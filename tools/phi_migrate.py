#!/usr/bin/env python3
"""E0: convert nativegen.zig test Trace literals from `.exit_stores = &exits`
to slot-bound `phi` instrs spliced before the terminal `.op = .loop`.

Dry-run by default; pass --apply to write. Only touches literal-array tests
(`var NAME = [_]S{...};`); runtime ArrayList helpers are left for hand-edit.
"""
import re
import sys

PATH = "src/nativegen.zig"

decl_re = re.compile(r"^(\s*)var (\w+) = \[_\]S\{(.*)\};\s*$")
entry_re = re.compile(r"\.\{\s*\.slot\s*=\s*(\d+)\s*,\s*\.ref\s*=\s*(\d+)\s*\}")
loop_re = re.compile(r"\.op = \.loop")


def main():
    apply = "--apply" in sys.argv
    with open(PATH) as f:
        lines = f.readlines()

    # ops keyed by original line index
    delete = set()         # line idx -> remove
    insert_before = {}     # line idx -> list of new lines
    replace = {}           # line idx -> new line

    i = 0
    matches = 0
    for idx, line in enumerate(lines):
        m = decl_re.match(line)
        if not m:
            continue
        indent, name, content = m.group(1), m.group(2), m.group(3)
        entries = entry_re.findall(content)
        if not entries:
            # empty `[_]S{}` — just delete decl + strip field
            entries = []
        matches += 1
        # find the loop line: last `.op = .loop` strictly before this decl
        loop_idx = None
        for j in range(idx - 1, -1, -1):
            if loop_re.search(lines[j]):
                loop_idx = j
                break
        if loop_idx is None:
            print(f"!! no loop line found before decl at {idx+1}", file=sys.stderr)
            sys.exit(1)
        loop_indent = re.match(r"^(\s*)", lines[loop_idx]).group(1)
        phi_lines = [
            f"{loop_indent}.{{ .op = .phi, .b = {ref}, .aux = {slot} }},\n"
            for (slot, ref) in entries
        ]
        insert_before.setdefault(loop_idx, []).extend(phi_lines)
        delete.add(idx)
        # the Trace line: next line containing `.exit_stores = &NAME`
        field = f", .exit_stores = &{name}"
        trace_idx = None
        for j in range(idx + 1, min(idx + 4, len(lines))):
            if field in lines[j]:
                trace_idx = j
                break
        if trace_idx is None:
            print(f"!! no Trace line for {name} after {idx+1}", file=sys.stderr)
            sys.exit(1)
        replace[trace_idx] = lines[trace_idx].replace(field, "")

    # rebuild
    out = []
    for idx, line in enumerate(lines):
        if idx in insert_before:
            out.extend(insert_before[idx])
        if idx in delete:
            continue
        if idx in replace:
            out.append(replace[idx])
        else:
            out.append(line)

    print(f"matched {matches} literal exits decls", file=sys.stderr)
    if apply:
        with open(PATH, "w") as f:
            f.writelines(out)
        print("applied", file=sys.stderr)
    else:
        # show a small diff sample around first few changes
        import difflib
        diff = difflib.unified_diff(lines, out, lineterm="", n=2)
        sys.stdout.write("\n".join(list(diff)[:120]))


if __name__ == "__main__":
    main()
