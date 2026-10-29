//! The mahina language server (doc 74). This file is the module hub: it
//! re-exports the submodules and pulls their tests into the build.

pub const position = @import("lsp/position.zig");
pub const jsonrpc = @import("lsp/jsonrpc.zig");
pub const protocol = @import("lsp/protocol.zig");
pub const documents = @import("lsp/documents.zig");
pub const analysis = @import("lsp/analysis.zig");
pub const navigation = @import("lsp/navigation.zig");
pub const syntax = @import("lsp/syntax.zig");
pub const tokens = @import("lsp/tokens.zig");
pub const completion = @import("lsp/completion.zig");
pub const stdlib_db = @import("lsp/stdlib_db.zig");
pub const library = @import("lsp/library.zig");
pub const config = @import("lsp/config.zig");
pub const modules = @import("lsp/modules.zig");
pub const exports = @import("lsp/exports.zig");
pub const module_cache = @import("lsp/module_cache.zig");
pub const uri = @import("lsp/uri.zig");
pub const workspace = @import("lsp/workspace.zig");
pub const server = @import("lsp/server.zig");
/// The stdio host; native only (the browser has its own, in `wasm_entry.zig`).
pub const host_stdio = @import("lsp/host_stdio.zig");

test {
    _ = position;
    _ = jsonrpc;
    _ = protocol;
    _ = documents;
    _ = analysis;
    _ = navigation;
    _ = syntax;
    _ = tokens;
    _ = completion;
    _ = stdlib_db;
    _ = library;
    _ = config;
    _ = modules;
    _ = exports;
    _ = module_cache;
    _ = uri;
    _ = workspace;
    _ = server;
    _ = host_stdio;
}
