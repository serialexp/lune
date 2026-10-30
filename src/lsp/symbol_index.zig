//! The workspace symbol index (doc 74 §7.4, P6e): every function and method
//! of every source file in the workspace folders, at any depth, and each
//! file's top-level names, for `workspace/symbol`.
//!
//! Built in the background. When a folder appears, the index saved for it
//! last session (the host's `Store`) is loaded and the folder walked, a
//! slice of work per `work` call (the server's `tick`), so requests are
//! answered meanwhile. The walk stamps every file (`Files.Stamp`: size and
//! modification time) and parses only one whose stamp differs from the one
//! it was indexed at, so a restart parses only what changed while the server
//! was away. After that, only the paths in the change log are looked at
//! again: what the client's file watcher reported (`note`). A client that
//! cannot watch has no change log, so each of its requests walks every
//! folder (`rewalk`), the stamps still sparing the parsing. A folder's index
//! is saved when its walk ends and at shutdown, never per change: it is
//! written whole, and its stamps make a stale one safe to load.
//!
//! `search` rules most names out with one AND of character masks before
//! scoring the rest, and keeps only the best `limit` in a heap. Bounded
//! (§3): at most `max_files` files are indexed, and a change log longer
//! than that is dropped for a walk.

const std = @import("std");
const diag = @import("../diag.zig");
const parser = @import("../parser.zig");
const position = @import("position.zig");
const syntax = @import("syntax.zig");
const uri_mod = @import("uri.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;

pub const max_files = 200_000;

/// Bump when what an entry holds changes (`syntax.symbols`, the layout
/// below): an index saved by another version is not loaded.
pub const format_version: u32 = 2;

/// What one `work` slice may spend: a stat or a directory listing costs one,
/// a parse one more per 128 bytes of the file. About 5 ms.
pub const slice_budget = 4096;

/// Directories a walk does not enter, besides the hidden ones (`.git`).
pub const skipped_dirs = [_][]const u8{ "node_modules", "zig-out", "target" };

/// One folder to walk, and the extensions of the files it holds.
pub const Root = struct {
    path: []const u8,
    extensions: []const []const u8,
};

/// An open document, indexed from its text.
pub const Open = struct {
    uri: []const u8,
    /// Its file, resolved, so the walk leaves the file to the document.
    path: ?[]const u8,
    text: []const u8,
};

/// One symbol, in the index's columns (`Index.syms`, a `MultiArrayList`):
/// a scan reads the masks alone, in order, and only a candidate's other
/// fields. 41 bytes; a 100k-file workspace holds 800k.
pub const Symbol = struct {
    /// `maskOf` the name; 0 for a dead slot.
    mask: u64,
    /// The name, in the file's text.
    range: position.Range,
    /// Offsets into `Index.pool`.
    name: u32,
    container: u32,
    name_len: u16,
    /// 0 for a top-level name; else the function or table it is declared in.
    container_len: u16,
    kind: syntax.Kind,
    /// The entry it belongs to (`Index.slots`), or `dead`.
    owner: u32,
};

/// The owner of a removed entry's symbols, until `compactIfWasteful`.
const dead = std.math.maxInt(u32);

/// A symbol as the outline (or a saved index) gives it, before it goes into
/// the columns.
const Found = struct {
    name: []const u8,
    kind: syntax.Kind,
    container: ?[]const u8,
    range: position.Range,
};

/// One file: its key and uri, and where its symbols and their names lie in
/// the columns (contiguous, in order).
pub const Entry = struct {
    /// The key, then the uri.
    strings: []u8,
    key_len: u32,
    uri_len: u32,
    stamp: workspace.Files.Stamp,
    first: u32,
    len: u32,
    pool_first: u32,
    pool_len: u32,
    /// Its slot in `Index.slots`.
    id: u32,
    /// The last pass that saw it.
    seen: u32,
    /// Indexed from an open document's text.
    document: bool,
    /// The key is a path (else the uri of a document with no file).
    file: bool,

    pub fn key(e: *const Entry) []const u8 {
        return e.strings[0..e.key_len];
    }

    pub fn uri(e: *const Entry) []const u8 {
        return e.strings[e.key_len..][0..e.uri_len];
    }
};

const RootState = struct {
    /// Owned by the index's `gpa`.
    path: []u8,
    extensions: [][]u8,
    /// Its entries changed since it was saved or loaded.
    dirty: bool = false,
    /// A walk of the whole root is in this pass: it is saved when the pass ends.
    walking: bool = false,

    fn view(r: *const RootState) Root {
        return .{ .path = r.path, .extensions = @ptrCast(r.extensions) };
    }
};

pub const Change = enum { created, changed, deleted };

pub const Index = struct {
    gpa: Allocator,
    /// By path (by uri for a document with no file); the keys are the
    /// entries' own.
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// Every entry's symbols, as columns, and their names. Removal marks a
    /// range dead; `compactIfWasteful` copies out the live once the dead
    /// outnumber them.
    syms: std.MultiArrayList(Symbol) = .empty,
    pool: std.ArrayList(u8) = .empty,
    dead_syms: usize = 0,
    dead_pool: usize = 0,
    /// The entries by id, for a symbol's `owner`; a free id is reused. Room
    /// in `free_slots` is kept for every slot, so freeing one cannot fail.
    slots: std.ArrayList(?*Entry) = .empty,
    free_slots: std.ArrayList(u32) = .empty,
    /// Every directory above an indexed file, and how many lie under it: a
    /// deletion reported at one of these is a directory's, and takes its
    /// files. Keys owned.
    dirs: std.StringHashMapUnmanaged(u32) = .empty,
    roots: std.ArrayList(RootState) = .empty,
    /// The walks in progress: directories to list, then files to look at.
    /// Paths owned.
    walk_dirs: std.ArrayList([]u8) = .empty,
    walk_files: std.ArrayList([]u8) = .empty,
    /// The change log: the paths reported since they were last looked at.
    /// Keys owned.
    pending: std.StringHashMapUnmanaged(void) = .empty,
    /// The directories walked in this pass, keys owned: what was indexed
    /// under one and not seen again is gone, swept when the pass ends.
    scopes: std.StringHashMapUnmanaged(void) = .empty,
    /// A walk reached `max_files` in this pass, so nothing is swept: what it
    /// did not get to was not seen, and is not gone.
    stopped: bool = false,
    /// Counts passes; a pass ends when no work is left.
    pass: u32 = 1,
    encoding: position.Encoding = .utf16,
    /// Files parsed, files stamped, and indexes saved so far: what an
    /// unchanged stamp, the change log and the store save, for tests and
    /// the benchmark.
    builds: u64 = 0,
    stamps: u64 = 0,
    saves: u64 = 0,
    /// A walk stopped at `max_files`.
    truncated: bool = false,

    pub const Mode = enum {
        /// Up to `slice_budget` of work.
        slice,
        /// The change log, all of it; walks it starts go on in slices.
        change_log,
        /// Everything.
        all,
    };

    pub fn init(gpa: Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Index) void {
        self.clearEntries();
        self.entries.deinit(self.gpa);
        self.syms.deinit(self.gpa);
        self.pool.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.free_slots.deinit(self.gpa);
        self.dirs.deinit(self.gpa);
        for (self.roots.items) |*r| self.freeRoot(r);
        self.roots.deinit(self.gpa);
        self.clearWork();
        self.walk_dirs.deinit(self.gpa);
        self.walk_files.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.scopes.deinit(self.gpa);
    }

    fn freeRoot(self: *Index, r: *RootState) void {
        for (r.extensions) |x| self.gpa.free(x);
        self.gpa.free(r.extensions);
        self.gpa.free(r.path);
    }

    fn clearEntries(self: *Index) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| self.free(e.*);
        self.entries.clearRetainingCapacity();
        self.syms.shrinkRetainingCapacity(0);
        self.pool.clearRetainingCapacity();
        self.dead_syms = 0;
        self.dead_pool = 0;
        self.slots.clearRetainingCapacity();
        self.free_slots.clearRetainingCapacity();
        var dit = self.dirs.keyIterator();
        while (dit.next()) |k| self.gpa.free(k.*);
        self.dirs.clearRetainingCapacity();
    }

    fn clearWork(self: *Index) void {
        for (self.walk_dirs.items) |d| self.gpa.free(d);
        self.walk_dirs.clearRetainingCapacity();
        for (self.walk_files.items) |f| self.gpa.free(f);
        self.walk_files.clearRetainingCapacity();
        freeKeys(self.gpa, &self.pending);
        freeKeys(self.gpa, &self.scopes);
    }

    fn free(self: *Index, e: *Entry) void {
        self.gpa.free(e.strings);
        self.gpa.destroy(e);
    }

    /// The symbols held.
    pub fn symbolCount(self: *const Index) usize {
        return self.syms.len - self.dead_syms;
    }

    /// Whether work is waiting for `work`.
    pub fn busy(self: *const Index) bool {
        return self.walk_dirs.items.len > 0 or self.walk_files.items.len > 0 or self.pending.count() > 0;
    }

    /// Positions are in `encoding` from here on; what was indexed in another
    /// is indexed again.
    pub fn setEncoding(self: *Index, encoding: position.Encoding) Allocator.Error!void {
        if (encoding == self.encoding) return;
        self.encoding = encoding;
        self.clearEntries();
        try self.rewalk();
    }

    /// Walk every root again: what a client that cannot watch needs before
    /// each request.
    pub fn rewalk(self: *Index) Allocator.Error!void {
        for (self.roots.items) |*r| try self.queueWalk(r);
    }

    fn queueWalk(self: *Index, r: *RootState) Allocator.Error!void {
        r.walking = true;
        try self.pushOwned(&self.walk_dirs, r.path);
        try putKey(self.gpa, &self.scopes, r.path);
    }

    fn pushOwned(self: *Index, list: *std.ArrayList([]u8), path: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(copy);
        try list.append(self.gpa, copy);
    }

    /// The folders are now `roots`. A new one has its saved index loaded from
    /// `store` and is walked. A root that went is saved first, its files are
    /// dropped, and every other root is walked again: one that held it now
    /// owns its directory. (Folders seldom go; a walk of unchanged files only
    /// stamps them.)
    pub fn setRoots(self: *Index, scratch: Allocator, roots: []const Root, store: ?workspace.Store) Allocator.Error!void {
        var removed_any = false;
        for (self.roots.items) |*o| {
            const kept = for (roots) |n| {
                if (sameRoot(o.view(), n)) break true;
            } else false;
            if (kept) continue;
            removed_any = true;
            if (store) |st| if (o.dirty) try self.save(scratch, o, st);
        }
        var next: std.ArrayList(RootState) = .empty;
        errdefer {
            for (next.items) |*r| self.freeRoot(r);
            next.deinit(self.gpa);
        }
        var fresh: std.ArrayList(usize) = .empty;
        for (roots, 0..) |n, i| {
            const old = for (self.roots.items) |*o| {
                if (sameRoot(o.view(), n)) break o;
            } else null;
            const xs = try self.gpa.alloc([]u8, n.extensions.len);
            var made: usize = 0;
            errdefer {
                for (xs[0..made]) |x| self.gpa.free(x);
                self.gpa.free(xs);
            }
            for (n.extensions, xs) |x, *slot| {
                slot.* = try self.gpa.dupe(u8, x);
                made += 1;
            }
            const path = try self.gpa.dupe(u8, n.path);
            errdefer self.gpa.free(path);
            try next.append(self.gpa, .{
                .path = path,
                .extensions = xs,
                .dirty = if (old) |o| o.dirty else false,
                .walking = if (old) |o| o.walking else false,
            });
            if (old == null) try fresh.append(scratch, i);
        }
        for (self.roots.items) |*o| self.freeRoot(o);
        self.roots.deinit(self.gpa);
        self.roots = next;

        for (fresh.items) |i| {
            const r = &self.roots.items[i];
            if (store) |st| try self.load(scratch, r, st);
            try self.queueWalk(r);
        }
        if (removed_any) {
            // What lies in no root goes; a root that now owns a nested
            // root's directory walks it.
            var gone: std.ArrayList([]const u8) = .empty;
            var it = self.entries.valueIterator();
            while (it.next()) |e| {
                if (!e.*.file or e.*.document) continue;
                if (innermost(self.roots.items, e.*.key()) == null) try gone.append(scratch, try scratch.dupe(u8, e.*.key()));
            }
            for (gone.items) |k| self.remove(k);
            for (self.roots.items) |*r| {
                if (!r.walking) try self.queueWalk(r);
            }
        }
    }

    /// Log a change the client's watcher reported at `path` (resolved). What
    /// cannot matter is dropped here: a path in no root or in a directory the
    /// walk does not enter, and a change to a file that is not a source file
    /// (a creation or deletion is kept: it may be a directory's).
    pub fn note(self: *Index, path: []const u8, change: Change) Allocator.Error!void {
        const root = innermost(self.roots.items, path) orelse return;
        if (skippedBelow(root.path, path)) return;
        if (change == .changed and !hasExtension(path, root.extensions)) return;
        try self.queue(path);
    }

    fn queue(self: *Index, path: []const u8) Allocator.Error!void {
        if (self.pending.contains(path)) return;
        if (self.pending.count() >= max_files) {
            // Too much to go by: walk everything instead.
            freeKeys(self.gpa, &self.pending);
            return self.rewalk();
        }
        try putKey(self.gpa, &self.pending, path);
    }

    /// Index the open documents, ahead of their files; a document closed
    /// since goes back to its file, if there is one.
    pub fn setOpen(self: *Index, scratch: Allocator, opened: []const Open, has_disk: bool) Allocator.Error!void {
        var open_keys: std.StringHashMapUnmanaged(void) = .empty;
        for (opened) |d| {
            const key = d.path orelse d.uri;
            try open_keys.put(scratch, key, {});
            const stamp: workspace.Files.Stamp = .{ .size = d.text.len, .mtime_ns = @as(u64, @truncate(std.hash.Wyhash.hash(0, d.text))) };
            try self.update(key, d.uri, stamp, d.text, true, d.path != null);
        }
        var closed: std.ArrayList([]const u8) = .empty;
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (e.*.document and !open_keys.contains(e.*.key())) try closed.append(scratch, try scratch.dupe(u8, e.*.key()));
        }
        for (closed.items) |k| {
            const e = self.entries.get(k).?;
            if (has_disk and e.file and innermost(self.roots.items, k) != null) {
                // Its stamp is the text's hash, so the file is parsed again.
                e.document = false;
                try self.queue(k);
            } else self.remove(k);
        }
        try self.compactIfWasteful();
    }

    /// Do the waiting work, as much as `mode` says. `scratch` holds what
    /// lives only for this call.
    pub fn work(self: *Index, scratch: Allocator, fs: workspace.Files, store: ?workspace.Store, mode: Mode) Allocator.Error!void {
        var spent: u64 = 0;
        // The change log first: it is the newest word on what is there.
        while (self.pending.count() > 0) {
            if (mode == .slice and spent >= slice_budget) return;
            var kit = self.pending.keyIterator();
            const owned = kit.next().?.*;
            _ = self.pending.remove(owned);
            defer self.gpa.free(owned);
            spent += try self.lookAt(scratch, fs, owned);
        }
        if (mode == .change_log) return self.endPassIfIdle(scratch, store);
        while (true) {
            if (mode == .slice and spent >= slice_budget) return;
            if (self.walk_files.pop()) |path| {
                defer self.gpa.free(path);
                spent += try self.walkFile(scratch, fs, path);
            } else if (self.walk_dirs.pop()) |dir| {
                defer self.gpa.free(dir);
                spent += try self.walkDir(scratch, fs, dir);
            } else break;
        }
        try self.endPassIfIdle(scratch, store);
    }

    /// A path from the change log: a source file is indexed again if its
    /// stamp changed; a directory is walked; what is gone, or is not a
    /// source file, is dropped (a directory's files with it).
    fn lookAt(self: *Index, scratch: Allocator, fs: workspace.Files, path: []const u8) Allocator.Error!u64 {
        if (self.entries.get(path)) |e| if (e.document) return 0;
        const root = innermost(self.roots.items, path) orelse return 0;
        if (skippedBelow(root.path, path)) return 0;
        self.stamps += 1;
        if (fs.stamp.?(fs.ctx, path)) |stamp| {
            if (hasExtension(path, root.extensions)) return 1 + try self.indexFile(scratch, fs, path, stamp);
            self.remove(path);
            return 1;
        }
        if (fs.list.?(fs.ctx, scratch, path) != null) {
            // A directory: walked, and what it no longer holds swept.
            try self.pushOwned(&self.walk_dirs, path);
            try putKey(self.gpa, &self.scopes, path);
            return 1;
        }
        if (self.entries.contains(path)) {
            self.remove(path);
        } else if (self.dirs.contains(path)) {
            try self.removeUnder(scratch, path);
        }
        return 1;
    }

    fn walkDir(self: *Index, scratch: Allocator, fs: workspace.Files, dir: []const u8) Allocator.Error!u64 {
        if (self.stopped) return 0;
        const root = innermost(self.roots.items, dir) orelse return 0;
        const listing = fs.list.?(fs.ctx, scratch, dir) orelse return 1;
        for (listing) |e| {
            if (isSkipped(e.name)) continue;
            const path = try std.fs.path.resolveAllocPosix(scratch, &.{ dir, e.name });
            switch (e.kind) {
                .directory => {
                    const nested = for (self.roots.items) |r| {
                        if (std.mem.eql(u8, r.path, path)) break true;
                    } else false;
                    if (!nested) try self.pushOwned(&self.walk_dirs, path);
                },
                .file => if (hasExtension(e.name, root.extensions)) try self.pushOwned(&self.walk_files, path),
            }
        }
        return 1 + listing.len / 16;
    }

    fn walkFile(self: *Index, scratch: Allocator, fs: workspace.Files, path: []const u8) Allocator.Error!u64 {
        if (self.stopped) return 0;
        if (self.entries.get(path)) |e| if (e.document or e.seen == self.pass) return 0;
        self.stamps += 1;
        const stamp = fs.stamp.?(fs.ctx, path) orelse return 1;
        return 1 + try self.indexFile(scratch, fs, path, stamp);
    }

    /// Index the file at `path`, unless it is indexed at `stamp` already.
    /// Returns what the parse cost.
    fn indexFile(self: *Index, scratch: Allocator, fs: workspace.Files, path: []const u8, stamp: workspace.Files.Stamp) Allocator.Error!u64 {
        const old = self.entries.get(path);
        if (old) |e| if (std.meta.eql(e.stamp, stamp)) {
            e.seen = self.pass;
            return 0;
        };
        if (old == null and self.entries.count() >= max_files) {
            self.truncated = true;
            self.stopped = true;
            return 0;
        }
        // Freed at once: a first walk reads every file.
        const text = fs.read(fs.ctx, self.gpa, path) orelse return 0;
        defer self.gpa.free(text);
        try self.update(path, try uri_mod.fromPath(scratch, path), stamp, text, false, true);
        return text.len / 128;
    }

    /// The pass is over when no work is left: what its walks did not see
    /// again is swept, and the roots it walked whole are saved.
    fn endPassIfIdle(self: *Index, scratch: Allocator, store: ?workspace.Store) Allocator.Error!void {
        try self.compactIfWasteful();
        if (self.busy()) return;
        if (!self.stopped and self.scopes.count() > 0) try self.sweep(scratch);
        for (self.roots.items) |*r| {
            if (r.walking and r.dirty) if (store) |st| try self.save(scratch, r, st);
            r.walking = false;
        }
        freeKeys(self.gpa, &self.scopes);
        self.stopped = false;
        self.pass +%= 1;
    }

    /// Drop each entry from a file that this pass did not see, if it lies in
    /// a walked scope under the scope's own root (a nested root's files are
    /// its own).
    fn sweep(self: *Index, scratch: Allocator) Allocator.Error!void {
        var gone: std.ArrayList([]const u8) = .empty;
        var it = self.entries.valueIterator();
        while (it.next()) |ep| {
            const e = ep.*;
            if (e.seen == self.pass or e.document or !e.file) continue;
            const key = e.key();
            const root = innermost(self.roots.items, key) orelse {
                try gone.append(scratch, try scratch.dupe(u8, key));
                continue;
            };
            // The entry's path, then each directory above it, up to the root.
            var at: []const u8 = key;
            while (true) {
                if (self.scopes.contains(at)) {
                    const scope_root = innermost(self.roots.items, at).?;
                    if (std.mem.eql(u8, scope_root.path, root.path)) try gone.append(scratch, try scratch.dupe(u8, key));
                    break;
                }
                if (at.len <= root.path.len) break;
                at = std.fs.path.dirnamePosix(at) orelse break;
            }
        }
        for (gone.items) |k| self.remove(k);
    }

    /// Save every root changed since it was saved: at shutdown.
    pub fn saveDirty(self: *Index, scratch: Allocator, store: workspace.Store) Allocator.Error!void {
        for (self.roots.items) |*r| {
            if (r.dirty) try self.save(scratch, r, store);
        }
    }

    // ---- entries --------------------------------------------------------

    fn remove(self: *Index, key: []const u8) void {
        const e = (self.entries.fetchRemove(key) orelse return).value;
        self.forget(e);
        @memset(self.syms.items(.owner)[e.first..][0..e.len], dead);
        @memset(self.syms.items(.mask)[e.first..][0..e.len], 0);
        self.dead_syms += e.len;
        self.dead_pool += e.pool_len;
        self.slots.items[e.id] = null;
        self.free_slots.appendAssumeCapacity(e.id);
        self.free(e);
    }

    /// Copy the live symbols and names into fresh columns once the dead
    /// outnumber them, so a scan stays dense. Amortised: each copy follows at
    /// least as many removals as it moves.
    fn compactIfWasteful(self: *Index) Allocator.Error!void {
        const live = self.syms.len - self.dead_syms;
        if (self.dead_syms < 4096 or self.dead_syms < live) return;
        var syms: std.MultiArrayList(Symbol) = .empty;
        errdefer syms.deinit(self.gpa);
        try syms.ensureTotalCapacity(self.gpa, live);
        var pool: std.ArrayList(u8) = .empty;
        errdefer pool.deinit(self.gpa);
        try pool.ensureTotalCapacity(self.gpa, self.pool.items.len - self.dead_pool);
        // An entry with no symbols holds no place in the columns.
        for (self.slots.items) |slot| {
            const e = slot orelse continue;
            if (e.len == 0) {
                e.first = 0;
                e.pool_first = 0;
            }
        }
        const owners = self.syms.items(.owner);
        var i: usize = 0;
        while (i < self.syms.len) {
            if (owners[i] == dead) {
                i += 1;
                continue;
            }
            // The first live symbol met is its entry's first.
            const e = self.slots.items[owners[i]].?;
            const new_first: u32 = @intCast(syms.len);
            const new_pool: u32 = @intCast(pool.items.len);
            pool.appendSliceAssumeCapacity(self.pool.items[e.pool_first..][0..e.pool_len]);
            for (e.first..e.first + e.len) |k| {
                var sym = self.syms.get(k);
                sym.name = sym.name - e.pool_first + new_pool;
                if (sym.container_len != 0) sym.container = sym.container - e.pool_first + new_pool;
                syms.appendAssumeCapacity(sym);
            }
            i = e.first + e.len;
            e.first = new_first;
            e.pool_first = new_pool;
        }
        self.syms.deinit(self.gpa);
        self.syms = syms;
        self.pool.deinit(self.gpa);
        self.pool = pool;
        self.dead_syms = 0;
        self.dead_pool = 0;
    }

    /// Every file entry under the directory `dir`.
    fn removeUnder(self: *Index, scratch: Allocator, dir: []const u8) Allocator.Error!void {
        var gone: std.ArrayList([]const u8) = .empty;
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (e.*.file and !e.*.document and within(dir, e.*.key())) try gone.append(scratch, try scratch.dupe(u8, e.*.key()));
        }
        for (gone.items) |k| self.remove(k);
    }

    /// Count a new entry: its directories, and its root as changed.
    fn count(self: *Index, e: *const Entry) Allocator.Error!void {
        if (!e.file) return;
        const key = e.key();
        if (!e.document) self.markDirty(key);
        var at = std.fs.path.dirnamePosix(key);
        while (at) |d| : (at = std.fs.path.dirnamePosix(d)) {
            const slot = try self.dirs.getOrPut(self.gpa, d);
            if (slot.found_existing) {
                slot.value_ptr.* += 1;
            } else {
                slot.key_ptr.* = self.gpa.dupe(u8, d) catch |err| {
                    self.dirs.removeByPtr(slot.key_ptr);
                    return err;
                };
                slot.value_ptr.* = 1;
            }
        }
    }

    /// Uncount an entry that is going.
    fn forget(self: *Index, e: *const Entry) void {
        if (!e.file) return;
        const key = e.key();
        if (!e.document) self.markDirty(key);
        var at = std.fs.path.dirnamePosix(key);
        while (at) |d| : (at = std.fs.path.dirnamePosix(d)) {
            const slot = self.dirs.getEntry(d) orelse continue;
            slot.value_ptr.* -= 1;
            if (slot.value_ptr.* == 0) {
                const owned = slot.key_ptr.*;
                self.dirs.removeByPtr(slot.key_ptr);
                self.gpa.free(owned);
            }
        }
    }

    fn markDirty(self: *Index, path: []const u8) void {
        const r = innermostState(self.roots.items, path) orelse return;
        r.dirty = true;
    }

    /// Index `text` under `key`, unless it is indexed at `stamp` already.
    fn update(self: *Index, key: []const u8, uri: []const u8, stamp: workspace.Files.Stamp, text: []const u8, document: bool, file: bool) Allocator.Error!void {
        if (self.entries.get(key)) |old| {
            if (old.document == document and std.meta.eql(old.stamp, stamp)) {
                old.seen = self.pass;
                return;
            }
            self.remove(key);
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const found = try self.symbolsOf(scratch.allocator(), text);
        try self.insertFound(key, uri, stamp, found, self.pass, document, file);
    }

    /// Add an entry under `key` (none there yet) holding `found`.
    fn insertFound(self: *Index, key: []const u8, uri: []const u8, stamp: workspace.Files.Stamp, found: []const Found, seen: u32, document: bool, file: bool) Allocator.Error!void {
        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        e.strings = try self.gpa.alloc(u8, key.len + uri.len);
        errdefer self.gpa.free(e.strings);
        @memcpy(e.strings[0..key.len], key);
        @memcpy(e.strings[key.len..], uri);
        e.key_len = @intCast(key.len);
        e.uri_len = @intCast(uri.len);
        e.stamp = stamp;
        e.seen = seen;
        e.document = document;
        e.file = file;

        // A slot: a free one, or a new one with room kept to free it.
        e.id = self.free_slots.pop() orelse blk: {
            try self.free_slots.ensureTotalCapacity(self.gpa, self.slots.items.len + 1);
            try self.slots.append(self.gpa, null);
            break :blk @intCast(self.slots.items.len - 1);
        };
        errdefer self.free_slots.appendAssumeCapacity(e.id);

        var size: usize = 0;
        var n: usize = 0;
        for (found) |f| {
            if (!fits(f)) continue;
            size += f.name.len + if (f.container) |c| c.len else 0;
            n += 1;
        }
        // Offsets are 32-bit.
        if (self.pool.items.len + size > std.math.maxInt(u32)) return error.OutOfMemory;
        try self.pool.ensureUnusedCapacity(self.gpa, size);
        try self.syms.ensureUnusedCapacity(self.gpa, n);
        e.first = @intCast(self.syms.len);
        e.len = @intCast(n);
        e.pool_first = @intCast(self.pool.items.len);
        e.pool_len = @intCast(size);
        for (found) |f| {
            if (!fits(f)) continue;
            const name_at: u32 = @intCast(self.pool.items.len);
            self.pool.appendSliceAssumeCapacity(f.name);
            const container_at: u32 = @intCast(self.pool.items.len);
            if (f.container) |c| self.pool.appendSliceAssumeCapacity(c);
            self.syms.appendAssumeCapacity(.{
                .mask = maskOf(f.name),
                .range = f.range,
                .name = name_at,
                .container = if (f.container != null) container_at else 0,
                .name_len = @intCast(f.name.len),
                .container_len = if (f.container) |c| @intCast(c.len) else 0,
                .kind = f.kind,
                .owner = e.id,
            });
        }
        errdefer {
            self.syms.shrinkRetainingCapacity(e.first);
            self.pool.shrinkRetainingCapacity(e.pool_first);
        }
        try self.entries.put(self.gpa, e.key(), e);
        errdefer _ = self.entries.remove(e.key());
        try self.count(e);
        self.slots.items[e.id] = e;
    }

    /// A name or container too long for its length field is left out.
    fn fits(f: Found) bool {
        const limit = std.math.maxInt(u16);
        return f.name.len > 0 and f.name.len <= limit and (f.container == null or f.container.?.len <= limit);
    }

    /// The symbols of `text`, allocated in `a` (scratch).
    fn symbolsOf(self: *Index, a: Allocator, text: []const u8) Allocator.Error![]const Found {
        self.builds += 1;
        const source = try a.dupeSentinel(u8, text, 0);
        var diags = diag.Diagnostics.init(self.gpa);
        defer diags.deinit();
        var tree = parser.parse(self.gpa, source, &diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => return &.{},
        };
        defer tree.deinit();
        const outline = try syntax.symbols(a, tree.root);
        var index = position.LineIndex.build(self.gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TextTooLong => return &.{},
        };
        defer index.deinit(self.gpa);
        var out: std.ArrayList(Found) = .empty;
        try flatten(a, &out, outline, null, &index, text, self.encoding);
        return out.items;
    }

    // ---- the saved index ------------------------------------------------
    //
    // One file per root, named by a hash of its path: "MHSI", the format
    // version, a Wyhash of the rest, then the encoding, the root's path and
    // extensions, and each file's entry: lengths, stamp, its strings (key,
    // uri, names) and its symbols, their name offsets into those strings.
    // Little-endian. Anything that does not check out is ignored whole: the
    // walk rebuilds.

    const magic = "MHSI";
    const header_bytes = magic.len + 4 + 8;
    const entry_bytes = 4 + 4 + 4 + 8 + 16 + 4;
    const symbol_bytes = 16 + 4 + 4 + 2 + 2 + 1;

    fn storeName(buf: *[32]u8, root: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x:0>16}.idx", .{std.hash.Wyhash.hash(0, root)}) catch unreachable;
    }

    /// Whether `e` is saved with `root`: a file's, not a document's, and
    /// `root` the innermost root holding it.
    fn savedWith(self: *const Index, e: *const Entry, root: []const u8) bool {
        if (e.document or !e.file) return false;
        const owner = innermost(self.roots.items, e.key()) orelse return false;
        return std.mem.eql(u8, owner.path, root);
    }

    fn save(self: *Index, scratch: Allocator, root: *RootState, store: workspace.Store) Allocator.Error!void {
        // Sized first, so the buffer (the size of the index) is allocated once.
        var size: usize = header_bytes + 1 + 4 + root.path.len + 4 + 4;
        for (root.extensions) |x| size += 4 + x.len;
        var it = self.entries.valueIterator();
        while (it.next()) |ep| {
            const e = ep.*;
            if (self.savedWith(e, root.path)) size += entry_bytes + e.strings.len + e.pool_len + @as(usize, e.len) * symbol_bytes;
        }
        var out: std.ArrayList(u8) = try .initCapacity(scratch, size);
        out.appendSliceAssumeCapacity(magic);
        putInt(&out, u32, format_version);
        const sum_at = out.items.len;
        putInt(&out, u64, 0);
        const body_at = out.items.len;
        putInt(&out, u8, @intFromEnum(self.encoding));
        putBytes(&out, root.path);
        putInt(&out, u32, @intCast(root.extensions.len));
        for (root.extensions) |x| putBytes(&out, x);
        const count_at = out.items.len;
        putInt(&out, u32, 0);
        var n: u32 = 0;
        const cols = self.syms.slice();
        it = self.entries.valueIterator();
        while (it.next()) |ep| {
            const e = ep.*;
            if (!self.savedWith(e, root.path)) continue;
            const base = e.key_len + e.uri_len;
            putInt(&out, u32, base + e.pool_len);
            putInt(&out, u32, e.key_len);
            putInt(&out, u32, e.uri_len);
            putInt(&out, u64, e.stamp.size);
            putInt(&out, i128, e.stamp.mtime_ns);
            putInt(&out, u32, e.len);
            out.appendSliceAssumeCapacity(e.strings);
            out.appendSliceAssumeCapacity(self.pool.items[e.pool_first..][0..e.pool_len]);
            for (e.first..e.first + e.len) |k| {
                const sym = cols.get(k);
                putInt(&out, u32, sym.range.start.line);
                putInt(&out, u32, sym.range.start.character);
                putInt(&out, u32, sym.range.end.line);
                putInt(&out, u32, sym.range.end.character);
                putInt(&out, u32, sym.name - e.pool_first + base);
                putInt(&out, u32, if (sym.container_len != 0) sym.container - e.pool_first + base else 0);
                putInt(&out, u16, sym.name_len);
                putInt(&out, u16, sym.container_len);
                putInt(&out, u8, @intFromEnum(sym.kind));
            }
            n += 1;
        }
        std.debug.assert(out.items.len == size);
        std.mem.writeInt(u32, out.items[count_at..][0..4], n, .little);
        std.mem.writeInt(u64, out.items[sum_at..][0..8], std.hash.Wyhash.hash(0, out.items[body_at..]), .little);
        var buf: [32]u8 = undefined;
        store.save(store.ctx, storeName(&buf, root.path), out.items);
        root.dirty = false;
        self.saves += 1;
    }

    /// Load `root`'s saved index: its entries, unseen, for the walk to
    /// confirm by their stamps. An entry already held, or now in a nested
    /// root, is left out. A save that does not check out is ignored whole.
    fn load(self: *Index, scratch: Allocator, root: *RootState, store: workspace.Store) Allocator.Error!void {
        var buf: [32]u8 = undefined;
        const bytes = store.load(store.ctx, scratch, storeName(&buf, root.path)) orelse return;
        var added: std.ArrayList([]const u8) = .empty;
        self.decode(scratch, root, bytes, &added) catch |err| {
            for (added.items) |k| self.remove(k);
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Corrupt => return,
            }
        };
        // As saved: a walk that finds nothing changed has nothing to save.
        root.dirty = false;
    }

    /// Insert the entries of `bytes`, each as it is read; their keys go to
    /// `added` (allocated in `scratch`) for `load` to take back on failure.
    fn decode(self: *Index, scratch: Allocator, root: *const RootState, bytes: []const u8, added: *std.ArrayList([]const u8)) (Allocator.Error || error{Corrupt})!void {
        var r: Reader = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try r.take(magic.len), magic)) return error.Corrupt;
        if (try r.int(u32) != format_version) return error.Corrupt;
        const sum = try r.int(u64);
        if (std.hash.Wyhash.hash(0, bytes[r.at..]) != sum) return error.Corrupt;
        if (try r.int(u8) != @intFromEnum(self.encoding)) return error.Corrupt;
        if (!std.mem.eql(u8, try r.bytesOf(), root.path)) return error.Corrupt;
        if (try r.int(u32) != root.extensions.len) return error.Corrupt;
        for (root.extensions) |x| {
            if (!std.mem.eql(u8, try r.bytesOf(), x)) return error.Corrupt;
        }
        var found: std.ArrayList(Found) = .empty;
        defer found.deinit(self.gpa);
        const n = try r.int(u32);
        for (0..n) |_| {
            const strings_len = try r.int(u32);
            const key_len = try r.int(u32);
            const uri_len = try r.int(u32);
            const size = try r.int(u64);
            const mtime = try r.int(i128);
            const symbol_count = try r.int(u32);
            if (@as(u64, key_len) + uri_len > strings_len or key_len == 0) return error.Corrupt;
            if (mtime < std.math.minInt(i96) or mtime > std.math.maxInt(i96)) return error.Corrupt;
            const strings = try r.take(strings_len);
            if (@as(u64, symbol_count) * symbol_bytes > r.bytes.len - r.at) return error.Corrupt;
            found.clearRetainingCapacity();
            try found.ensureTotalCapacity(self.gpa, symbol_count);
            for (0..symbol_count) |_| {
                const range: position.Range = .{
                    .start = .{ .line = try r.int(u32), .character = try r.int(u32) },
                    .end = .{ .line = try r.int(u32), .character = try r.int(u32) },
                };
                const name_at = try r.int(u32);
                const container_at = try r.int(u32);
                const name_len = try r.int(u16);
                const container_len = try r.int(u16);
                const kind = std.enums.fromInt(syntax.Kind, try r.int(u8)) orelse return error.Corrupt;
                if (@as(u64, name_at) + name_len > strings_len or @as(u64, container_at) + container_len > strings_len) return error.Corrupt;
                found.appendAssumeCapacity(.{
                    .name = strings[name_at..][0..name_len],
                    .kind = kind,
                    .container = if (container_len != 0) strings[container_at..][0..container_len] else null,
                    .range = range,
                });
            }
            const key = strings[0..key_len];
            const owner = innermost(self.roots.items, key);
            const ours = owner != null and std.mem.eql(u8, owner.?.path, root.path);
            if (!ours or self.entries.contains(key)) continue;
            const stamp: workspace.Files.Stamp = .{ .size = size, .mtime_ns = @intCast(mtime) };
            try added.ensureUnusedCapacity(scratch, 1);
            try self.insertFound(key, strings[key_len..][0..uri_len], stamp, found.items, 0, false, true);
            added.appendAssumeCapacity(self.entries.get(key).?.key());
        }
        if (r.at != bytes.len) return error.Corrupt;
    }

    // ---- searching ------------------------------------------------------

    /// The symbols matching `query` (see `score`), the closest first, at most
    /// `limit` of them; allocated in `a`, and valid until the index changes.
    pub fn search(self: *const Index, a: Allocator, query: []const u8, limit: usize) Allocator.Error![]const Hit {
        if (limit == 0) return &.{};
        const want = maskOf(query);
        // The worst kept hit on top, to be pushed out by a better one.
        var best = std.PriorityQueue(Hit, void, Hit.worseFirst).initContext({});
        const cols = self.syms.slice();
        const owners = cols.items(.owner);
        // A dead symbol's mask is 0: it passes only the empty query.
        for (cols.items(.mask), 0..) |m, i| {
            if (m & want != want or owners[i] == dead) continue;
            const sym = cols.get(i);
            const name = self.pool.items[sym.name..][0..sym.name_len];
            const rank = score(name, query) orelse continue;
            const hit: Hit = .{
                .symbol = sym,
                .name_text = name,
                .container_text = if (sym.container_len != 0) self.pool.items[sym.container..][0..sym.container_len] else null,
                .entry = self.slots.items[owners[i]].?,
                .rank = rank,
            };
            if (best.count() < limit) {
                try best.push(a, hit);
            } else if (Hit.before({}, hit, best.peek().?)) {
                _ = best.pop();
                try best.push(a, hit);
            }
        }
        const hits = best.items;
        std.mem.sort(Hit, hits, {}, Hit.before);
        return hits;
    }
};

