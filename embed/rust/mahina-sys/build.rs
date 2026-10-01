//! Build libmahina via the repo's `zig build lib` (doc 59 §3.8).
//!
//! - `MAHINA_LIB_DIR=<dir>`: skip the zig build and link a prebuilt
//!   `libmahina.a` from that directory.
//! - `ZIG=<path>`: which zig to invoke (default: `zig` from PATH). Its
//!   version is checked against the repo's `.zig-version` and a mismatch
//!   fails loudly (the stdlib is a moving target — a stray toolchain would
//!   produce mystery miscompiles, Rule Z-1).
//! - Cargo `PROFILE` maps to the zig optimize mode (`debug` → `Debug`,
//!   everything else → `ReleaseFast`).
//! - The zig local cache and install prefix live under `OUT_DIR`, so cargo
//!   builds never fight a developer's `zig build` in the repo (and vice
//!   versa).

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    // Prebuilt override: trust the directory, link, done.
    if let Ok(dir) = env::var("MAHINA_LIB_DIR") {
        println!("cargo:rustc-link-search=native={dir}");
        println!("cargo:rustc-link-lib=static=mahina");
        println!("cargo:rerun-if-env-changed=MAHINA_LIB_DIR");
        return;
    }

    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest
        .ancestors()
        .nth(3) // mahina-sys -> rust -> embed -> repo root
        .expect("mahina-sys must live at <repo>/embed/rust/mahina-sys")
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

    // Rebuild when the Zig surface changes.
    for f in [
        "src/capi.zig",
        "include/mahina.h",
        "build.zig",
        ".zig-version",
        "src/interp.zig",
        "src/function.zig",
    ] {
        println!("cargo:rerun-if-changed={}", repo_root.join(f).display());
    }
    println!("cargo:rerun-if-env-changed=ZIG");
    println!("cargo:rerun-if-env-changed=MAHINA_LIB_DIR");
}
