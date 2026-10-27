# mahina for Zed

A dev extension (not published). It gives Zed syntax highlighting, brackets,
outline and indents for `.mah` files, and launches `mahina lsp` for
diagnostics.

## Install

1. Put the `mahina` CLI on `PATH` (`just cli`, or `zig build` and link
   `zig-out/bin/mahina`).
2. In Zed: **zed: install dev extension**, and pick this directory
   (`editors/zed`). Zed compiles the launcher itself (it needs `rustup`).

To point at another binary:

```json
{ "lsp": { "mahina": { "binary": { "path": "/path/to/mahina" } } } }
```

## The grammar pin

`extension.toml` names the Tree-sitter grammar by repository, commit and
subdirectory (`editors/tree-sitter-mahina`). Zed builds it from the
checked-in `src/parser.c`, so after changing `grammar.js` run
`pnpm generate` there, commit the generated files, and update `commit`.

The query files in `languages/mahina/` are symlinks to
`../../../tree-sitter-mahina/queries/`, so there is one copy of each.