pub const Hit = struct {
    symbol: Symbol,
    name_text: []const u8,
    container_text: ?[]const u8,
    entry: *const Entry,
    rank: u8,

    pub fn name(h: Hit) []const u8 {
        return h.name_text;
    }

    pub fn container(h: Hit) ?[]const u8 {
        return h.container_text;
    }

    pub fn uri(h: Hit) []const u8 {
        return h.entry.uri();
    }

    pub fn range(h: Hit) position.Range {
        return h.symbol.range;
    }

    fn before(_: void, x: Hit, y: Hit) bool {
        if (x.rank != y.rank) return x.rank < y.rank;
        const order = std.mem.order(u8, x.name_text, y.name_text);
        if (order != .eq) return order == .lt;
        return std.mem.order(u8, x.uri(), y.uri()) == .lt;
    }

    fn worseFirst(_: void, x: Hit, y: Hit) std.math.Order {
        if (before({}, y, x)) return .lt;
        if (before({}, x, y)) return .gt;
        return .eq;
    }
};

/// One bit per character class, ignoring case: letters, digits and `_` each
/// their own, the rest sharing bits. A name lacking a bit the query has
/// cannot hold it as a subsequence.
pub fn maskOf(s: []const u8) u64 {
    var m: u64 = 0;
    for (s) |raw| {
        const c = std.ascii.toLower(raw);
        const bit: u6 = switch (c) {
            'a'...'z' => @intCast(c - 'a'),
            '0'...'9' => @intCast(26 + c - '0'),
            '_' => 36,
            else => @intCast(37 + c % 27),
        };
        m |= @as(u64, 1) << bit;
    }
    return m;
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(r: *Reader, n: usize) error{Corrupt}![]const u8 {
        if (n > r.bytes.len - r.at) return error.Corrupt;
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }

    fn int(r: *Reader, comptime T: type) error{Corrupt}!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const b = try r.take(n);
        return std.mem.readInt(T, b[0..n], .little);
    }

    fn bytesOf(r: *Reader) error{Corrupt}![]const u8 {
        return r.take(try r.int(u32));
    }
};

