#!/usr/bin/env python3
"""Pre-flight for tools/split-tests.py.

Answers the two questions that otherwise only surface as compile errors after
an --apply:

  1. Which decls declared in the *test* region are referenced by *production*
     code?  Zig does not care about declaration order within a container, so a
     `const irinterp = @import(...)` sitting below the test banner can still be
     used at line 700.  Cutting the file there silently removes it.

  2. Which test-region helpers are used from more than one destination block?
     Those must go to the shared testutil file rather than staying with the
     block that happens to declare them.

Both are computed over comment-stripped text so that a name appearing only in
prose does not count as a reference.

Usage:
  check-split.py <src.zig> --cut N --block <lo>:<name> [--block ...]
"""
import argparse
import re
import sys

DECL_RE = re.compile(r'^(?:pub )?(?:inline )?(?:const|var|fn) ([A-Za-z_][A-Za-z0-9_]*)')
TEST_RE = re.compile(r'^test\s+["{]')


def strip_comment(line):
    out = []
    i = 0
    instr = inch = False
    while i < len(line):
        c = line[i]
        if instr:
            out.append(c)
            if c == '\\':
                out.append(line[i + 1:i + 2]); i += 2; continue
            if c == '"':
                instr = False
        elif inch:
            out.append(c)
            if c == '\\':
                out.append(line[i + 1:i + 2]); i += 2; continue
            if c == "'":
                inch = False
        else:
            if c == '"':
                instr = True; out.append(c)
            elif c == "'":
                inch = True; out.append(c)
            elif c == '/' and line[i + 1:i + 2] == '/':
                break
            else:
                out.append(c)
        i += 1
    return ''.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('--cut', type=int, required=True)
    ap.add_argument('--block', action='append', default=[])
    args = ap.parse_args()

    raw = open(args.src, encoding='utf8').read().split('\n')
    # comment-stripped view, keeping line numbers aligned; multiline-string
    # payload lines are dropped (they are data, not code).
    code = [('' if L.lstrip().startswith('\\\\') else strip_comment(L)) for L in raw]

    blocks = sorted((int(b.split(':', 1)[0]), b.split(':', 1)[1]) for b in args.block)

    def blockof(ln):
        name = None
        for s, nm in blocks:
            if ln >= s:
                name = nm
        return name

    # decls declared in the test region (column 0 only)
    test_decls = {}
    for i in range(args.cut - 1, len(raw)):
        m = DECL_RE.match(raw[i])
        if m and not TEST_RE.match(raw[i]):
            test_decls.setdefault(m.group(1), i + 1)

    # --- 1. test-region decls used by production ---------------------------
    prod_text = '\n'.join(code[:args.cut - 1])
    prod_ids = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', prod_text))
    leaks = sorted((n, ln) for n, ln in test_decls.items() if n in prod_ids)

    print(f'{args.src}: cut {args.cut}, {len(test_decls)} test-region decls')
    print()
    print('--- test-region decls REFERENCED BY PRODUCTION (must stay in the source) ---')
    if not leaks:
        print('  (none)')
    for n, ln in leaks:
        hits = [i + 1 for i in range(args.cut - 1) if re.search(r'\b' + re.escape(n) + r'\b', code[i])]
        print(f'  {n:28} declared L{ln}, used at production lines '
              f'{", ".join(map(str, hits[:6]))}{" ..." if len(hits) > 6 else ""} ({len(hits)} sites)')

    # --- 2. cross-block helper usage ---------------------------------------
    print()
    print('--- test-region decls used by MORE THAN ONE block (must go to testutil) ---')
    shared = []
    for n, ln in sorted(test_decls.items()):
        used_in = set()
        pat = re.compile(r'\b' + re.escape(n) + r'\b')
        for i in range(args.cut - 1, len(raw)):
            if i + 1 == ln:
                continue
            if pat.search(code[i]):
                b = blockof(i + 1)
                if b:
                    used_in.add(b)
        home = blockof(ln)
        if len(used_in - {home}) > 0 and len(used_in) > 0:
            if used_in - {home}:
                shared.append(n)
                print(f'  {n:28} declared L{ln} (in {home}), also used by: '
                      f'{", ".join(sorted(used_in - {home}))}')
    if not shared:
        print('  (none)')
    print()
    print(f'summary: {len(leaks)} production leaks, {len(shared)} cross-block helpers')
    return 0


if __name__ == '__main__':
    sys.exit(main())
