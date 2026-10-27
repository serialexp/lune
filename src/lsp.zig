//! The mahina language server (doc 74). This file is the module hub: it
//! re-exports the submodules and pulls their tests into the build.

pub const position = @import("lsp/position.zig");
pub const jsonrpc = @import("lsp/jsonrpc.zig");

test {
    _ = position;
    _ = jsonrpc;
}