/// Into room reserved beforehand.
fn putInt(out: *std.ArrayList(u8), comptime T: type, v: T) void {
    var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    out.appendSliceAssumeCapacity(&b);
}

fn putBytes(out: *std.ArrayList(u8), s: []const u8) void {
    putInt(out, u32, @intCast(s.len));
    out.appendSliceAssumeCapacity(s);
}

fn putKey(gpa: Allocator, set: *std.StringHashMapUnmanaged(void), key: []const u8) Allocator.Error!void {
    if (set.contains(key)) return;
    const copy = try gpa.dupe(u8, key);
    errdefer gpa.free(copy);
    try set.put(gpa, copy, {});
}

fn freeKeys(gpa: Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.clearRetainingCapacity();
}

/// The innermost of `roots` containing `path`.
fn innermost(roots: []const RootState, path: []const u8) ?Root {
    const r = innermostIndex(roots, path) orelse return null;
    return roots[r].view();
}

fn innermostState(roots: []RootState, path: []const u8) ?*RootState {
    const r = innermostIndex(roots, path) orelse return null;
    return &roots[r];
}

fn innermostIndex(roots: []const RootState, path: []const u8) ?usize {
    var best: ?usize = null;
    for (roots, 0..) |r, i| {
        if (!within(r.path, path)) continue;
        if (best == null or r.path.len > roots[best.?].path.len) best = i;
    }
    return best;
}

