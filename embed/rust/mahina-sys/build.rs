//! Link libmahina (doc 59 §3.8). Three sources, checked in this order:
//!
//! - `MAHINA_PREBUILT_ROOT=<dir>`: link the prebuilt archive for cargo's
//!   `TARGET` from `<dir>/<TARGET>/` (`libmahina.a`, or `mahina.lib` on MSVC)
//!   — the layout of the vendor bundle's `lib/` (tools/mahina-bundle.sh).
//!   Never invokes zig; a target without an archive is a hard error, not a
//!   fallback to building one.
//! - `MAHINA_LIB_DIR=<dir>`: link the archive in that single directory.
//! - Neither: build it with the repo's `zig build lib`. Needs this crate to
//!   sit in a lune checkout (`<repo>/embed/rust/mahina-sys`); a bundled copy
//!   must use one of the variables above.
//!   - `ZIG=<path>`: which zig to invoke (default: `zig` from PATH). Its
//!     version is checked against the repo's `.zig-version` and a mismatch
//!     fails loudly (the stdlib is a moving target — a stray toolchain would
//!     produce mystery miscompiles, Rule Z-1).
//!   - Cargo `PROFILE` maps to the zig optimize mode (`debug` → `Debug`,
//!     everything else → `ReleaseFast`).
//!   - The zig local cache and install prefix live under `OUT_DIR`, so cargo
//!     builds never fight a developer's `zig build` in the repo (and vice
//!     versa).

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=MAHINA_PREBUILT_ROOT");
    println!("cargo:rerun-if-env-changed=MAHINA_LIB_DIR");

    let target = env::var("TARGET").unwrap();
    let archive_name = if target.ends_with("-msvc") { "mahina.lib" } else { "libmahina.a" };

    // Prebuilt bundle: one directory per Rust target triple.
    if let Some(root) = env::var_os("MAHINA_PREBUILT_ROOT") {
        let dir = PathBuf::from(&root).join(&target);
        let archive = dir.join(archive_name);
        if !archive.is_file() {
            panic!(
                "no prebuilt libmahina for this target: {target} \
                 (expected {} under MAHINA_PREBUILT_ROOT={})",
                archive.display(),
                Path::new(&root).display(),
            );
        }
        link_prebuilt(&dir, &archive);
        return;
    }

    // Prebuilt single directory: trust it, link, done.
    if let Some(dir) = env::var_os("MAHINA_LIB_DIR") {
        let dir = PathBuf::from(dir);
        let archive = dir.join(archive_name);
        if !archive.is_file() {
            panic!(
                "MAHINA_LIB_DIR={} has no {archive_name} for target {target}",
                dir.display()
            );
        }
        link_prebuilt(&dir, &archive);
        return;
    }

    build_with_zig();
}

/// Link a prebuilt archive, and rebuild whenever the archive itself changes
/// (a refreshed bundle under an unchanged variable must still relink).
fn link_prebuilt(dir: &Path, archive: &Path) {
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=static=mahina");
    println!("cargo:rerun-if-changed={}", archive.display());
}

fn build_with_zig() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    // mahina-sys -> rust -> embed -> repo root. Verified, not assumed: a copy
    // of this crate outside lune (the vendor bundle) has no repo above it.
    let repo_root = manifest
        .ancestors()
        .nth(3)
        .filter(|root| root.join("build.zig").is_file() && root.join(".zig-version").is_file())
        .unwrap_or_else(|| {
            panic!(
                "mahina-sys at {} is not inside a lune checkout (<repo>/embed/rust/mahina-sys), \
                 so it cannot build libmahina with zig. Set MAHINA_PREBUILT_ROOT=<bundle>/lib \
                 (one <rust-target-triple>/ directory per target) or MAHINA_LIB_DIR=<dir>.",
                manifest.display()
            )
        })
        .to_path_buf();
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());

    // Toolchain drift check (Rule Z-1): the repo pins a -dev Zig; refuse to
    // build with anything else rather than let the stdlib churn surface as
    // a mystery failure.
    let pinned = std::fs::read_to_string(repo_root.join(".zig-version"))
        .expect("read .zig-version at the repo root")
        .trim()
        .to_string();
    let active = Command::new(&zig)
        .arg("version")
        .output()
        .unwrap_or_else(|e| panic!("failed to run `{zig} version`: {e} (set ZIG=<path> to the pinned toolchain)"));
    let active = String::from_utf8_lossy(&active.stdout).trim().to_string();
    if active != pinned {
        panic!(
            "zig toolchain drift: `{zig}` is {active} but the repo pins {pinned}. \
             Set ZIG=<path-to-pinned-zig> (or fix PATH)."
        );
    }

    let profile = env::var("PROFILE").unwrap_or_default();
    let optimize = if profile == "debug" { "Debug" } else { "ReleaseFast" };

    let prefix = out_dir.join("zig-out");
    let cache = out_dir.join("zig-cache");
    let status = Command::new(&zig)
        .current_dir(&repo_root)
        .args(["build", "lib"])
        .arg(format!("-Doptimize={optimize}"))
        .args(["--prefix", prefix.to_str().unwrap()])
        .args(["--cache-dir", cache.to_str().unwrap()])
        .status()
        .unwrap_or_else(|e| panic!("failed to spawn `{zig} build lib`: {e}"));
    assert!(status.success(), "`zig build lib` failed (see output above)");

    println!("cargo:rustc-link-search=native={}", prefix.join("lib").display());
    println!("cargo:rustc-link-lib=static=mahina");

    // Rebuild when anything the library is built from changes. Cargo scans a
    // directory recursively, so `src` covers every Zig module and the
    // hand-written assembly under `src/asm` (doc 60), not just the files
    // someone remembered to list.
    for f in ["src", "include", "build.zig", "build.zig.zon", ".zig-version"] {
        println!("cargo:rerun-if-changed={}", repo_root.join(f).display());
    }
    println!("cargo:rerun-if-env-changed=ZIG");
}
