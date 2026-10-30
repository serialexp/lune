//! The workspace symbol index (doc 74 §7.4, P6e): every function and method
//! of every source file in the workspace folders, at any depth, and each
//! file's top-level names, for `workspace/symbol`; and the globals each file
//! uses, with where it uses them, so references and rename of a global
//! answer for the other files without reading them (`filesUsing`,
//! `currentUsers`).
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
const resolve = @import("../resolve.zig");
const syntax = @import("syntax.zig");
const uri_mod = @import("uri.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;

pub const max_files = 200_000;

/// Bump when what an entry holds changes (`syntax.symbols`, `useKey`, the
/// layout below): an index saved by another version is not loaded.
pub const format_version: u32 = 4;

/// What one `work` slice may spend: a stat or a directory listing costs one,
/// a parse one more per 128 bytes of the file. About 5 ms.
pub const slice_budget = 4096;

/// Polling, for a client that cannot watch (`Index.setPolling`): a file is
/// stamped again this long after it changed, the wait doubling with each
/// stamp that finds it unchanged, up to `max_check_ms`, which is then how
/// long an edit made in place to a long-unchanged file can go unseen. Every
/// directory the walks entered is stamped each `dir_round_ms`, and listed
/// again when its stamp moved: a file created, deleted or renamed (and so
/// an editor's save by rename) shows by the next round.
pub const min_check_ms: u32 = 1000;
pub const max_check_ms: u32 = 300_000;
pub const dir_round_ms: u32 = 1000;

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

/// Where a file uses a global: the line and the first character of the
/// name, in the index's encoding.
pub const Spot = struct {
    line: u32,
    character: u32,
};

/// A global a file uses.
pub const Use = struct {
    /// The name, in the entry's strings.
    name: u32,
    name_len: u16,
    /// Its spots in `Entry.spots`, in source order.
    first: u32,
    count: u32,
    /// Which of its spots declares it, its first write (as
    /// `navigation.definition` has it); `no_decl` when nothing writes it.
    decl: u32,

    pub const no_decl = std.math.maxInt(u32);

    /// The name at `s`: an identifier, as long in every encoding as in
    /// bytes, so its end follows from its start.
    pub fn range(u: *const Use, s: Spot) position.Range {
        return .{
            .start = .{ .line = s.line, .character = s.character },
            .end = .{ .line = s.line, .character = s.character + u.name_len },
        };
    }
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
    /// Owned: the `useKey` of each global the file reads or writes (one per
    /// `uses`, in order), then that of each other name it declares (a local,
    /// a parameter, a loop variable), which is all a rename needs to know of
    /// which files could capture its new name.
    keys: []u64,
    /// The globals, and where each is used. Owned.
    uses: []Use,
    spots: []Spot,
    /// The parser dropped some of its text, whose names are unknown here.
    damaged: bool,
    /// Its slot in `Index.slots`.
    id: u32,
    /// When polling, a file's: when it is next stamped, and the wait after
    /// an unchanged stamp is doubled from (see `min_check_ms`).
    check_at: u64,
    check_ms: u32,
    /// Parsed after a change: at its next stamp it is parsed once more even
    /// if the stamp holds, since a rewrite of the same size in the same tick
    /// of a coarse clock as the read leaves the stamp as it was.
    again: bool,
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

    /// The global `name`, if the file uses it.
    pub fn use(e: *const Entry, name: []const u8) ?*const Use {
        const want = useKey(name);
        for (e.keys[0..e.uses.len], e.uses) |k, *u| {
            if (k == want and std.mem.eql(u8, e.useName(u), name)) return u;
        }
        return null;
    }

    pub fn useName(e: *const Entry, u: *const Use) []const u8 {
        return e.strings[u.name..][0..u.name_len];
    }

    pub fn spotsOf(e: *const Entry, u: *const Use) []const Spot {
        return e.spots[u.first..][0..u.count];
    }

    /// Whether the file declares a name spelled `name`, other than a global.
    /// Now and then yes for a name only sharing its `useKey`, which costs
    /// the caller a read, not a wrong answer.
    pub fn declares(e: *const Entry, name: []const u8) bool {
        return std.mem.indexOfScalar(u64, e.keys[e.uses.len..], useKey(name)) != null;
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
    /// A walk of the whole root has ended: a file found from here on is new.
    known: bool = false,

    fn view(r: *const RootState) Root {
        return .{ .path = r.path, .extensions = @ptrCast(r.extensions) };
    }
};

pub const Change = enum { created, changed, deleted };

/// A directory being polled: its stamp when last listed (null for a root
/// that is not there), and whether to list it once more though the stamp
/// holds, since a change in the same tick of a coarse clock as the listing
/// leaves the stamp as it was.
const Polled = struct {
    stamp: ?workspace.Files.Stamp,
    again: bool = false,
};

/// A file entry's next stamp, by its slot. Stale when the slot is empty or
/// its entry's `check_at` differs: skipped when it comes up.
const Due = struct {
    at: u64,
    id: u32,

    fn order(_: void, x: Due, y: Due) std.math.Order {
        return std.math.order(x.at, y.at);
    }
};

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
    /// Polling the disk, for a client that cannot watch: `setPolling`.
    polling: bool = false,
    /// The host's clock, as `advance` last said.
    now_ms: u64 = 0,
    /// Every directory the walks entered while polling, keys owned.
    polled: std.StringArrayHashMapUnmanaged(Polled) = .empty,
    /// The round of directory stamps: the next one to stamp, and when the
    /// next round begins (at or before `now_ms`: one is under way).
    dir_cursor: usize = 0,
    dir_round_at: u64 = 0,
    /// The file entries by when they are next stamped.
    due: std.PriorityQueue(Due, void, Due.order) = .empty,
    /// The directories listed again in this pass, keys owned: a file entry
    /// directly in one that this pass did not see is gone.
    relisted: std.StringHashMapUnmanaged(void) = .empty,
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
        self.relisted.deinit(self.gpa);
        self.freePolled();
        self.polled.deinit(self.gpa);
        self.due.deinit(self.gpa);
    }

    fn freePolled(self: *Index) void {
        for (self.polled.keys()) |k| self.gpa.free(k);
        self.polled.clearRetainingCapacity();
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
        self.due.clearRetainingCapacity();
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
        freeKeys(self.gpa, &self.relisted);
    }

    fn free(self: *Index, e: *Entry) void {
        self.gpa.free(e.keys);
        self.gpa.free(e.uses);
        self.gpa.free(e.spots);
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
        for (self.roots.items) |*r| r.known = false;
        try self.rewalk();
    }

    /// The host's clock is now `now_ms`: what polling is due by, and what
    /// a new entry is scheduled from.
    pub fn advance(self: *Index, now_ms: u64) void {
        self.now_ms = @max(self.now_ms, now_ms);
    }

    /// Poll the disk, for a client that cannot watch: the walks record each
    /// directory's stamp, and `work` stamps the directories each round and
    /// the files as they come due (see `min_check_ms`). Turned on, every root
    /// is walked again to record its directories (the stamps spare the
    /// parsing).
    pub fn setPolling(self: *Index, on: bool) Allocator.Error!void {
        if (on == self.polling) return;
        self.polling = on;
        self.freePolled();
        self.due.clearRetainingCapacity();
        if (!on) return;
        try self.rebuildDue();
        self.dir_cursor = 0;
        self.dir_round_at = self.now_ms + dir_round_ms;
        try self.rewalk();
    }

    /// When `work` next has polling to do, in the host's clock; null when
    /// there is none to come.
    pub fn nextPoll(self: *const Index) ?u64 {
        if (!self.polling) return null;
        var at: ?u64 = if (self.polled.count() > 0) self.dir_round_at else null;
        if (self.due.peek()) |d| at = if (at) |x| @min(x, d.at) else d.at;
        return at;
    }

    /// Walk every root again.
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
                .known = if (old) |o| o.known else false,
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
            try self.update(key, d.uri, stamp, d.text, true, d.path != null, .if_changed);
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
            } else if (try self.pollOne(scratch, fs)) |cost| {
                spent += cost;
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
            if (hasExtension(path, root.extensions)) return 1 + try self.indexFile(scratch, fs, path, stamp, .if_changed);
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
        // Stamped before it is listed: a change while listing shows next round.
        const stamp = if (self.polling) fs.dir_stamp.?(fs.ctx, dir) else null;
        const cost = try self.listDir(scratch, fs, dir, .all) orelse return 1;
        if (self.polling) {
            const slot = try self.polled.getOrPut(self.gpa, dir);
            if (!slot.found_existing) {
                slot.key_ptr.* = self.gpa.dupe(u8, dir) catch |err| {
                    self.polled.swapRemoveAt(slot.index);
                    return err;
                };
            }
            slot.value_ptr.* = .{ .stamp = stamp };
        }
        return cost;
    }

    /// Queue `dir`'s source files for the walk, and its directories: all of
    /// them, or only those not polled yet (`relist`). Null when it cannot be
    /// listed; else what the listing cost.
    fn listDir(self: *Index, scratch: Allocator, fs: workspace.Files, dir: []const u8, comptime dirs: enum { all, new }) Allocator.Error!?u64 {
        const root = innermost(self.roots.items, dir) orelse return null;
        const listing = fs.list.?(fs.ctx, scratch, dir) orelse return null;
        for (listing) |e| {
            if (isSkipped(e.name)) continue;
            const path = try std.fs.path.resolveAllocPosix(scratch, &.{ dir, e.name });
            switch (e.kind) {
                .directory => {
                    if (isRoot(self.roots.items, path)) continue;
                    if (dirs == .new and self.polled.contains(path)) continue;
                    try self.pushOwned(&self.walk_dirs, path);
                    // A new directory under a polled one: what was indexed
                    // under it before it went is swept.
                    if (dirs == .new) try putKey(self.gpa, &self.scopes, path);
                },
                .file => if (hasExtension(e.name, root.extensions)) try self.pushOwned(&self.walk_files, path),
            }
        }
        return 1 + listing.len / 16;
    }

    // ---- polling --------------------------------------------------------

    /// One piece of the polling that is due: the next directory of a round
    /// under way, else the next file. Null when nothing is due.
    fn pollOne(self: *Index, scratch: Allocator, fs: workspace.Files) Allocator.Error!?u64 {
        if (!self.polling) return null;
        if (self.polled.count() > 0 and self.dir_round_at <= self.now_ms) {
            if (self.dir_cursor < self.polled.count()) return try self.checkDir(scratch, fs);
            self.dir_cursor = 0;
            self.dir_round_at = self.now_ms + dir_round_ms;
        }
        while (self.due.peek()) |d| {
            if (d.at > self.now_ms) return null;
            _ = self.due.pop();
            const e = self.slots.items[d.id] orelse continue;
            if (e.check_at != d.at or e.document or !e.file) continue;
            return try self.checkFile(scratch, fs, e);
        }
        return null;
    }

    /// Stamp the round's next directory. Moved, it is listed again; gone,
    /// its files and the directories under it go (a root stays polled, to be
    /// walked when it is back).
    fn checkDir(self: *Index, scratch: Allocator, fs: workspace.Files) Allocator.Error!u64 {
        const i = self.dir_cursor;
        self.dir_cursor += 1;
        const dir = try scratch.dupe(u8, self.polled.keys()[i]);
        const was = self.polled.values()[i];
        self.stamps += 1;
        const stamp = fs.dir_stamp.?(fs.ctx, dir);
        const moved = !optionalEql(stamp, was.stamp);
        if (!moved and !was.again) return 1;
        if (stamp == null) {
            try self.removeUnder(scratch, dir);
            self.dropPolledUnder(dir);
            // What was swapped into this place is stamped next.
            self.dir_cursor = @min(i, self.polled.count());
            return 1;
        }
        self.polled.values()[i] = .{ .stamp = stamp, .again = moved };
        if (was.stamp == null) {
            // Back (a root, or a directory that was briefly not one): walked whole.
            try self.pushOwned(&self.walk_dirs, dir);
            try putKey(self.gpa, &self.scopes, dir);
            return 1;
        }
        const cost = try self.listDir(scratch, fs, dir, .new) orelse return 1;
        try putKey(self.gpa, &self.relisted, dir);
        return cost;
    }

    /// Stop polling `dir` and every directory under it, but a root, which
    /// is kept with no stamp.
    fn dropPolledUnder(self: *Index, dir: []const u8) void {
        var k: usize = 0;
        while (k < self.polled.count()) {
            const key = self.polled.keys()[k];
            if (!within(dir, key)) {
                k += 1;
            } else if (isRoot(self.roots.items, key)) {
                self.polled.values()[k] = .{ .stamp = null };
                k += 1;
            } else {
                self.gpa.free(key);
                self.polled.swapRemoveAt(k);
            }
        }
    }

    /// Stamp a file that came due: unchanged, its wait doubles; changed, it
    /// is parsed again; gone, it goes. A file parsed after a change is
    /// parsed once more at its next stamp (`Entry.again`).
    fn checkFile(self: *Index, scratch: Allocator, fs: workspace.Files, e: *Entry) Allocator.Error!u64 {
        self.stamps += 1;
        const path = try scratch.dupe(u8, e.key());
        const stamp = fs.stamp.?(fs.ctx, path) orelse {
            self.remove(path);
            return 1;
        };
        const changed = !std.meta.eql(stamp, e.stamp);
        const again = e.again;
        // Changed, it is checked again soon even if it cannot be read now
        // (indexed again, its new entry is scheduled afresh).
        e.check_ms = if (changed) min_check_ms else @min(e.check_ms *| 2, max_check_ms);
        e.check_at = self.now_ms + e.check_ms;
        try self.pushDue(e);
        if (!changed and !again) return 1;
        const cost = 1 + try self.indexFile(scratch, fs, path, stamp, if (changed) .if_changed else .always);
        if (!changed) if (self.entries.get(path)) |n| {
            // Confirmed: on as a file found unchanged.
            n.again = false;
            n.check_ms = 2 * min_check_ms;
            n.check_at = self.now_ms + n.check_ms;
            try self.pushDue(n);
        };
        return cost;
    }

    const Origin = enum { changed, found };

    /// Give a file entry its first stamp when polling: soon after a change,
    /// or for a file found once its root's walk has ended (a new file);
    /// else (a first walk's, or a saved index's) at a point spread over
    /// `max_check_ms` by its path, so the stamps do not come in one burst.
    fn schedule(self: *Index, e: *Entry, why: Origin) Allocator.Error!void {
        if (e.document or !e.file) return;
        const new = why == .changed or if (innermostState(self.roots.items, e.key())) |r| r.known else false;
        e.again = new;
        if (new) {
            e.check_ms = min_check_ms;
            e.check_at = self.now_ms + min_check_ms;
        } else {
            e.check_ms = max_check_ms;
            e.check_at = self.now_ms + std.hash.Wyhash.hash(1, e.key()) % max_check_ms;
        }
        if (self.polling) try self.pushDue(e);
    }

    /// Queue `e`'s next stamp; the queue is rebuilt once stale items (from
    /// entries gone or rescheduled) outnumber the entries.
    fn pushDue(self: *Index, e: *const Entry) Allocator.Error!void {
        if (self.due.count() > 2 * @as(usize, self.entries.count()) + 4096) return self.rebuildDue();
        try self.due.push(self.gpa, .{ .at = e.check_at, .id = e.id });
    }

    fn rebuildDue(self: *Index) Allocator.Error!void {
        self.due.clearRetainingCapacity();
        try self.due.ensureTotalCapacity(self.gpa, self.entries.count());
        var it = self.entries.valueIterator();
        while (it.next()) |ep| {
            const e = ep.*;
            if (!e.document and e.file) try self.due.push(self.gpa, .{ .at = e.check_at, .id = e.id });
        }
    }

    fn walkFile(self: *Index, scratch: Allocator, fs: workspace.Files, path: []const u8) Allocator.Error!u64 {
        if (self.stopped) return 0;
        if (self.entries.get(path)) |e| if (e.document or e.seen == self.pass) return 0;
        self.stamps += 1;
        const stamp = fs.stamp.?(fs.ctx, path) orelse return 1;
        return 1 + try self.indexFile(scratch, fs, path, stamp, .if_changed);
    }

    const Parse = enum { if_changed, always };

    /// Index the file at `path`, unless it is indexed at `stamp` already
    /// (and `parse` is `.if_changed`). Returns what the parse cost.
    fn indexFile(self: *Index, scratch: Allocator, fs: workspace.Files, path: []const u8, stamp: workspace.Files.Stamp, parse: Parse) Allocator.Error!u64 {
        const old = self.entries.get(path);
        if (old) |e| if (parse == .if_changed and std.meta.eql(e.stamp, stamp)) {
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
        try self.update(path, try uri_mod.fromPath(scratch, path), stamp, text, false, true, parse);
        return text.len / 128;
    }

    /// The pass is over when no work is left: what its walks did not see
    /// again is swept, and the roots it walked whole are saved.
    fn endPassIfIdle(self: *Index, scratch: Allocator, store: ?workspace.Store) Allocator.Error!void {
        try self.compactIfWasteful();
        if (self.busy()) return;
        if (!self.stopped and (self.scopes.count() > 0 or self.relisted.count() > 0)) try self.sweep(scratch);
        for (self.roots.items) |*r| {
            if (r.walking and r.dirty) if (store) |st| try self.save(scratch, r, st);
            if (r.walking and !self.stopped) r.known = true;
            r.walking = false;
        }
        freeKeys(self.gpa, &self.scopes);
        freeKeys(self.gpa, &self.relisted);
        self.stopped = false;
        self.pass +%= 1;
    }

    /// Drop each entry from a file that this pass did not see, if it lies
    /// directly in a directory listed again, or in a walked scope under the
    /// scope's own root (a nested root's files are its own).
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
            if (std.fs.path.dirnamePosix(key)) |parent| if (self.relisted.contains(parent)) {
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

    /// Index `text` under `key`, unless it is indexed at `stamp` already
    /// (and `parse` is `.if_changed`).
    fn update(self: *Index, key: []const u8, uri: []const u8, stamp: workspace.Files.Stamp, text: []const u8, document: bool, file: bool, parse: Parse) Allocator.Error!void {
        var had = false;
        if (self.entries.get(key)) |old| {
            if (parse == .if_changed and old.document == document and std.meta.eql(old.stamp, stamp)) {
                old.seen = self.pass;
                return;
            }
            had = true;
            self.remove(key);
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const parsed = try self.parseText(scratch.allocator(), text);
        try self.insertFound(key, uri, stamp, parsed, self.pass, document, file);
        try self.schedule(self.entries.get(key).?, if (had) .changed else .found);
    }

    /// Add an entry under `key` (none there yet) holding what `p` found.
    fn insertFound(self: *Index, key: []const u8, uri: []const u8, stamp: workspace.Files.Stamp, p: Parsed, seen: u32, document: bool, file: bool) Allocator.Error!void {
        const found = p.found;
        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        var names: usize = 0;
        for (p.uses) |u| names += u.name.len;
        e.strings = try self.gpa.alloc(u8, key.len + uri.len + names);
        errdefer self.gpa.free(e.strings);
        e.keys = try self.gpa.alloc(u64, p.uses.len + p.declared.len);
        errdefer self.gpa.free(e.keys);
        e.uses = try self.gpa.alloc(Use, p.uses.len);
        errdefer self.gpa.free(e.uses);
        e.spots = try self.gpa.dupe(Spot, p.spots);
        errdefer self.gpa.free(e.spots);
        @memcpy(e.strings[0..key.len], key);
        @memcpy(e.strings[key.len..][0..uri.len], uri);
        var at = key.len + uri.len;
        for (p.uses, e.uses, e.keys[0..p.uses.len]) |u, *slot, *k| {
            @memcpy(e.strings[at..][0..u.name.len], u.name);
            slot.* = .{ .name = @intCast(at), .name_len = @intCast(u.name.len), .first = u.first, .count = u.count, .decl = u.decl };
            k.* = useKey(u.name);
            at += u.name.len;
        }
        @memcpy(e.keys[p.uses.len..], p.declared);
        e.damaged = p.damaged;
        e.key_len = @intCast(key.len);
        e.uri_len = @intCast(uri.len);
        e.stamp = stamp;
        e.seen = seen;
        e.document = document;
        e.file = file;
        e.check_at = 0;
        e.check_ms = max_check_ms;
        e.again = false;

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

    /// A global as parsed (or read back from a save): its spots are
    /// `Parsed.spots[first..][0..count]`.
    const FoundUse = struct {
        name: []const u8,
        first: u32,
        count: u32,
        decl: u32,
    };

    const Parsed = struct {
        found: []const Found = &.{},
        uses: []const FoundUse = &.{},
        spots: []const Spot = &.{},
        /// The `useKey` of each other name declared, once each.
        declared: []const u64 = &.{},
        damaged: bool = false,
    };

    /// The symbols of `text`, and the globals it uses and where, allocated
    /// in `a` (scratch).
    fn parseText(self: *Index, a: Allocator, text: []const u8) Allocator.Error!Parsed {
        self.builds += 1;
        const source = try a.dupeSentinel(u8, text, 0);
        var diags = diag.Diagnostics.init(self.gpa);
        defer diags.deinit();
        var tree = parser.parse(self.gpa, source, &diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => return .{},
        };
        defer tree.deinit();
        const outline = try syntax.symbols(a, tree.root);
        var index = position.LineIndex.build(self.gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TextTooLong => return .{},
        };
        defer index.deinit(self.gpa);
        var out: std.ArrayList(Found) = .empty;
        try flatten(a, &out, outline, null, &index, text, self.encoding);

        var res = try resolve.resolve(self.gpa, tree.root, @intCast(source.len));
        defer res.deinit();
        var parsed = try collectUses(a, &res, &index, text, self.encoding);
        parsed.found = out.items;
        return parsed;
    }

    /// The globals `res` resolved (one binding per name), each with its
    /// spots in `enc`, and the keys of the other names it declares.
    fn collectUses(a: Allocator, res: *const resolve.Resolution, index: *const position.LineIndex, text: []const u8, enc: position.Encoding) Allocator.Error!Parsed {
        const none = std.math.maxInt(u32);
        const bindings = res.bindings.items;
        // Each binding's place in `uses`, if it is a global's.
        const place = try a.alloc(u32, bindings.len);
        var uses: std.ArrayList(FoundUse) = .empty;
        var declared: std.ArrayList(u64) = .empty;
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (bindings, place) |b, *at| {
            at.* = none;
            if (b.kind != .global) {
                const k = useKey(b.name);
                if (!(try seen.getOrPut(a, k)).found_existing) try declared.append(a, k);
            } else if (b.name.len <= std.math.maxInt(u16)) {
                at.* = @intCast(uses.items.len);
                try uses.append(a, .{ .name = b.name, .first = 0, .count = 0, .decl = Use.no_decl });
            }
        }
        const occs = res.occurrences.items;
        for (occs) |o| {
            const at = place[o.binding];
            if (at != none) uses.items[at].count += 1;
        }
        var total: u32 = 0;
        for (uses.items) |*u| {
            u.first = total;
            total += u.count;
            u.count = 0;
        }
        // The occurrences are in source order, so the cursor only moves on.
        const spots = try a.alloc(Spot, total);
        var cur = position.Cursor.init(index, text, enc);
        for (occs) |o| {
            const at = place[o.binding];
            if (at == none) continue;
            const u = &uses.items[at];
            const writes = o.access == .write or o.access == .read_write;
            if (writes and o.span.start == bindings[o.binding].decl_span.start) u.decl = u.count;
            const pos = cur.positionOf(o.span.start);
            spots[u.first + u.count] = .{ .line = pos.line, .character = pos.character };
            u.count += 1;
        }
        return .{ .uses = uses.items, .spots = spots, .declared = declared.items, .damaged = res.damaged.items.len > 0 };
    }

    // ---- the saved index ------------------------------------------------
    //
    // One file per root, named by a hash of its path: "MHSI", the format
    // version, a Wyhash of the rest, then the encoding, the root's path and
    // extensions, and each file's entry: lengths, stamp, whether it is
    // damaged, its strings (key, uri, global names, symbol names), its
    // symbols with their name offsets into those strings, its globals (name
    // offset, spots), the keys of its other names, and its spots.
    // Little-endian. Anything that does not check out is ignored whole: the
    // walk rebuilds.

    const magic = "MHSI";
    const header_bytes = magic.len + 4 + 8;
    const entry_bytes = 4 + 4 + 4 + 8 + 16 + 4 + 4 + 4 + 4 + 1;
    const symbol_bytes = 16 + 4 + 4 + 2 + 2 + 1;
    const use_bytes = 4 + 2 + 4 + 4 + 4;
    const spot_bytes = 4 + 4;

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
            if (self.savedWith(e, root.path)) size += entry_bytes + e.strings.len + e.pool_len + @as(usize, e.len) * symbol_bytes +
                use_bytes * e.uses.len + 8 * (e.keys.len - e.uses.len) + spot_bytes * e.spots.len;
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
            const base: u32 = @intCast(e.strings.len);
            putInt(&out, u32, base + e.pool_len);
            putInt(&out, u32, e.key_len);
            putInt(&out, u32, e.uri_len);
            putInt(&out, u64, e.stamp.size);
            putInt(&out, i128, e.stamp.mtime_ns);
            putInt(&out, u32, e.len);
            putInt(&out, u32, @intCast(e.uses.len));
            putInt(&out, u32, @intCast(e.keys.len - e.uses.len));
            putInt(&out, u32, @intCast(e.spots.len));
            putInt(&out, u8, @intFromBool(e.damaged));
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
            for (e.uses) |u| {
                putInt(&out, u32, u.name);
                putInt(&out, u16, u.name_len);
                putInt(&out, u32, u.first);
                putInt(&out, u32, u.count);
                putInt(&out, u32, u.decl);
            }
            for (e.keys[e.uses.len..]) |k| putInt(&out, u64, k);
            for (e.spots) |s| {
                putInt(&out, u32, s.line);
                putInt(&out, u32, s.character);
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
        var uses: std.ArrayList(FoundUse) = .empty;
        defer uses.deinit(self.gpa);
        var declared: std.ArrayList(u64) = .empty;
        defer declared.deinit(self.gpa);
        var spots: std.ArrayList(Spot) = .empty;
        defer spots.deinit(self.gpa);
        const n = try r.int(u32);
        for (0..n) |_| {
            const strings_len = try r.int(u32);
            const key_len = try r.int(u32);
            const uri_len = try r.int(u32);
            const size = try r.int(u64);
            const mtime = try r.int(i128);
            const symbol_count = try r.int(u32);
            const use_count = try r.int(u32);
            const declared_count = try r.int(u32);
            const spot_count = try r.int(u32);
            const damaged = switch (try r.int(u8)) {
                0 => false,
                1 => true,
                else => return error.Corrupt,
            };
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
            if (@as(u64, use_count) * use_bytes > r.bytes.len - r.at) return error.Corrupt;
            uses.clearRetainingCapacity();
            try uses.ensureTotalCapacity(self.gpa, use_count);
            for (0..use_count) |_| {
                const name_at = try r.int(u32);
                const name_len = try r.int(u16);
                const first = try r.int(u32);
                const spot_n = try r.int(u32);
                const decl = try r.int(u32);
                if (name_len == 0 or @as(u64, name_at) + name_len > strings_len) return error.Corrupt;
                if (@as(u64, first) + spot_n > spot_count or spot_n == 0) return error.Corrupt;
                if (decl != Use.no_decl and decl >= spot_n) return error.Corrupt;
                uses.appendAssumeCapacity(.{ .name = strings[name_at..][0..name_len], .first = first, .count = spot_n, .decl = decl });
            }
            if (@as(u64, declared_count) * 8 > r.bytes.len - r.at) return error.Corrupt;
            declared.clearRetainingCapacity();
            try declared.ensureTotalCapacity(self.gpa, declared_count);
            for (0..declared_count) |_| declared.appendAssumeCapacity(try r.int(u64));
            if (@as(u64, spot_count) * spot_bytes > r.bytes.len - r.at) return error.Corrupt;
            spots.clearRetainingCapacity();
            try spots.ensureTotalCapacity(self.gpa, spot_count);
            for (0..spot_count) |_| spots.appendAssumeCapacity(.{ .line = try r.int(u32), .character = try r.int(u32) });
            const key = strings[0..key_len];
            const owner = innermost(self.roots.items, key);
            const ours = owner != null and std.mem.eql(u8, owner.?.path, root.path);
            if (!ours or self.entries.contains(key)) continue;
            const stamp: workspace.Files.Stamp = .{ .size = size, .mtime_ns = @intCast(mtime) };
            try added.ensureUnusedCapacity(scratch, 1);
            try self.insertFound(key, strings[key_len..][0..uri_len], stamp, .{
                .found = found.items,
                .uses = uses.items,
                .spots = spots.items,
                .declared = declared.items,
                .damaged = damaged,
            }, 0, false, true);
            const e = self.entries.get(key).?;
            added.appendAssumeCapacity(e.key());
            try self.schedule(e, .found);
        }
        if (r.at != bytes.len) return error.Corrupt;
    }

    // ---- searching ------------------------------------------------------

    /// The entries of the files and documents that use the global `name`,
    /// as indexed. Allocated in `a`, valid until the index changes. One pass
    /// over every entry's keys (a name is compared only on a key's match): a
    /// few ms at 100k files.
    pub fn filesUsing(self: *const Index, a: Allocator, name: []const u8) Allocator.Error![]const *const Entry {
        const want = useKey(name);
        var out: std.ArrayList(*const Entry) = .empty;
        for (self.slots.items) |slot| {
            const e = slot orelse continue;
            if (std.mem.indexOfScalar(u64, e.keys[0..e.uses.len], want) == null) continue;
            if (e.use(name) != null) try out.append(a, e);
        }
        return out.items;
    }

    pub const Users = struct {
        entries: []const *const Entry,
        /// A file among them changed and could not be read again: it is
        /// left out.
        unreadable: bool,
    };

    /// `filesUsing`, with every file among them made current first, so
    /// their spots can be trusted: each is stamped, and one whose stamp
    /// moved (or that a coarse clock may hide a rewrite of, `Entry.again`)
    /// is parsed again, or dropped if it is gone. A stat per file, and a
    /// parse per changed one. Open documents are current already.
    pub fn currentUsers(self: *Index, scratch: Allocator, fs: workspace.Files, name: []const u8) Allocator.Error!Users {
        const Stale = struct { path: []const u8, stamp: ?workspace.Files.Stamp };
        var stale: std.ArrayList(Stale) = .empty;
        for (try self.filesUsing(scratch, name)) |e| {
            if (e.document or !e.file) continue;
            self.stamps += 1;
            const stamp = fs.stamp.?(fs.ctx, e.key());
            const moved = stamp == null or !std.meta.eql(stamp.?, e.stamp);
            if (moved or (self.polling and e.again)) try stale.append(scratch, .{ .path = try scratch.dupe(u8, e.key()), .stamp = stamp });
        }
        var unreadable = false;
        for (stale.items) |s| {
            const stamp = s.stamp orelse {
                self.remove(s.path);
                continue;
            };
            _ = try self.indexFile(scratch, fs, s.path, stamp, .always);
            const e = self.entries.get(s.path) orelse continue;
            if (!std.meta.eql(e.stamp, stamp)) {
                // Not read: what it holds is from before the change.
                unreadable = true;
                self.remove(s.path);
            }
        }
        return .{ .entries = try self.filesUsing(scratch, name), .unreadable = unreadable };
    }

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

/// The key an entry keeps of a name, to rule most entries out without
/// comparing names: a hash of it. Saved, so changing it means a new
/// `format_version`.
pub fn useKey(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

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

fn isRoot(roots: []const RootState, path: []const u8) bool {
    for (roots) |r| {
        if (std.mem.eql(u8, r.path, path)) return true;
    }
    return false;
}

fn optionalEql(x: ?workspace.Files.Stamp, y: ?workspace.Files.Stamp) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.meta.eql(x.?, y.?);
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

/// The keys of the entries `filesUsing` gives for `name`, each followed by
/// a space, in key order.
fn usersOf(f: *Fixture, name: []const u8) ![]const u8 {
    const users = try f.a().dupe(*const Entry, try f.idx.filesUsing(f.a(), name));
    std.mem.sort(*const Entry, users, {}, struct {
        fn lt(_: void, x: *const Entry, y: *const Entry) bool {
            return std.mem.order(u8, x.key(), y.key()) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (users) |e| {
        try out.appendSlice(f.a(), e.key());
        try out.append(f.a(), ' ');
    }
    return out.items;
}

/// Where the entry at `key` uses the global `name`: `line:character` for
/// each spot, a `*` after the one declaring it.
fn spotsOf(f: *Fixture, key: []const u8, name: []const u8) ![]const u8 {
    const e = f.idx.entries.get(key).?;
    const u = e.use(name) orelse return "";
    var out: std.ArrayList(u8) = .empty;
    for (e.spotsOf(u), 0..) |s, i| {
        try out.print(f.a(), "{d}:{d}{s} ", .{ s.line, s.character, if (i == u.decl) "*" else "" });
    }
    return out.items;
}

test "symbol index: the files using a global, as walked, edited, opened and saved" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "counter = 0\nfunction bump() counter = counter + 1 end\n" },
        .{ "/w/b.mah", "local counter = 5\nprint(counter, bump)\n" },
        .{ "/w/c.mah", "local t = {}\nt.counter = 1\nprint(t, counter)\n" },
        .{ "/w/d.mah", "_G.counter = 3\n" },
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
        // b's `counter` is a local, and a field is no global unless it is
        // one of the globals table.
        try testing.expectEqualStrings("/w/a.mah /w/c.mah /w/d.mah ", try usersOf(&f, "counter"));
        try testing.expectEqualStrings("/w/a.mah /w/b.mah ", try usersOf(&f, "bump"));
        try testing.expectEqualStrings("/w/b.mah /w/c.mah ", try usersOf(&f, "print"));
        try testing.expectEqualStrings("", try usersOf(&f, "t"));
        // Where: the first write declares it; through `_G` too.
        try testing.expectEqualStrings("0:0* 1:16 1:26 ", try spotsOf(&f, "/w/a.mah", "counter"));
        try testing.expectEqualStrings("2:9 ", try spotsOf(&f, "/w/c.mah", "counter"));
        try testing.expectEqualStrings("0:3* ", try spotsOf(&f, "/w/d.mah", "counter"));
        // The other names each declares.
        try testing.expect(f.idx.entries.get("/w/b.mah").?.declares("counter"));
        try testing.expect(f.idx.entries.get("/w/c.mah").?.declares("t"));
        try testing.expect(!f.idx.entries.get("/w/a.mah").?.declares("counter"));

        // An open document is read as edited.
        const opened = [_]Open{.{ .uri = "file:///w/b.mah", .path = "/w/b.mah", .text = "counter = 2\n" }};
        try f.idx.setOpen(f.a(), &opened, true);
        try testing.expectEqualStrings("/w/a.mah /w/b.mah /w/c.mah /w/d.mah ", try usersOf(&f, "counter"));
        try testing.expectEqualStrings("/w/a.mah ", try usersOf(&f, "bump"));
        try f.idx.setOpen(f.a(), &.{}, true);
        try f.settle(&mem, store.store());
        try testing.expectEqualStrings("/w/a.mah /w/b.mah ", try usersOf(&f, "bump"));
    }
    // The next session has them from the save, with nothing parsed.
    var f = Fixture.init();
    defer f.deinit();
    try f.idx.setRoots(f.a(), &roots, store.store());
    try f.settle(&mem, store.store());
    try testing.expectEqual(@as(u64, 0), f.idx.builds);
    try testing.expectEqualStrings("/w/a.mah /w/c.mah /w/d.mah ", try usersOf(&f, "counter"));
    try testing.expectEqualStrings("/w/a.mah /w/b.mah ", try usersOf(&f, "bump"));
    try testing.expectEqualStrings("0:0* 1:16 1:26 ", try spotsOf(&f, "/w/a.mah", "counter"));
    try testing.expectEqualStrings("0:3* ", try spotsOf(&f, "/w/d.mah", "counter"));
    try testing.expect(f.idx.entries.get("/w/b.mah").?.declares("counter"));

    // Made current before its spots are trusted: a file changed on disk is
    // parsed again (the one only), one gone is dropped.
    entries[0][1] = "\n\ncounter = 1\n";
    entries[3][0] = "/w/gone.lua";
    const users = try f.idx.currentUsers(f.a(), mem.files(), "counter");
    try testing.expectEqual(@as(usize, 2), users.entries.len);
    try testing.expect(!users.unreadable);
    try testing.expectEqual(@as(u64, 1), f.idx.builds);
    try testing.expectEqualStrings("2:0* ", try spotsOf(&f, "/w/a.mah", "counter"));
    try testing.expectEqualStrings("/w/a.mah /w/c.mah ", try usersOf(&f, "counter"));
}

test "symbol index: spots are in the client's encoding, and damage is kept" {
    // `é` is two bytes, one UTF-16 unit; `😀` four bytes, two units.
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "local s = \"é😀\" .. shared\nlocal = shared\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};
    var f = Fixture.init();
    defer f.deinit();
    try f.idx.setRoots(f.a(), &roots, null);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("0:19 ", try spotsOf(&f, "/w/a.mah", "shared"));
    try testing.expect(f.idx.entries.get("/w/a.mah").?.damaged);
    try f.idx.setEncoding(.utf8);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("0:22 ", try spotsOf(&f, "/w/a.mah", "shared"));
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

test "symbol index: polling sees a directory's changes by its stamp, and an edit in place when the file comes due" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "function alpha() end\n" },
        .{ "/w/sub/b.mah", "function beta() end\n" },
        .{ "/elsewhere/c.mah", "function gamma() end\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    var f = Fixture.init();
    defer f.deinit();
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};
    try f.idx.setRoots(f.a(), &roots, null);
    try f.idx.setPolling(true);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("alpha beta ", try f.names(""));
    try testing.expectEqual(@as(usize, 2), f.idx.polled.count());
    try testing.expectEqual(@as(?u64, dir_round_ms), f.idx.nextPoll());

    // A file created shows at the next round of directory stamps, and is
    // checked again a second later.
    entries[2][0] = "/w/sub/c.mah";
    f.idx.advance(1000);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("gamma ", try f.names("gamma"));
    const c = f.idx.entries.get("/w/sub/c.mah").?;
    try testing.expectEqual(@as(u64, 2000), c.check_at);

    // An edit in place does not move its directory's stamp: it shows when
    // the file comes due, within `max_check_ms` for a file never changed.
    entries[0][1] = "function delta() end\n";
    f.idx.advance(2000);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("", try f.names("delta"));
    f.idx.advance(2000 + max_check_ms);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("delta ", try f.names("delta"));

    // Left alone, a file's wait doubles up to the most; a round of
    // directories is one stamp each.
    var t: u64 = 2000 + max_check_ms;
    while (t < 2000 + 3 * max_check_ms) : (t += 1000) {
        f.idx.advance(t);
        try f.settle(&mem, null);
    }
    try testing.expectEqual(max_check_ms, f.idx.entries.get("/w/sub/c.mah").?.check_ms);
    const stamped = f.idx.stamps;
    f.idx.advance(t);
    try f.settle(&mem, null);
    try testing.expect(f.idx.stamps - stamped <= 2 + 3);

    // A file deleted goes at the next round; a directory deleted takes its
    // files, and is no longer polled.
    entries[0][0] = "/elsewhere/a.mah";
    t += 1000;
    f.idx.advance(t);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("beta gamma ", try f.names(""));
    entries[1][0] = "/elsewhere/b.mah";
    entries[2][0] = "/elsewhere/c2.mah";
    t += 1000;
    f.idx.advance(t);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("", try f.names(""));
    try testing.expectEqual(@as(usize, 1), f.idx.polled.count());

    // The directory back: walked whole at the next round of its parent.
    entries[1][0] = "/w/sub/b.mah";
    t += 1000;
    f.idx.advance(t);
    try f.settle(&mem, null);
    try testing.expectEqualStrings("beta ", try f.names(""));
    try testing.expectEqual(@as(usize, 2), f.idx.polled.count());
}

/// A file's stamp is its size alone, as when a clock is too coarse to tell
/// two writes apart: a rewrite of the same size looks unchanged.
fn coarseStamp(ctx: ?*anyopaque, path: []const u8) ?workspace.Files.Stamp {
    const mem: *workspace.MemoryFiles = @ptrCast(@alignCast(ctx.?));
    var s = mem.files().stamp.?(ctx, path) orelse return null;
    s.mtime_ns = 0;
    return s;
}

test "symbol index: polling parses a changed file once more, for a rewrite its stamp cannot show" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "function aa() end\n" },
        .{ "/elsewhere/b.mah", "function bb() end\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    var fs_coarse = mem.files();
    fs_coarse.stamp = coarseStamp;
    var f = Fixture.init();
    defer f.deinit();
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};
    try f.idx.setRoots(f.a(), &roots, null);
    try f.idx.setPolling(true);
    try f.idx.work(f.a(), fs_coarse, null, .all);

    // A new file, then rewritten at the same size before its next stamp.
    entries[1][0] = "/w/b.mah";
    f.idx.advance(1000);
    try f.idx.work(f.a(), fs_coarse, null, .all);
    try testing.expectEqualStrings("bb ", try f.names("bb"));
    entries[1][1] = "function cc() end\n";
    f.idx.advance(2000);
    try f.idx.work(f.a(), fs_coarse, null, .all);
    try testing.expectEqualStrings("cc ", try f.names("cc"));
    try testing.expectEqualStrings("", try f.names("bb"));

    // Once confirmed, it is not parsed again while it holds.
    const built = f.idx.builds;
    var t: u64 = 3000;
    while (t < 60_000) : (t += 1000) {
        f.idx.advance(t);
        try f.idx.work(f.a(), fs_coarse, null, .all);
    }
    try testing.expectEqual(built, f.idx.builds);
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
