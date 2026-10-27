//! The mahina language-server launcher for Zed (doc 74 §13.2): the whole
//! extension is "find `mahina` on PATH and run `mahina lsp`". Highlighting,
//! brackets, outline and indents are Tree-sitter queries; everything else
//! (diagnostics, navigation) is the server.

use zed_extension_api::{self as zed, settings::LspSettings, LanguageServerId, Result};

struct MahinaExtension;

impl zed::Extension for MahinaExtension {
    fn new() -> Self {
        MahinaExtension
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        // `lsp.mahina.binary.path` / `.arguments` in Zed's settings win.
        let settings = LspSettings::for_worktree(language_server_id.as_ref(), worktree).ok();
        let configured = settings.as_ref().and_then(|s| s.binary.as_ref());

        let command = match configured.and_then(|b| b.path.clone()) {
            Some(path) => path,
            None => worktree.which("mahina").ok_or_else(|| {
                "`mahina` was not found on PATH; install the CLI (`just cli`) or set \
                 `lsp.mahina.binary.path` in Zed's settings"
                    .to_string()
            })?,
        };
        let args = configured
            .and_then(|b| b.arguments.clone())
            .unwrap_or_else(|| vec!["lsp".to_string()]);

        Ok(zed::Command {
            command,
            args,
            env: worktree.shell_env(),
        })
    }
}

zed::register_extension!(MahinaExtension);
