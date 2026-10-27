//! The LSP 3.17 structures the server uses (doc 74 §4): plain Zig types whose
//! field names are the JSON field names, so `jsonrpc.decode` / the encoders
//! (de)serialise them directly. No JSON knowledge lives here — only shapes.
//! Optional fields default to null and are omitted from output when null.

const position = @import("position.zig");

pub const Position = position.Position;
pub const Range = position.Range;

// ---- initialize ------------------------------------------------------------

pub const ClientGeneral = struct {
    positionEncodings: ?[]const []const u8 = null,
};

pub const ClientCapabilities = struct {
    general: ?ClientGeneral = null,
};

pub const InitializeParams = struct {
    processId: ?i64 = null,
    capabilities: ClientCapabilities = .{},
};

pub const TextDocumentSyncKind = struct {
    pub const none: u8 = 0;
    pub const full: u8 = 1;
    pub const incremental: u8 = 2;
};

pub const TextDocumentSyncOptions = struct {
    openClose: bool = true,
    change: u8 = TextDocumentSyncKind.incremental,
};

pub const ServerCapabilities = struct {
    /// Omitted when the client offered no encodings (then UTF-16 is implied).
    positionEncoding: ?[]const u8 = null,
    textDocumentSync: TextDocumentSyncOptions = .{},
};

pub const ServerInfo = struct {
    name: []const u8,
    version: ?[]const u8 = null,
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
    serverInfo: ?ServerInfo = null,
};

// ---- text document sync ----------------------------------------------------

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8 = "",
    version: i64 = 0,
    text: []const u8,
};

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i64 = 0,
};

pub const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem,
};

/// One change. With a `range`, replaces that range; without, replaces the
/// whole document.
pub const TextDocumentContentChangeEvent = struct {
    range: ?Range = null,
    rangeLength: ?u32 = null,
    text: []const u8,
};

pub const DidChangeTextDocumentParams = struct {
    textDocument: VersionedTextDocumentIdentifier,
    contentChanges: []const TextDocumentContentChangeEvent,
};

pub const DidCloseTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

// ---- diagnostics -----------------------------------------------------------

pub const DiagnosticSeverity = struct {
    pub const @"error": u8 = 1;
    pub const warning: u8 = 2;
    pub const information: u8 = 3;
    pub const hint: u8 = 4;
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?u8 = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    version: ?i64 = null,
    diagnostics: []const Diagnostic,
};

// ---- window ----------------------------------------------------------------

pub const MessageType = struct {
    pub const @"error": u8 = 1;
    pub const warning: u8 = 2;
    pub const info: u8 = 3;
    pub const log: u8 = 4;
};

pub const LogMessageParams = struct {
    type: u8,
    message: []const u8,
};
