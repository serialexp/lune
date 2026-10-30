//! The LSP 3.17 structures the server uses (doc 74 §4): plain Zig types whose
//! field names are the JSON field names, so `jsonrpc.decode` / the encoders
//! (de)serialise them directly. No JSON knowledge lives here — only shapes.
//! Optional fields default to null and are omitted from output when null.

const position = @import("position.zig");
const jsonrpc = @import("jsonrpc.zig");

pub const Position = position.Position;
pub const Range = position.Range;

// ---- initialize ------------------------------------------------------------

pub const ClientGeneral = struct {
    positionEncodings: ?[]const []const u8 = null,
};

pub const DynamicRegistration = struct {
    dynamicRegistration: ?bool = null,
};

pub const ClientWorkspace = struct {
    didChangeWatchedFiles: ?DynamicRegistration = null,
};

pub const ClientCapabilities = struct {
    general: ?ClientGeneral = null,
    workspace: ?ClientWorkspace = null,
};

pub const WorkspaceFolder = struct {
    uri: []const u8,
    name: []const u8 = "",
};

pub const InitializeParams = struct {
    processId: ?i64 = null,
    capabilities: ClientCapabilities = .{},
    /// The single root of a client without workspace folders.
    rootUri: ?[]const u8 = null,
    /// Every folder of the workspace; takes precedence over `rootUri`.
    workspaceFolders: ?[]const WorkspaceFolder = null,
};

/// `initializationOptions` (doc 74 §7.4): the tables of `mahina.toml`, as
/// JSON, overriding it in every folder. Decoded strictly
/// (`jsonrpc.decodeStrict`), so a misspelt key is reported.
pub const InitializationOptions = struct {
    runtime: ?RuntimeOptions = null,
    /// Host globals, each with a description: `{"spawn": "starts a process"}`.
    globals: ?[]const jsonrpc.NameValue = null,
    diagnostics: ?DiagnosticsOptions = null,
};

pub const RuntimeOptions = struct {
    cwd: ?[]const u8 = null,
    package_path: ?[]const []const u8 = null,
    system: ?[]const []const u8 = null,
};

pub const DiagnosticsOptions = struct {
    suppress: ?[]const []const u8 = null,
};

pub const FileSystemWatcher = struct {
    globPattern: []const u8,
};

pub const DidChangeWatchedFilesRegistrationOptions = struct {
    watchers: []const FileSystemWatcher,
};

pub const Registration = struct {
    id: []const u8,
    method: []const u8,
    registerOptions: DidChangeWatchedFilesRegistrationOptions,
};

pub const RegistrationParams = struct {
    registrations: []const Registration,
};

pub const FileChangeType = struct {
    pub const created: u8 = 1;
    pub const changed: u8 = 2;
    pub const deleted: u8 = 3;
};

pub const FileEvent = struct {
    uri: []const u8,
    type: u8,
};

pub const DidChangeWatchedFilesParams = struct {
    changes: []const FileEvent = &.{},
};

pub const WorkspaceFoldersChangeEvent = struct {
    added: []const WorkspaceFolder = &.{},
    removed: []const WorkspaceFolder = &.{},
};

pub const DidChangeWorkspaceFoldersParams = struct {
    event: WorkspaceFoldersChangeEvent,
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

pub const RenameOptions = struct {
    prepareProvider: bool = true,
};

pub const CompletionOptions = struct {
    resolveProvider: bool = false,
    /// `lib.` offers the library's members, so the client asks after a dot.
    triggerCharacters: []const []const u8 = &.{"."},
};

pub const SignatureHelpOptions = struct {
    triggerCharacters: []const []const u8 = &.{ "(", "," },
};

pub const SemanticTokensLegend = struct {
    tokenTypes: []const []const u8,
    tokenModifiers: []const []const u8,
};

pub const SemanticTokensOptions = struct {
    legend: SemanticTokensLegend,
    full: bool = true,
};

pub const WorkspaceFoldersServerCapabilities = struct {
    supported: bool = true,
    changeNotifications: bool = true,
};

pub const WorkspaceServerCapabilities = struct {
    /// One server serves every folder (doc 74 §7.4).
    workspaceFolders: WorkspaceFoldersServerCapabilities = .{},
};

pub const ServerCapabilities = struct {
    /// Omitted when the client offered no encodings (then UTF-16 is implied).
    positionEncoding: ?[]const u8 = null,
    textDocumentSync: TextDocumentSyncOptions = .{},
    definitionProvider: bool = true,
    referencesProvider: bool = true,
    documentHighlightProvider: bool = true,
    renameProvider: RenameOptions = .{},
    completionProvider: CompletionOptions = .{},
    hoverProvider: bool = true,
    signatureHelpProvider: ?SignatureHelpOptions = .{},
    semanticTokensProvider: ?SemanticTokensOptions = null,
    documentSymbolProvider: bool = true,
    foldingRangeProvider: bool = true,
    selectionRangeProvider: bool = true,
    workspaceSymbolProvider: bool = true,
    workspace: WorkspaceServerCapabilities = .{},
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

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const DiagnosticRelatedInformation = struct {
    location: Location,
    message: []const u8,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?u8 = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8,
    relatedInformation: ?[]const DiagnosticRelatedInformation = null,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    version: ?i64 = null,
    diagnostics: []const Diagnostic,
};

// ---- navigation (doc 74 §7.2) -----------------------------------------------

pub const TextDocumentPositionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};

pub const ReferenceParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    context: struct { includeDeclaration: bool = true } = .{},
};

