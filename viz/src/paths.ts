// Program file paths: relative to the program's directory, `/`-separated.
// Mirrors `normalize` in src/relpath.zig (the wasm entry's file set and
// `mahina viz`'s `/project` and `/run`), so a `require` candidate like
// `./lib/util.mah` finds the tab named `lib/util.mah`.

/** The longest path `normalize` in src/relpath.zig fits (`max_len`). */
const MAX_LEN = 1024;

/** Normalize a relative path lexically: drop empty and `.` segments, resolve
 *  `..` against the segment before it. Null when the path is absolute, climbs
 *  above the root, is empty, or is longer than the Zig side fits. Pure. */
export function normalizePath(path: string): string | null {
  if (path.length === 0 || path.startsWith("/")) return null;
  const out: string[] = [];
  for (const seg of path.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (out.length === 0) return null;
      out.pop();
      continue;
    }
    out.push(seg);
  }
  const norm = out.join("/");
  return norm.length === 0 || new TextEncoder().encode(norm).length > MAX_LEN ? null : norm;
}

/** The last segment of a path (`lib/util.mah` → `util.mah`). Pure. */
export function baseName(path: string): string {
  const i = path.lastIndexOf("/");
  return i < 0 ? path : path.slice(i + 1);
}
