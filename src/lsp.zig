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
    _ = server;
    _ = host_stdio;
}
