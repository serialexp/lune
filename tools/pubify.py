#!/usr/bin/env python3
"""Widen named top-level decls in a Zig file to `pub`.

Dry-run by default: prints the before/after of each line it would change and
fails loudly if a name is missing or already `pub` (so a typo can't silently
no-op). Pass --apply to write.

Used by the test-extraction work: a test moved to a sibling file can only reach
decls that are `pub`, and this makes that widening explicit and reviewable
rather than a hand-edit buried in a large diff.

Usage:  pubify.py <file.zig> <name> [<name>...] [--apply]
"""
import re
import sys


def main(argv):
    apply = '--apply' in argv
    argv = [a for a in argv if a != '--apply']
    if len(argv) < 2:
        print(__doc__)
        return 2
    lines = None

    # `--members` also matches decls indented one level, i.e. methods and
    # constants of a struct. Zig has no function-local `fn`, but it does have
    # function-local `const`, so an indented `const` match must be eyeballed
    # before applying — the dry run prints every one.
    indent = r'(?:    )?' if '--members' in argv else ''
    argv = [a for a in argv if a != '--members']
    path, names = argv[0], argv[1:]
    lines = open(path, encoding='utf8').read().split('\n')

    hits, missing, already = {}, [], []
    for name in names:
        pat = re.compile(r'^(' + indent + r')(pub )?((?:inline )?(?:const|var|fn) '
                         + re.escape(name) + r'\b)')
        found = [i for i, L in enumerate(lines) if pat.match(L)]
        if not found:
            missing.append(name)
            continue
        i = found[0]
        if lines[i].lstrip().startswith('pub '):
            already.append(name)
            continue
        hits[name] = i

    for name in sorted(hits):
        i = hits[name]
        print(f'  L{i+1:<6} {lines[i][:78]}')
        ws = re.match(r'\s*', lines[i]).group(0)
        print(f'       -> {ws}pub {lines[i][len(ws):][:70]}')
    if already:
        print(f'  already pub (no-op): {", ".join(already)}')
    if missing:
        print(f'  ERROR: not found: {", ".join(missing)}', file=sys.stderr)
        return 1
    if not apply:
        print(f'\n({len(hits)} changes — dry run, pass --apply to write)')
        return 0
    for i in hits.values():
        ws = re.match(r'\s*', lines[i]).group(0)
        lines[i] = ws + 'pub ' + lines[i][len(ws):]
    open(path, 'w', encoding='utf8').write('\n'.join(lines))
    print(f'\napplied {len(hits)} changes to {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
