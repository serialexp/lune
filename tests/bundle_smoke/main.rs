//! The vendor-bundle smoke program (tools/bundle-smoke.sh): built against a
//! bundle's `rust/mahina` with `MAHINA_PREBUILT_ROOT=<bundle>/lib` and no zig
//! on PATH, then run on its target (natively, or under qemu/wine). One VM
//! lifecycle through the safe crate: compile + run guest code with a loop hot
//! enough to tier up, a host-function round trip, strings, a table, a GC, and
//! teardown. Prints `bundle-smoke ok` and exits 0 only if every check holds.

use mahina::{Value, Vm};

fn main() {
    let vm = Vm::new().expect("mh_vm_new");

    vm.register_fn("host_add", |_vm, args| {
        let a = args[0].as_int().map_err(|e| format!("{e:?}"))?;
        let b = args[1].as_int().map_err(|e| format!("{e:?}"))?;
        Ok(vec![Value::Int(a + b)])
    })
    .expect("register_fn");

    let src = r#"
        local sum = 0
        for i = 1, 200000 do sum = sum + i % 7 end
        local t = {}
        for i = 1, 100 do t[i] = host_add(i, 1) end
        return sum, #t, t[100], "mahina" .. "-" .. "bundle"
    "#;
    let out = vm.eval(src, "smoke").expect("eval");
    assert_eq!(out[0], Value::Int(599997), "loop sum");
    assert_eq!(out[1], Value::Int(100), "table length");
    assert_eq!(out[2], Value::Int(101), "host call result");
    assert_eq!(out[3].as_str().expect("string").as_bytes(), b"mahina-bundle");

    let script = vm.compile("n = (n or 0) + 1 return n", "inc").expect("compile");
    assert_eq!(script.run().expect("run")[0], Value::Int(1));
    assert_eq!(script.run().expect("run")[0], Value::Int(2));

    vm.collect().expect("collect");
    drop(script);
    drop(vm);
    println!("bundle-smoke ok");
}
