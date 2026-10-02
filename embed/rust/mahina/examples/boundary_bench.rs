//! Boundary-cost benchmark for the embedding API (doc 59 E5).
//!
//! Run deliberately (never as a test gate — Rule #22):
//!
//! ```sh
//! just embed-bench            # from the repo root, or
//! cargo run --release --example boundary_bench
//! ```
//!
//! Each line reports the amortized cost of one crossing of the Rust↔mahina
//! boundary. These are the numbers an embedder budgets against (a game host
//! calling into guest scripts per frame), so the interesting failures are
//! per-op costs that grow with VM state — which is why the iteration and ref
//! benches run against large tables/heaps.

use std::time::Instant;

use mahina::{Value, Vm};

fn bench(name: &str, iters: u64, mut f: impl FnMut()) {
    // One untimed warmup round lets the JIT tier up / caches settle.
    f();
    let start = Instant::now();
    for _ in 0..iters {
        f();
    }
    let elapsed = start.elapsed();
    let per = elapsed.as_nanos() as f64 / iters as f64;
    println!("{name:<44} {per:>10.0} ns/op   ({iters} iters, {elapsed:.2?} total)");
}

fn main() {
    let vm = Vm::new().expect("vm");

    // --- host → guest: call a trivial guest function -----------------------
    vm.eval("function id(x) return x end", "bench").unwrap();
    let id = vm.global("id").unwrap();
    let id = id.as_function().unwrap().clone();
    bench("host->guest call (typed i64 -> i64)", 100_000, || {
        let out: i64 = id.call(7).unwrap();
        assert_eq!(out, 7);
    });
    bench("host->guest call (&[Value] -> Vec<Value>)", 100_000, || {
        let out: Vec<Value> = id.call(&[Value::Int(7)]).unwrap();
        assert_eq!(out[0], Value::Int(7));
    });

    // --- guest → host: guest loop hammering a registered callback ----------
    vm.register_fn("host_id", |_vm, args| Ok(vec![args[0].clone()]))
        .unwrap();
    let cb_loop = vm
        .compile("local s = 0 for i = 1, 100000 do s = s + host_id(1) end return s", "cb")
        .unwrap();
    bench("guest->host callback (amortized, x100k)", 10, || {
        let out = cb_loop.run().unwrap();
        assert_eq!(out[0], Value::Int(100_000));
    });

    // --- table field get / set ---------------------------------------------
    let t = vm.create_table().unwrap();
    let key = vm.create_string("field").unwrap();
    t.set(key.clone(), 1i64).unwrap();
    bench("table get (string key)", 100_000, || {
        let v = t.get(key.clone()).unwrap();
        assert_eq!(v, Value::Int(1));
    });
    bench("table set (string key)", 100_000, || {
        t.set(key.clone(), 2i64).unwrap();
    });

    // --- iteration over a large hash table ---------------------------------
    vm.eval(
        "big = {} for i = 1, 10000 do big['k' .. i] = i end",
        "bench",
    )
    .unwrap();
    let big = vm.global("big").unwrap();
    let big = big.as_table().unwrap().clone();
    bench("table iteration (10k hash entries, per entry)", 10, || {
        let mut n = 0u64;
        for kv in big.iter().unwrap() {
            kv.unwrap();
            n += 1;
        }
        assert_eq!(n, 10_000);
    });
    println!("{:<44} {:>10}", "  (divide the line above by 10000)", "");

    // --- ref churn under a live heap ----------------------------------------
    bench("ref create+drop (rooted string)", 100_000, || {
        let s = vm.create_string("churn").unwrap();
        drop(s);
    });

    // --- repeated compilation ----------------------------------------------
    let src = "local acc = 0 for i = 1, 10 do acc = acc + i end return acc";
    bench("compile small chunk", 10_000, || {
        let s = vm.compile(src, "recompile").unwrap();
        drop(s);
    });

    // --- eval round trip (compile + run + wrap) -----------------------------
    bench("eval 'return 1 + 2'", 10_000, || {
        let out = vm.eval("return 1 + 2", "bench").unwrap();
        assert_eq!(out[0], Value::Int(3));
    });

    let stats = vm.mem_stats();
    println!(
        "\nVM memory after bench: live {} KiB (peak {} KiB, {} live allocations)",
        stats.live_bytes / 1024,
        stats.peak_bytes / 1024,
        stats.live_allocations
    );
}