/// Whether `path` is `dir` or lies under it.
fn within(dir: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len) return true;
    return std.mem.endsWith(u8, dir, "/") or path[dir.len] == '/';
}

fn isSkipped(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    for (skipped_dirs) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// Whether a component of `path` below `root` is one the walk does not enter.
fn skippedBelow(root: []const u8, path: []const u8) bool {
    if (path.len <= root.len) return false;
    var it = std.mem.tokenizeScalar(u8, path[root.len..], '/');
    while (it.next()) |part| {
        if (isSkipped(part)) return true;
    }
    return false;
}

fn sameRoot(x: Root, y: Root) bool {
    if (!std.mem.eql(u8, x.path, y.path) or x.extensions.len != y.extensions.len) return false;
    for (x.extensions, y.extensions) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

/// How `name` matches `query`, ignoring case: 0 the whole name, 1 a prefix,
/// 2 a substring, 3 a subsequence (`mad` in `M.add`); null for no match. An
/// empty query matches everything at 3.
pub fn score(name: []const u8, query: []const u8) ?u8 {
    if (query.len == 0) return 3;
    if (std.ascii.eqlIgnoreCase(name, query)) return 0;
    if (std.ascii.startsWithIgnoreCase(name, query)) return 1;
    if (std.ascii.findIgnoreCase(name, query) != null) return 2;
    var i: usize = 0;
    for (name) |c| {
        if (i < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[i])) i += 1;
    }
    return if (i == query.len) 3 else null;
}

fn hasExtension(name: []const u8, extensions: []const []const u8) bool {
    for (extensions) |x| {
        if (std.mem.endsWith(u8, name, x) and name.len > x.len) return true;
    }
    return false;
}

/// The outline's functions and methods at any depth, and its top-level names.
fn flatten(
    a: Allocator,
    out: *std.ArrayList(Found),
    list: []const syntax.Symbol,
    container: ?[]const u8,
    index: *const position.LineIndex,
    text: []const u8,
    encoding: position.Encoding,
) Allocator.Error!void {
    for (list) |s| {
        const callable = s.kind == .function or s.kind == .method;
        if (container == null or callable) {
            try out.append(a, .{
                .name = s.name,
                .kind = s.kind,
                .container = container,
                .range = index.toRange(text, s.selection.start, s.selection.end, encoding),
            });
        }
        try flatten(a, out, s.children, s.name, index, text, encoding);
    }
}

/// The file extensions `package.path` templates name: `.mah` of `./?.mah`.
pub fn extensionsOf(a: Allocator, templates: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (templates) |t| {
        const base = std.fs.path.basenamePosix(t);
        const dot = std.mem.findScalarLast(u8, base, '.') orelse continue;
        const x = base[dot..];
        const dup = for (out.items) |o| {
            if (std.mem.eql(u8, o, x)) break true;
        } else false;
        if (!dup) try out.append(a, x);
    }
    return out.items;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

/// An index over `mem` with one root per path in `roots`, each taking
/// `.mah` (and `.lua`, for the second and later).
const Fixture = struct {
    idx: Index,
    arena: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .idx = Index.init(testing.allocator), .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(f: *Fixture) void {
        f.idx.deinit();
        f.arena.deinit();
    }

    fn a(f: *Fixture) Allocator {
        return f.arena.allocator();
    }

    /// Run the waiting work to its end.
    fn settle(f: *Fixture, mem: *workspace.MemoryFiles, store: ?workspace.Store) !void {
        try f.idx.work(f.a(), mem.files(), store, .all);
    }

    fn names(f: *Fixture, query: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (try f.idx.search(f.a(), query, 100)) |h| {
            try out.appendSlice(f.a(), h.name());
            try out.append(f.a(), ' ');
        }
        return out.items;
    }
};

test "symbol index: functions at any depth and top-level names; the change log is all that is looked at again" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "local M = {}\nfunction M.add(a, b)\n  local function helper() end\n  local inner = 1\nend\nreturn M\n" },
        .{ "/w/sub/b.mah", "function greet() end\n" },
        .{ "/w/notes.txt", "function nope() end\n" },
        .{ "/w/.git/c.mah", "function hidden() end\n" },
        .{ "/w/node_modules/d.mah", "function vendored() end\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    var f = Fixture.init();
    defer f.deinit();
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};
    try f.idx.setEncoding(.utf8);
    try f.idx.setRoots(f.a(), &roots, null);
    try testing.expect(f.idx.busy());
    try f.settle(&mem, null);
    try testing.expect(!f.idx.busy());
    try testing.expectEqual(@as(u64, 2), f.idx.builds);
    try testing.expectEqualStrings("M M.add greet helper ", try f.names(""));
    const helper = (try f.idx.search(f.a(), "helper", 10))[0];
    try testing.expectEqualStrings("M.add", helper.container().?);
    try testing.expectEqualStrings("file:///w/a.mah", helper.uri());
    try testing.expectEqual(@as(u32, 2), helper.range().start.line);

    // Nothing reported: nothing to do.
    const stamped = f.idx.stamps;
    try testing.expect(!f.idx.busy());

    // What the change log names is looked at: a changed file is parsed
    // again, a file renamed away from a source extension goes. An open
    // document wins over its file, and its file is back once it closes.
    entries[1][1] = "function welcome() end\n";
    entries[0][0] = "/w/gone.txt";
    try f.idx.note("/w/sub/b.mah", .changed);
    try f.idx.note("/w/a.mah", .deleted);
    try f.idx.note("/w/gone.txt", .created);
    try f.idx.note("/w/notes.txt", .changed); // not a source file: dropped
    try f.idx.note("/w/.git/c.mah", .changed); // not walked: dropped
    try f.idx.note("/elsewhere/x.mah", .changed); // in no root: dropped
    try testing.expectEqual(@as(u32, 3), f.idx.pending.count());
    try f.idx.work(f.a(), mem.files(), null, .change_log);
    try testing.expectEqualStrings("", try f.names("add"));
    try testing.expectEqualStrings("welcome ", try f.names("welcome"));
    try testing.expectEqual(stamped + 3, f.idx.stamps);
    try f.idx.setOpen(f.a(), &.{.{ .uri = "file:///w/sub/b.mah", .path = "/w/sub/b.mah", .text = "function edited() end\n" }}, true);
    try testing.expectEqualStrings("edited ", try f.names("edit"));
    try testing.expectEqualStrings("", try f.names("welcome"));
    try f.idx.setOpen(f.a(), &.{}, true);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("", try f.names("edited"));
    try testing.expectEqualStrings("welcome ", try f.names("welcome"));

    // A directory reported once stands for everything under it: deleted, its
    // files go; created (moved in), its files are walked.
    entries[1][0] = "/w/moved/b.mah";
    try f.idx.note("/w/sub", .deleted);
    try f.idx.note("/w/moved", .created);
    try f.settle(&mem, null);
    const moved = try f.idx.search(f.a(), "welcome", 10);
    try testing.expectEqual(@as(usize, 1), moved.len);
    try testing.expectEqualStrings("file:///w/moved/b.mah", moved[0].uri());
    try testing.expect(!f.idx.dirs.contains("/w/sub"));

    // With no change log (a client that cannot watch), every root is walked
    // again, and the stamps still spare the parsing.
    entries[2][0] = "/w/notes.mah";
    const built = f.idx.builds;
    try f.idx.rewalk();
    try f.settle(&mem, null);
    try testing.expectEqualStrings("nope ", try f.names("nope"));
    try testing.expectEqual(built + 1, f.idx.builds);
}

