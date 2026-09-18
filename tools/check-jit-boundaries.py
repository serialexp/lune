#!/usr/bin/env python3
"""Check the focused production dependency boundaries from design document 41.

This is deliberately a small Zig import scanner rather than a general-purpose
architecture checker.  It understands enough Zig lexical structure to avoid
counting imports in comments, literals, and ``test`` declarations.
"""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
from pathlib import Path
import sys
from typing import Iterable


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    line: int


def _decode_string(raw: str) -> str:
    """Decode the Zig escapes which can occur in an import string."""
    result: list[str] = []
    i = 0
    simple = {
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "\\": "\\",
        '"': '"',
        "'": "'",
        "0": "\0",
    }
    while i < len(raw):
        if raw[i] != "\\" or i + 1 >= len(raw):
            result.append(raw[i])
            i += 1
            continue
        escape = raw[i + 1]
        if escape in simple:
            result.append(simple[escape])
            i += 2
        elif escape == "x" and i + 3 < len(raw):
            try:
                result.append(chr(int(raw[i + 2 : i + 4], 16)))
                i += 4
            except ValueError:
                result.append("\\")
                i += 1
        elif escape == "u" and i + 2 < len(raw) and raw[i + 2] == "{":
            end = raw.find("}", i + 3)
            try:
                if end < 0:
                    raise ValueError
                result.append(chr(int(raw[i + 3 : end], 16)))
                i = end + 1
            except (ValueError, OverflowError):
                result.append("\\")
                i += 1
        else:
            # Invalid source is Zig's concern.  Retaining the escaped character
            # is the least surprising behavior for dependency checking.
            result.append(escape)
            i += 2
    return "".join(result)


def tokenize_zig(source: str) -> list[Token]:
    """Return structural tokens, discarding comments and multiline literals."""
    tokens: list[Token] = []
    i = 0
    line = 1
    length = len(source)
    while i < length:
        char = source[i]
        if char in " \t\r":
            i += 1
        elif char == "\n":
            line += 1
            i += 1
        elif source.startswith("//", i):
            end = source.find("\n", i + 2)
            i = length if end < 0 else end
        elif source.startswith("\\\\", i):
            # A Zig multiline-string line starts with two backslashes and runs
            # to the newline.  Its contents have no lexical punctuation.
            end = source.find("\n", i + 2)
            i = length if end < 0 else end
        elif char in ('"', "'"):
            quote = char
            start_line = line
            i += 1
            raw: list[str] = []
            while i < length:
                char = source[i]
                if char == "\\" and i + 1 < length:
                    raw.extend((source[i], source[i + 1]))
                    i += 2
                elif char == quote:
                    i += 1
                    break
                else:
                    if char == "\n":
                        line += 1
                    raw.append(char)
                    i += 1
            kind = "string" if quote == '"' else "char"
            value = _decode_string("".join(raw)) if kind == "string" else ""
            tokens.append(Token(kind, value, start_line))
        elif char.isalpha() or char == "_":
            start = i
            while i < length and (source[i].isalnum() or source[i] == "_"):
                i += 1
            tokens.append(Token("identifier", source[start:i], line))
        else:
            tokens.append(Token("symbol", char, line))
            i += 1
    return tokens


def _without_test_blocks(tokens: list[Token]) -> list[Token]:
    """Remove complete Zig test declarations, including nested brace bodies."""
    production: list[Token] = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token.kind == "identifier" and token.value == "test":
            # Test declarations have an optional name followed by a block.  Look
            # only as far as that header; a semicolon/brace means this was not a
            # declaration in malformed or future syntax.
            opening = None
            j = i + 1
            while j < len(tokens) and j <= i + 4:
                if tokens[j].kind == "symbol" and tokens[j].value == "{":
                    opening = j
                    break
                if tokens[j].kind == "symbol" and tokens[j].value in (";", "}"):
                    break
                j += 1
            if opening is not None:
                depth = 1
                i = opening + 1
                while i < len(tokens) and depth:
                    if tokens[i].kind == "symbol" and tokens[i].value == "{":
                        depth += 1
                    elif tokens[i].kind == "symbol" and tokens[i].value == "}":
                        depth -= 1
                    i += 1
                continue
        production.append(token)
        i += 1
    return production


def production_imports(path: Path) -> list[str]:
    """Extract string-valued @import calls from production portions of *path*."""
    tokens = _without_test_blocks(tokenize_zig(path.read_text(encoding="utf-8")))
    imports: list[str] = []
    for i in range(len(tokens) - 4):
        if (
            tokens[i].value == "@"
            and tokens[i + 1].kind == "identifier"
            and tokens[i + 1].value == "import"
            and tokens[i + 2].value == "("
            and tokens[i + 3].kind == "string"
            and tokens[i + 4].value == ")"
        ):
            imports.append(tokens[i + 3].value)
    return imports


