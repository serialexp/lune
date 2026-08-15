#!/usr/bin/env python3
"""Extract a Zig source file's trailing `test` region into sibling `*_test.zig`
files, split along the file's own banner comments.

Dry-run by default: prints exactly what it *would* write, and reports the test
count per destination so the total can be checked against the pre-split
`zig build test` number. Pass --apply to actually write.

The transformation is deliberately *textual and body-preserving*: test bodies
are copied byte-for-byte and never rewritten. Each destination file gets a
prelude that recreates the identifier namespace the bodies were written
against — the original file's whole import/alias block, plus aliases for the
production decls the bodies reference (`const foo = <mod>.foo;`). Unused
container-level decls are legal in Zig, so copying the full import block is
safe and avoids per-file guesswork.

Usage:
  split-tests.py <src.zig> --cut N \\
      --util <name>:<lo>-<hi>[,<lo>-<hi>...] \\
      --block <lo>:<name> [--block ...] \\
      [--apply]
"""
import argparse
import os
import re
import sys

DECL_RE = re.compile(r'(?:pub )?(?:inline )?(?:const|var|fn) ([A-Za-z_][A-Za-z0-9_]*)')
TEST_RE = re.compile(r'test\s+["{]')


def strip_comment(line):
    """Drop a trailing // comment, respecting string/char literals."""
    out = []
    i = 0
    instr = inch = False
    while i < len(line):
        c = line[i]
        if instr:
            out.append(c)
            if c == '\\':
                out.append(line[i + 1:i + 2])
                i += 2
                continue
            if c == '"':
                instr = False
        elif inch:
            out.append(c)
            if c == '\\':
                out.append(line[i + 1:i + 2])
                i += 2
                continue
            if c == "'":
                inch = False
        else:
            if c == '"':
                instr = True
                out.append(c)
            elif c == "'":
                inch = True
                out.append(c)
            elif c == '/' and line[i + 1:i + 2] == '/':
                break
            else:
                out.append(c)
        i += 1
    return ''.join(out)


def code_text(lines):
    """Comment-stripped text, with multiline-string (\\\\) lines dropped."""
    return '\n'.join(strip_comment(L) for L in lines if not L.lstrip().startswith('\\\\'))


def idents(lines):
    return set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', code_text(lines)))


def scan_decls(lines, lo, hi):
    """Top-level (column-0) decls in [lo,hi], as {name: (start,end)} 1-based."""
    out = {}
    i = lo - 1
    n = min(hi, len(lines))
    while i < n:
        L = lines[i]
        m = DECL_RE.match(L)
        if m and not TEST_RE.match(L):
            depth = 0
            started = False
            j = i
            while j < len(lines):
                depth += lines[j].count('{') - lines[j].count('}')
                if '{' in lines[j]:
                    started = True
                if started and depth <= 0:
                    break
                if not started and lines[j].rstrip().endswith(';'):
                    break
                j += 1
            out[m.group(1)] = (i + 1, j + 1)
            i = j + 1
        else:
            i += 1
    return out


def count_tests(lines):
    return sum(1 for L in lines if TEST_RE.match(L))