test "symbol index: nested roots keep their own files, and a root that goes takes its files" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "function outer() end\n" },
        .{ "/w/in/b.lua", "function inner() end\n" },
        .{ "/w/in/c.mah", "function both() end\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    var f = Fixture.init();
    defer f.deinit();
    const both = [_]Root{
        .{ .path = "/w", .extensions = &.{".mah"} },
        .{ .path = "/w/in", .extensions = &.{".lua"} },
    };
    try f.idx.setRoots(f.a(), &both, null);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("inner outer ", try f.names(""));
    // The outer root's directory event does not sweep the inner's file.
    try f.idx.note("/w/in", .created);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("inner ", try f.names("inner"));
    // The inner root goes: its file goes, and the outer walks its directory.
    try f.idx.setRoots(f.a(), both[0..1], null);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("both outer ", try f.names(""));
}

test "symbol index: a saved index spares the next session every parse but a changed file's" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "local M = {}\nfunction M.add(a, b) end\nreturn M\n" },
        .{ "/w/b.mah", "function greet() end\n" },
        .{ "/w/c.mah", "function gone() end\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    var store: workspace.MemoryStore = .{ .gpa = testing.allocator };
    defer store.deinit();
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};
    {
        var f = Fixture.init();
        defer f.deinit();
        try f.idx.setRoots(f.a(), &roots, store.store());
        try f.settle(&mem, store.store());
        // Saved once, when the walk ended.
        try testing.expectEqual(@as(u64, 1), f.idx.saves);
        try testing.expectEqual(@as(u64, 3), f.idx.builds);
    }
    // While no server ran: one file changed, one went.
    entries[1][1] = "function hello() end\n";
    entries[2][0] = "/w/c.txt";
    {
        var f = Fixture.init();
        defer f.deinit();
        try f.idx.setRoots(f.a(), &roots, store.store());
        // Loaded at once, before the walk confirms it.
        try testing.expectEqualStrings("M M.add gone greet ", try f.names(""));
        try f.settle(&mem, store.store());
        try testing.expectEqual(@as(u64, 1), f.idx.builds);
        try testing.expectEqualStrings("M M.add hello ", try f.names(""));
        try testing.expectEqualStrings("M.add", (try f.idx.search(f.a(), "add", 1))[0].name());
        try testing.expectEqual(@as(u64, 1), f.idx.saves);
        // Unchanged since: saving at shutdown has nothing to do.
        try f.idx.saveDirty(f.a(), store.store());
        try testing.expectEqual(@as(u64, 1), f.idx.saves);
    }
    // A damaged save, or one in another encoding, is not loaded.
    var saved_it = store.saved.valueIterator();
    const saved = saved_it.next().?.*;
    saved[saved.len - 1] ^= 1;
    {
        var f = Fixture.init();
        defer f.deinit();
        try f.idx.setRoots(f.a(), &roots, store.store());
        try testing.expectEqualStrings("", try f.names(""));
        try f.settle(&mem, store.store());
        try testing.expectEqual(@as(u64, 2), f.idx.builds);
    }
    {
        var f = Fixture.init();
        defer f.deinit();
        try f.idx.setEncoding(.utf8);
        try f.idx.setRoots(f.a(), &roots, store.store());
        try testing.expectEqualStrings("", try f.names(""));
    }
}