def _is_dedicated_test(path: Path) -> bool:
    return path.name.endswith("_test.zig") or path.name.endswith("_testutil.zig")


def build_graph(source_root: Path) -> dict[Path, tuple[Path, ...]]:
    """Build the local-.zig production import graph below *source_root*."""
    source_root = source_root.resolve()
    graph: dict[Path, tuple[Path, ...]] = {}
    for source in sorted(source_root.rglob("*.zig")):
        source = source.resolve()
        if _is_dedicated_test(source):
            continue
        dependencies: list[Path] = []
        for imported in production_imports(source):
            if not imported.endswith(".zig"):
                continue
            dependency = (source.parent / imported).resolve()
            try:
                dependency.relative_to(source_root)
            except ValueError:
                continue
            if dependency.is_file() and not _is_dedicated_test(dependency):
                dependencies.append(dependency)
        graph[source] = tuple(dict.fromkeys(dependencies))
    return graph


@dataclass(frozen=True)
class Violation:
    rule: str
    path: tuple[Path, ...]

    def format(self, source_root: Path) -> str:
        display = " -> ".join(str(item.relative_to(source_root)) for item in self.path)
        return f"JIT boundary violation: {self.rule}\n  dependency path: {display}"


def _path_to_any(
    graph: dict[Path, tuple[Path, ...]], root: Path, forbidden: set[Path]
) -> tuple[Path, ...] | None:
    queue: deque[tuple[Path, ...]] = deque([(root,)])
    visited = {root}
    while queue:
        path = queue.popleft()
        for dependency in graph.get(path[-1], ()):
            next_path = path + (dependency,)
            if dependency in forbidden:
                return next_path
            if dependency not in visited:
                visited.add(dependency)
                queue.append(next_path)
    return None


def check_boundaries(source_root: Path) -> list[Violation]:
    source_root = source_root.resolve()
    graph = build_graph(source_root)
    forbidden = {
        (source_root / name).resolve()
        for name in ("trace.zig", "irinterp.zig", "nativegen.zig")
    }
    violations: list[Violation] = []

    trace_exec = (source_root / "trace_exec.zig").resolve()
    if trace_exec in graph and graph[trace_exec]:
        # This leaf has the stricter rule: even an otherwise harmless local
        # dependency is an ownership violation.
        violations.append(
            Violation(
                "trace_exec.zig must not depend on any project module",
                (trace_exec, graph[trace_exec][0]),
            )
        )

    for name in ("ir_eval.zig", "tropt.zig", "troptdiag.zig", "trace_code.zig", "trace_candidate.zig", "trace_finalize.zig", "trace_region_topology.zig"):
        root = (source_root / name).resolve()
        if root not in graph:
            continue
        path = _path_to_any(graph, root, forbidden)
        if path is not None:
            violations.append(
                Violation(
                    f"{name} must not depend transitively on trace.zig, "
                    "irinterp.zig, or nativegen.zig",
                    path,
                )
            )
    # Execution and serialization consume code, never lifecycle records. Neither
    # executor owns the other's semantics or shared result vocabulary.
    for name, blocked in (
        ("nativegen.zig", ("trace.zig", "trace_record.zig", "irinterp.zig")),
        ("irinterp.zig", ("trace.zig", "trace_record.zig", "nativegen.zig")),
        ("traceser.zig", ("trace.zig", "trace_record.zig", "irinterp.zig", "nativegen.zig")),
        ("trace_entry_registry.zig", ("trace.zig", "trace_link.zig", "trace_regionops.zig", "trace_chain.zig")),
        ("trace_native_registry.zig", ("trace.zig", "trace_link.zig", "trace_regionops.zig", "trace_chain.zig")),
        ("trace_registry.zig", ("trace.zig", "trace_link.zig", "trace_regionops.zig", "trace_chain.zig")),
        ("trace_region_policy.zig", ("trace.zig", "trace_link.zig", "trace_regionops.zig", "trace_chain.zig", "trace_registry.zig")),
        ("trace_region_observer.zig", ("trace.zig", "trace_link.zig", "trace_regionops.zig", "trace_chain.zig", "trace_registry.zig")),
        ("trace_recording_session.zig", ("trace.zig", "trace_link.zig", "trace_regionops.zig", "trace_registry.zig", "nativegen.zig")),
        ("trace_recorder.zig", ("trace.zig", "trace_link.zig", "trace_regionops.zig", "trace_registry.zig", "nativegen.zig")),
    ):
        root = source_root / name
        if root not in graph:
            continue
        # The runtime/stdlib capability cycle is tracked separately in doc 41;
        # enforce the implemented direct contract, not that future transitive cut.
        blocked_paths = {source_root / item for item in blocked}
        for dependency in graph[root]:
            if dependency in blocked_paths:
                violations.append(Violation(f"{name} violates its direct ownership dependency boundary", (root, dependency)))
    violations.extend(check_body_callouts(source_root))
    return violations