def parse_ranges(spec):
    out = []
    for part in spec.split(','):
        lo, hi = part.split('-')
        out.append((int(lo), int(hi)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('--cut', type=int, required=True,
                    help='first line of the test region (1-based)')
    ap.add_argument('--block', action='append', default=[],
                    help='<startline>:<shortname> — one per destination file')
    ap.add_argument('--util', default=None,
                    help='<shortname>:<lo>-<hi>[,<lo>-<hi>] shared-helper line ranges')
    ap.add_argument('--extra-prelude', default=None,
                    help='<lo>-<hi>[,<lo>-<hi>] test-region alias lines copied into '
                         'every generated file (e.g. `const testing = std.testing;`)')
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()

    src = args.src
    stem = os.path.splitext(os.path.basename(src))[0]
    srcdir = os.path.dirname(src) or '.'
    lines = open(src, encoding='utf8').read().split('\n')
    cut = args.cut

    # --- production region: what the tests may reference -------------------
    prod = scan_decls(lines, 1, cut - 1)
    # The import/alias prelude: every column-0 decl before the first non-alias
    # declaration, i.e. the contiguous `const x = @import(..)` / `const X = m.Y;`
    # run at the top of the file.
    prelude = []
    for name, (s, e) in sorted(prod.items(), key=lambda kv: kv[1][0]):
        text = lines[s - 1]
        if s != e:
            continue
        if '@import(' in text or re.match(r'const [A-Za-z_]\w* = [a-z_]\w*\.[A-Za-z_]\w*;\s*$', text):
            prelude.append((s, text))
    prelude.sort()
    prelude_names = {DECL_RE.match(t).group(1) for _, t in prelude}
    prelude_text = [t for _, t in prelude]

    # production decls that are NOT part of the alias prelude — these need a
    # `const X = <stem>.X;` bridge in each test file that uses them.
    bridgeable = sorted(n for n in prod if n not in prelude_names)

    # --- destinations ------------------------------------------------------
    blocks = []
    for b in args.block:
        ln, name = b.split(':', 1)
        blocks.append((int(ln), name))
    blocks.sort()

    util_ranges = []
    util_name = None
    if args.util:
        util_name, rspec = args.util.split(':', 1)
        util_ranges = parse_ranges(rspec)

    extra_ranges = parse_ranges(args.extra_prelude) if args.extra_prelude else []
    for lo, hi in extra_ranges:
        prelude_text.extend(lines[lo - 1:hi])

    util_lines = set()
    for lo, hi in util_ranges:
        util_lines.update(range(lo, hi + 1))
    for lo, hi in extra_ranges:
        util_lines.update(range(lo, hi + 1))

    # slice each block, excluding lines claimed by the util file
    ends = [blocks[i + 1][0] - 1 for i in range(len(blocks) - 1)] + [len(lines)]
    dests = []
    for (lo, name), hi in zip(blocks, ends):
        body = [lines[i - 1] for i in range(lo, hi + 1) if i not in util_lines]
        dests.append((f'{stem}_{name}_test.zig', body, name))

    util_body = []
    if util_ranges:
        for lo, hi in util_ranges:
            util_body.extend(lines[lo - 1:hi])

    # --- emit --------------------------------------------------------------
    def render(fname, body, title, is_util):
        used = idents(body)
        bridges = [f'const {n} = {stem}.{n};' for n in bridgeable if n in used]
        head = [
            f'//! {title}',
            f'//!',
            f'//! Extracted verbatim from `{os.path.basename(src)}`; bodies are unchanged.',
        ]
        if not is_util and util_name:
            head.append(f'//! Shared harness lives in `{stem}_{util_name}.zig`.')
        head += ['', f'const {stem} = @import("{os.path.basename(src)}");']
        head += prelude_text
        if bridges:
            head += [''] + bridges
        if not is_util and util_name:
            uses_util = [n for n in util_decls if n in used]
            if uses_util:
                head += ['', f'const util = @import("{stem}_{util_name}.zig");']
                head += [f'const {n} = util.{n};' for n in uses_util]
        return '\n'.join(head + [''] + body).rstrip('\n') + '\n'

    util_decls = sorted(scan_decls(util_body, 1, len(util_body)).keys()) if util_body else []
    # util decls must be pub to be reachable
    if util_body:
        out = []
        for L in util_body:
            # Top-level decls must be pub to be importable...
            if DECL_RE.match(L) and not L.startswith('pub '):
                L = re.sub(r'^(const|var|fn) ', r'pub \1 ', L)
            # ...and so must methods of a moved struct, else callers in the test
            # files cannot reach them (`RefRun.deinit` &c).
            # An indented `fn` is always a struct method (Zig has no
            # function-local `fn`), so this is safe; an indented `const` may be
            # a local inside a function body, which cannot take `pub`.
            elif re.match(r'^(    )+fn ', L):
                L = re.sub(r'^((?:    )+)fn ', r'\1pub fn ', L)
            out.append(L)
        util_body = out

    outputs = []
    if util_body:
        outputs.append((f'{stem}_{util_name}.zig',
                        render(f'{stem}_{util_name}.zig', util_body,
                               f'Shared test harness for `{os.path.basename(src)}`.', True)))
    total_tests = 0
    for fname, body, name in dests:
        n = count_tests(body)
        total_tests += n
        outputs.append((fname, render(fname, body, f'Tests for `{os.path.basename(src)}` — {name}.', False)))

    # truncated source + discovery hook
    keep = lines[:cut - 1]
    while keep and not keep[-1].strip():
        keep.pop()
    hook = ['', '// ---------------------------------------------------------------------------',
            '// Tests', '// ---------------------------------------------------------------------------',
            '//',
            '// The test suite lives in sibling `*_test.zig` files (split by theme). Zig only',
            '// analyses a file that is reachable by import, so this block is what makes them',
            '// run under `zig build test`.', '', 'test {']
    for fname, _, _ in dests:
        hook.append(f'    _ = @import("{fname}");')
    hook += ['}', '']
    new_src = '\n'.join(keep + hook)

    orig_tests = count_tests(lines[cut - 1:])
    print(f'{src}: {len(lines)} lines, {orig_tests} tests in region from {cut}')
    print(f'  -> {os.path.basename(src)} keeps {len(keep)} lines (+ discovery hook)')
    for fname, text in outputs:
        nt = count_tests(text.split('\n'))
        print(f'  -> {fname:52} {len(text.splitlines()):6} lines, {nt:3} tests')
    print(f'  test-count check: {total_tests} extracted vs {orig_tests} original '
          f'-> {"OK" if total_tests == orig_tests else "MISMATCH"}')
    if util_decls:
        print(f'  shared util decls: {", ".join(util_decls)}')

    if not args.apply:
        print('\n(dry run — pass --apply to write)')
        return 0 if total_tests == orig_tests else 1

    if total_tests != orig_tests:
        print('refusing to apply: test-count mismatch', file=sys.stderr)
        return 1
    for fname, text in outputs:
        open(os.path.join(srcdir, fname), 'w', encoding='utf8').write(text)
    open(src, 'w', encoding='utf8').write(new_src)
    print('\napplied.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