test "symbol index: slices of work, and the best matches kept" {
    var paths: [40][2][]const u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A comment line of 1800 dashes pads each file.
    const filler: [1800]u8 = @splat('-');
    for (&paths, 0..) |*p, i| {
        p.* = .{
            try std.fmt.allocPrint(arena.allocator(), "/w/d{d}/f{d}.mah", .{ i % 4, i }),
            try std.fmt.allocPrint(arena.allocator(), "function f{d}_x() end\n{s}\n", .{ i, &filler }),
        };
    }
    var mem: workspace.MemoryFiles = .{ .entries = &paths };
    var f = Fixture.init();
    defer f.deinit();
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};
    try f.idx.setRoots(f.a(), &roots, null);
    // Each file costs about 15 units to parse; a slice takes some of them.
    var slices: usize = 0;
    while (f.idx.busy()) : (slices += 1) try f.idx.work(f.a(), mem.files(), null, .slice);
    try testing.expectEqual(@as(u64, 40), f.idx.builds);
    try testing.expect(slices >= 1);
    // The heap keeps the closest, in order.
    const top = try f.idx.search(f.a(), "f1", 3);
    try testing.expectEqual(@as(usize, 3), top.len);
    try testing.expectEqualStrings("f10_x", top[0].name());
    try testing.expectEqualStrings("f11_x", top[1].name());
    try testing.expectEqualStrings("f12_x", top[2].name());
}