# --- Doc 54 P1: the body-callout authority rule ------------------------------
#
# Inline native frame motion drops the old helpers' per-transition frame-
# identity re-verification on the strength of an episode-local invariant:
# nothing but the episode's own emitted code mutates `frames[]`/`depth`
# mid-episode.  Native BODIES do make runtime callouts (allocation, string
# helpers, hash resolves), so the invariant's mechanical form is that no BODY
# callout carries frame-mutation authority: a C-ABI function reachable from a
# native page body must take `*Heap` or value operands, never `*Vm` or the
# episode ctx (`NativeSeedCtx`, which carries `vm`).  The episode-BOUNDARY
# helpers legitimately hold that authority and are allowlisted by (file,
# name); adding a new `*Vm`/ctx-taking `callconv(.c)` function anywhere else
# fails this check instead of silently invalidating every dropped identity
# check.

CALLOUT_AUTHORITY_TYPES = frozenset({"Vm", "NativeSeedCtx"})

EPISODE_BOUNDARY_ALLOWLIST = frozenset(
    {
        ("interp.zig", "nativeSeedFn"),
        # (doc 54 P2 deleted `nativeSelfCallPush` — frame motion is fully
        # inline-emitted; the seed fn and the jit-debug assert callout are
        # the only remaining authority-bearing boundary helpers.)
        ("interp.zig", "nativeFrameMotionAssert"),
    }
)


def c_abi_functions(path: Path) -> list[tuple[str, int, tuple[str, ...]]]:
    """Named ``fn NAME(...) callconv(.c)`` declarations with the identifiers
    appearing in their parameter list (names and types alike).  Anonymous
    function-pointer TYPES (`*const fn (...) callconv(.c)`) have no name token
    and are deliberately not reported — they are boundary contract fields, not
    declarations."""
    tokens = _without_test_blocks(tokenize_zig(path.read_text(encoding="utf-8")))
    found: list[tuple[str, int, tuple[str, ...]]] = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if (
            token.kind == "identifier"
            and token.value == "fn"
            and i + 2 < len(tokens)
            and tokens[i + 1].kind == "identifier"
            and tokens[i + 2].kind == "symbol"
            and tokens[i + 2].value == "("
        ):
            name = tokens[i + 1].value
            line = tokens[i + 1].line
            depth = 1
            j = i + 3
            params: list[str] = []
            while j < len(tokens) and depth:
                inner = tokens[j]
                if inner.kind == "symbol" and inner.value == "(":
                    depth += 1
                elif inner.kind == "symbol" and inner.value == ")":
                    depth -= 1
                elif inner.kind == "identifier":
                    params.append(inner.value)
                j += 1
            # Between the parameter list and the body/semicolon sits the
            # return type, where a `callconv(.c)` marks the C ABI.  A nested
            # fn-pointer PARAMETER's own callconv was consumed above and
            # cannot reach here.
            is_c_abi = False
            k = j
            while k < len(tokens):
                trailer = tokens[k]
                if trailer.kind == "symbol" and trailer.value in ("{", ";"):
                    break
                if (
                    trailer.kind == "identifier"
                    and trailer.value == "callconv"
                    and k + 4 < len(tokens)
                    and tokens[k + 1].value == "("
                    and tokens[k + 2].value == "."
                    and tokens[k + 3].value == "c"
                    and tokens[k + 4].value == ")"
                ):
                    is_c_abi = True
                    break
                k += 1
            if is_c_abi:
                found.append((name, line, tuple(params)))
            i = j
            continue
        i += 1
    return found


def check_body_callouts(source_root: Path) -> list[Violation]:
    source_root = source_root.resolve()
    violations: list[Violation] = []
    for source in sorted(source_root.rglob("*.zig")):
        source = source.resolve()
        if _is_dedicated_test(source):
            continue
        relative = source.relative_to(source_root).as_posix()
        for name, line, params in c_abi_functions(source):
            if not CALLOUT_AUTHORITY_TYPES.intersection(params):
                continue
            if (relative, name) in EPISODE_BOUNDARY_ALLOWLIST:
                continue
            violations.append(
                Violation(
                    f"C-ABI function `{name}` ({relative}:{line}) takes frame-"
                    "mutation authority (*Vm / NativeSeedCtx); body callouts "
                    "must take *Heap or value operands (doc 54 P1) — an "
                    "episode-BOUNDARY helper goes on the allowlist only with "
                    "a soundness argument",
                    (source,),
                )
            )
    return violations


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--src",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "src",
        help="Zig source root (default: repository src directory)",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if not args.src.is_dir():
        print(f"error: Zig source directory does not exist: {args.src}", file=sys.stderr)
        return 2
    violations = check_boundaries(args.src)
    if violations:
        for violation in violations:
            print(violation.format(args.src.resolve()), file=sys.stderr)
        return 1
    print("JIT production dependency boundaries: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