pub const RenameParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    newName: []const u8,
};

pub const DocumentHighlightKind = struct {
    pub const read: u8 = 2;
    pub const write: u8 = 3;
};

pub const DocumentHighlight = struct {
    range: Range,
    kind: u8,
};

pub const PrepareRenameResult = struct {
    range: Range,
    placeholder: []const u8,
};

pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

/// `{"changes": {uri: edits}}`: the shape every client reads, and the only one
/// `@codemirror/lsp-client` does. A document's URI is the key, which a Zig
/// struct cannot name, hence the custom writer. One document until P6.
/// One document's edits in a `WorkspaceEdit`.
pub const FileEdits = struct {
    uri: []const u8,
    edits: []const TextEdit,
};

/// Each uri at most once.
pub const WorkspaceEdit = struct {
    files: []const FileEdits,

    pub fn jsonStringify(self: WorkspaceEdit, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("changes");
        try jw.beginObject();
        for (self.files) |f| {
            try jw.objectField(f.uri);
            try jw.write(f.edits);
        }
        try jw.endObject();
        try jw.endObject();
    }
};

// ---- completion --------------------------------------------------------------

pub const CompletionItemKind = struct {
    pub const method: u8 = 2;
    pub const function: u8 = 3;
    pub const field: u8 = 5;
    pub const variable: u8 = 6;
    pub const keyword: u8 = 14;
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: u8,
    detail: ?[]const u8 = null,
    sortText: ?[]const u8 = null,
};

pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

// ---- syntax (doc 74 §7.1) ---------------------------------------------------

pub const SemanticTokensParams = struct {
    textDocument: TextDocumentIdentifier,
};

/// The delta encoding of LSP: five integers per token, see `server.zig`.
pub const SemanticTokens = struct {
    data: []const u32,
};

pub const DocumentSymbolParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const SymbolKind = struct {
    pub const method: u8 = 6;
    pub const field: u8 = 8;
    pub const function: u8 = 12;
    pub const variable: u8 = 13;
    pub const object: u8 = 19;
};

pub const DocumentSymbol = struct {
    name: []const u8,
    kind: u8,
    range: Range,
    selectionRange: Range,
    children: ?[]const DocumentSymbol = null,
};

pub const WorkspaceSymbolParams = struct {
    query: []const u8 = "",
};

pub const SymbolInformation = struct {
    name: []const u8,
    kind: u8,
    location: Location,
    containerName: ?[]const u8 = null,
};

pub const FoldingRangeParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const FoldingRange = struct {
    startLine: u32,
    endLine: u32,
    kind: ?[]const u8 = null,
};

pub const SelectionRangeParams = struct {
    textDocument: TextDocumentIdentifier,
    positions: []const Position,
};

/// A position's chain of enclosing ranges: this one, then its `parent`.
pub const SelectionRange = struct {
    range: Range,
    parent: ?*const SelectionRange = null,
};

// ---- hover and signature help (doc 74 §7.3) ---------------------------------

pub const MarkupKind = struct {
    pub const markdown: []const u8 = "markdown";
};

pub const MarkupContent = struct {
    kind: []const u8,
    value: []const u8,
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

/// A parameter's `[start, end]` byte offsets into its signature's label (LSP's
/// own label form, which a client highlights without searching for the text).
pub const ParameterInformation = struct {
    label: [2]u32,
};

pub const SignatureInformation = struct {
    label: []const u8,
    documentation: ?MarkupContent = null,
    parameters: []const ParameterInformation = &.{},
};

pub const SignatureHelp = struct {
    signatures: []const SignatureInformation,
    activeSignature: u32 = 0,
    activeParameter: u32 = 0,
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