test "symbol index: removed symbols are compacted away, and what is left still reads and saves right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = 3000;
    var paths: [n + 1][2][]const u8 = undefined;
    for (paths[0..n], 0..) |*p, i| {
        p.* = .{
            try std.fmt.allocPrint(arena.allocator(), "/w/f{d}.mah", .{i}),
            try std.fmt.allocPrint(arena.allocator(), "function f{d}()\n  local function g{d}() end\nend\n", .{ i, i }),
        };
    }
    // A file with no symbols holds no place in the columns.
    paths[n] = .{ "/w/empty.mah", "-- nothing here\n" };
    var mem: workspace.MemoryFiles = .{ .entries = &paths };
    var store: workspace.MemoryStore = .{ .gpa = testing.allocator };
    defer store.deinit();
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};
    {
        var f = Fixture.init();
        defer f.deinit();
        try f.idx.setRoots(f.a(), &roots, store.store());
        try f.settle(&mem, store.store());
        try testing.expectEqual(@as(usize, 2 * n), f.idx.symbolCount());
        // All but every sixth file goes: 5000 symbols dead, 1000 live.
        for (paths[0..n], 0..) |*p, i| {
            if (i % 6 == 0) continue;
            const old = p[0];
            p[0] = try std.fmt.allocPrint(arena.allocator(), "{s}.txt", .{old});
            try f.idx.note(old, .deleted);
        }
        try f.settle(&mem, store.store());
        try testing.expectEqual(@as(usize, 1000), f.idx.symbolCount());
        try testing.expectEqual(@as(usize, 1000), f.idx.syms.len);
        try testing.expectEqual(@as(usize, 0), f.idx.dead_syms);
        const g = (try f.idx.search(f.a(), "g2994", 1))[0];
        try testing.expectEqualStrings("g2994", g.name());
        try testing.expectEqualStrings("f2994", g.container().?);
        try testing.expectEqualStrings("file:///w/f2994.mah", g.uri());
        try testing.expectEqual(@as(u32, 1), g.range().start.line);
        try testing.expectEqualStrings("", try f.names("g2995"));
        // An index after compaction still takes a new file and a removal.
        try f.idx.setOpen(f.a(), &.{.{ .uri = "untitled:1", .path = null, .text = "function fresh() end\n" }}, true);
        try testing.expectEqualStrings("fresh ", try f.names("fresh"));
        try f.idx.setOpen(f.a(), &.{}, true);
        try testing.expectEqualStrings("", try f.names("fresh"));
        try f.idx.saveDirty(f.a(), store.store());
    }
    // The saved index holds what was left, names and containers intact.
    {
        var f = Fixture.init();
        defer f.deinit();
        try f.idx.setRoots(f.a(), &roots, store.store());
        try testing.expectEqual(@as(usize, 1000), f.idx.symbolCount());
        const g = (try f.idx.search(f.a(), "g12", 1))[0];
        try testing.expectEqualStrings("g12", g.name());
        try testing.expectEqualStrings("f12", g.container().?);
        try f.settle(&mem, store.store());
        try testing.expectEqual(@as(u64, 0), f.idx.builds);
    }
}

test "symbol index: the closest matches first" {
    try testing.expectEqual(@as(?u8, 0), score("Add", "add"));
    try testing.expectEqual(@as(?u8, 1), score("addAll", "add"));
    try testing.expectEqual(@as(?u8, 2), score("M.add", "add"));
    try testing.expectEqual(@as(?u8, 3), score("M.add", "mad"));
    try testing.expectEqual(@as(?u8, null), score("M.add", "dam"));
    // The mask never rules out a match.
    for ([_][2][]const u8{ .{ "M.add", "mad" }, .{ "Work_12", "WRK_1" }, .{ "a:b", ":" } }) |c| {
        try testing.expectEqual(maskOf(c[1]), maskOf(c[0]) & maskOf(c[1]));
    }
    try testing.expect(maskOf("add") & maskOf("z") != maskOf("z"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const xs = try extensionsOf(arena.allocator(), &.{ "./?.mah", "./?/init.mah", "./?.lua", "lib/?" });
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqualStrings(".lua", xs[1]);
}
