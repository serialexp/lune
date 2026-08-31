#!/usr/bin/env python3
"""One-shot project rename: lune -> mahina.

The name `lune` collides with lune-org/lune, a standalone Luau runtime — same
language family, same shape of tool, guaranteed confusion. This script performs
the mechanical half of the rename.

Dry-run by default (Rule #6). Pass --apply to write.

    python3 tools/rename_project.py            # show what would change
    python3 tools/rename_project.py --apply    # do it

Three case forms are substituted, longest-first so `LUNE` is not eaten by a
case-insensitive pass:

    lune -> mahina        Lune -> Mahina        LUNE -> MAHINA

A survey of every `\\w*lune\\w*` occurrence in the tree found no English word
containing "lune" as a substring — every hit is the project — so a blanket
substring replace is safe and no word-boundary logic is needed. That includes
the five owned file extensions, which fall out for free:

    .lune .lunetrace .lunesnap .luneeff .lunecov
      -> .mahina .mahinatrace .mahinasnap .mahinaeff .mahinacov
"""

import argparse
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Longest-first: substituting "lune" before "LUNE" would still be correct here
# (they do not overlap), but ordering by length keeps this robust if a mixed
# form like "LuneJIT" is ever added.
SUBS = [("LUNE", "MAHINA"), ("Lune", "Mahina"), ("lune", "mahina")]

SKIP_DIRS = {".git", ".zig-cache", "zig-out", "zig-out-debug", "node_modules",
             "dist", "target", "__pycache__"}

# Files renamed on disk. Content substitution handles the references to them.
RENAMES = [
    ("viz/fixtures/counting-loop.lunetrace", "viz/fixtures/counting-loop.mahinatrace"),
    ("viz/src/editor/LuneEditor.tsx", "viz/src/editor/MahinaEditor.tsx"),
    ("viz/src/editor/luneLanguage.ts", "viz/src/editor/mahinaLanguage.ts"),
    ("viz/src/editor/luneLinter.ts", "viz/src/editor/mahinaLinter.ts"),
    ("viz/src/wasm/lune-client.ts", "viz/src/wasm/mahina-client.ts"),
    ("viz/src/wasm/lune.ts", "viz/src/wasm/mahina.ts"),
    ("viz/src/wasm/lune.worker.ts", "viz/src/wasm/mahina.worker.ts"),
]

# This script is itself full of the old name, on purpose.
SELF = os.path.relpath(os.path.abspath(__file__), REPO)


def substitute(text):
    for old, new in SUBS:
        text = text.replace(old, new)
    return text


def walk():
    for root, dirs, files in os.walk(REPO):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, REPO)
            if rel == SELF:
                continue
            yield path, rel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="write changes")
    args = ap.parse_args()

    changed = []
    binary_hits = []

    for path, rel in walk():
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, IsADirectoryError):
            with open(path, "rb") as fh:
                if b"lune" in fh.read().lower():
                    binary_hits.append(rel)
            continue

        new_text = substitute(text)
        if new_text == text:
            continue

        hits = sum(text.count(old) for old, _ in SUBS)
        changed.append((rel, hits))
        if args.apply:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_text)

    total = sum(h for _, h in changed)
    verb = "rewrote" if args.apply else "would rewrite"
    print(f"{verb} {total} occurrences across {len(changed)} files")
    for rel, hits in sorted(changed, key=lambda x: -x[1])[:20]:
        print(f"  {hits:5d}  {rel}")
    if len(changed) > 20:
        print(f"  ... and {len(changed) - 20} more files")

    if binary_hits:
        print("\nBINARY files containing 'lune' — handle by hand:")
        for rel in binary_hits:
            print(f"  {rel}")

    print()
    verb = "renamed" if args.apply else "would rename"
    for old, new in RENAMES:
        old_abs = os.path.join(REPO, old)
        if not os.path.exists(old_abs):
            print(f"  MISSING (already renamed?): {old}")
            continue
        print(f"  {verb}: {old} -> {new}")
        if args.apply:
            subprocess.run(["git", "mv", old, new], cwd=REPO, check=True)

    if not args.apply:
        print("\ndry run — pass --apply to write")


if __name__ == "__main__":
    sys.exit(main())
