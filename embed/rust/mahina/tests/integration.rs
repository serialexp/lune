//! Integration tests for the safe `mahina` crate (doc 59 E4). These also
//! exercise `mahina-sys`'s build.rs (`zig build lib`) end to end.

use mahina::{shared, Config, Error, Pending, Step, System, Task, Value, Vm};

#[test]
fn eval_scalars() {
    let vm = Vm::new().unwrap();
    assert_eq!(vm.eval("return 1 + 2", "t").unwrap()[0], Value::Int(3));
    assert_eq!(vm.eval("return 1.5 * 2", "t").unwrap()[0], Value::Float(3.0));
    assert_eq!(vm.eval("return true", "t").unwrap()[0], Value::Bool(true));
    assert_eq!(vm.eval("return nil", "t").unwrap()[0], Value::Nil);
    assert!(vm.eval("return", "t").unwrap().is_empty());
}

#[test]
fn format_normalizes_source_and_reports_syntax_errors() {
    assert_eq!(mahina::format("local x=1;").unwrap(), "local x = 1\n");
    match mahina::format("local = =") {
        Err(Error::Compile(m)) => assert!(m.contains("line 1"), "{m}"),
        other => panic!("expected a compile error, got {other:?}"),
    }
}

#[test]
fn eval_multiple_results() {
    let vm = Vm::new().unwrap();
    let out = vm.eval("return 1, 'two', 3.0", "t").unwrap();
    assert_eq!(out.len(), 3);
    assert_eq!(out[0], Value::Int(1));
    assert_eq!(out[1].as_str().unwrap().as_bytes(), b"two");
    assert_eq!(out[2], Value::Float(3.0));
}

#[test]
fn strings_round_trip() {
    let vm = Vm::new().unwrap();
    let s = vm.create_string("héllo\0world").unwrap();
    vm.set_global("s", s).unwrap();
    let got = vm.eval("return s .. '!'", "t").unwrap();
    assert_eq!(got[0].as_str().unwrap().as_bytes(), "héllo\0world!".as_bytes());
}

#[test]
fn compile_errors_are_reported_and_vm_stays_usable() {
    let vm = Vm::new().unwrap();
    match vm.eval("return 1 +", "bad") {
        Err(Error::Compile(msg)) => assert!(!msg.is_empty(), "want a diagnostic, got empty"),
        other => panic!("expected compile error, got {other:?}"),
    }
    assert_eq!(vm.eval("return 7", "t").unwrap()[0], Value::Int(7));
}

#[test]
fn runtime_errors_are_reported_and_vm_stays_usable() {
    let vm = Vm::new().unwrap();
    match vm.eval("error('kaboom')", "boom") {
        Err(Error::Runtime(msg)) => assert!(msg.contains("kaboom"), "message was {msg:?}"),
        other => panic!("expected runtime error, got {other:?}"),
    }
    assert_eq!(vm.eval("return 8", "t").unwrap()[0], Value::Int(8));
}

#[test]
fn compile_once_run_twice() {
    let vm = Vm::new().unwrap();
    vm.set_global("n", 0i64).unwrap();
    let script = vm.compile("n = n + 1 return n", "inc").unwrap();
    assert_eq!(script.run().unwrap()[0], Value::Int(1));
    assert_eq!(script.run().unwrap()[0], Value::Int(2));
}

#[test]
fn globals_both_directions() {
    let vm = Vm::new().unwrap();
    vm.set_global("x", 41i64).unwrap();
    assert_eq!(vm.eval("return x + 1", "t").unwrap()[0], Value::Int(42));
    vm.eval("answer = 42", "t").unwrap();
    assert_eq!(vm.global("answer").unwrap(), Value::Int(42));
    assert_eq!(vm.global("missing").unwrap(), Value::Nil);
}

#[test]
fn call_guest_function() {
    let vm = Vm::new().unwrap();
    vm.eval("function double(x) return x * 2 end", "t").unwrap();
    let f = vm.global("double").unwrap();
    let f = f.as_function().unwrap();
    let out: i64 = f.call(21).unwrap();
    assert_eq!(out, 42);
    // The untyped form still works: a slice of Values in, every result out.
    let out: Vec<Value> = f.call(&[Value::Int(21)]).unwrap();
    assert_eq!(out, vec![Value::Int(42)]);
}

#[test]
fn typed_call_conversions() {
    let vm = Vm::new().unwrap();
    vm.eval(
        "function swap(a, b) return b, a end
         function none() end
         function greet(s) return 'hi ' .. s end
         function count(...) return select('#', ...) end",
        "t",
    )
    .unwrap();
    let f = |name: &str| vm.global(name).unwrap().as_function().unwrap().clone();

    // Tuples in and out; a missing result reads as nil.
    let (a, b): (i64, f64) = f("swap").call((1.5, 7)).unwrap();
    assert_eq!((a, b), (7, 1.5));
    let (x, missing): (i64, Option<i64>) = f("swap").call((Option::<i64>::None, 3)).unwrap();
    assert_eq!((x, missing), (3, None));
    let nothing: Option<i64> = f("none").call(()).unwrap();
    assert_eq!(nothing, None);
    f("none").call::<_, ()>(()).unwrap();

    // Strings are interned on the way in and copied out.
    let s: String = f("greet").call("there").unwrap();
    assert_eq!(s, "hi there");
    let owned = String::from("you");
    let s: mahina::Str = f("greet").call(&owned).unwrap();
    assert_eq!(s.to_string_lossy(), "hi you");

    // Argument lists longer than the inline buffer spill correctly.
    let n: i64 = f("count").call((1, 2, 3, 4, 5, 6, 7, 8)).unwrap();
    assert_eq!(n, 8);
    let many: Vec<Value> = (0..20).map(Value::Int).collect();
    let n: i64 = f("count").call(&many).unwrap();
    assert_eq!(n, 20);
    let n: i64 = f("count").call(many).unwrap();
    assert_eq!(n, 20);

    // Handles pass by reference without a new root, and by value.
    let t = vm.create_table().unwrap();
    let (zero, back): (i64, mahina::Table) = f("swap").call((&t, 0)).unwrap();
    assert_eq!(zero, 0);
    assert_eq!(Value::Table(back), Value::Table(t.clone()));
    let (_, back): (Value, mahina::Table) = f("swap").call((t.clone(), 0)).unwrap();
    assert_eq!(Value::Table(back), Value::Table(t));

    // A conversion mismatch is a typed error, not a panic.
    match f("greet").call::<_, i64>("x") {
        Err(Error::Type { expected: "int", got: "string" }) => {}
        other => panic!("expected a type error, got {other:?}"),
    }
}

#[test]
fn typed_call_rejects_foreign_vm_values() {
    let a = Vm::new().unwrap();
    let b = Vm::new().unwrap();
    a.eval("function id(x) return x end", "t").unwrap();
    let id = a.global("id").unwrap().as_function().unwrap().clone();
    let foreign = b.create_table().unwrap();
    match id.call::<_, Value>(&foreign) {
        Err(Error::ForeignVm) => {}
        other => panic!("expected ForeignVm, got {other:?}"),
    }
    match b.call::<_, Value>(&id, 1) {
        Err(Error::ForeignVm) => {}
        other => panic!("expected ForeignVm, got {other:?}"),
    }
}

#[test]
fn tables_from_rust_and_guest() {
    let vm = Vm::new().unwrap();
    let t = vm.create_table().unwrap();
    t.set(1i64, 10i64).unwrap();
    t.set_str("name", vm.create_string("zig").unwrap()).unwrap();
    vm.set_global("t", Value::Table(t.clone())).unwrap();
    assert_eq!(vm.eval("return t[1] + #t.name", "t").unwrap()[0], Value::Int(13));

    let g = vm.eval("return {4, 5, 6}", "t").unwrap();
    let g = g[0].as_table().unwrap();
    assert_eq!(g.len().unwrap(), 3);
    assert_eq!(g.get(2i64).unwrap(), Value::Int(5));
}

#[test]
fn table_iteration_is_deterministic() {
    let vm = Vm::new().unwrap();
    let out = vm.eval("return {10, 20, 30, a = 1, b = 2}", "t").unwrap();
    let t = out[0].as_table().unwrap();

    let collect = |t: &mahina::Table| -> Vec<(String, i64)> {
        t.iter()
            .unwrap()
            .map(|kv| {
                let (k, v) = kv.unwrap();
                let key = match &k {
                    Value::Int(i) => i.to_string(),
                    Value::Str(s) => s.to_string_lossy(),
                    other => panic!("unexpected key {other:?}"),
                };
                (key, v.as_int().unwrap())
            })
            .collect()
    };

    let first = collect(t);
    assert_eq!(first.len(), 5);
    // Array part comes first, in order.
    assert_eq!(&first[..3], &[("1".into(), 10), ("2".into(), 20), ("3".into(), 30)]);
    // Hash part: fixed membership, and the order must repeat exactly.
    let mut tail: Vec<_> = first[3..].to_vec();
    tail.sort();
    assert_eq!(tail, vec![("a".into(), 1), ("b".into(), 2)]);
    assert_eq!(collect(t), first, "iteration order must be deterministic");
}

#[test]
fn metatables() {
    let vm = Vm::new().unwrap();
    let t = vm.create_table().unwrap();
    assert!(t.metatable().unwrap().is_none());
    let mt = vm.create_table().unwrap();
    let fallback = vm.eval("return function() return 99 end", "t").unwrap();
    vm.set_global("mt_probe", fallback[0].clone()).unwrap();
    vm.set_global("obj", Value::Table(t.clone())).unwrap();
    vm.eval("getmetatable_probe = 0", "t").unwrap();
    mt.set_str("__index", vm.eval("return function() return 42 end", "t").unwrap()[0].clone())
        .unwrap();
    t.set_metatable(Some(&mt)).unwrap();
    assert!(t.metatable().unwrap().is_some());
    assert_eq!(vm.eval("return obj.missing", "t").unwrap()[0], Value::Int(42));
    t.set_metatable(None).unwrap();
    assert!(t.metatable().unwrap().is_none());
}

#[test]
fn register_fn_stateful_closure() {
    let vm = Vm::new().unwrap();
    let count = shared(0i64);
    let c = count.clone();
    vm.register_fn("tick", move |_vm, _args| {
        *c.borrow_mut() += 1;
        Ok(vec![Value::Int(*c.borrow())])
    })
    .unwrap();
    assert_eq!(vm.eval("return tick() + tick() + tick()", "t").unwrap()[0], Value::Int(6));
    assert_eq!(*count.borrow(), 3);
}

/// A call statement discards the results, so the VM asks the host for none
/// (and may hand the trampoline a null result buffer). Both a host fn that
/// returns values and one that returns none must be callable that way; the
/// debug build's slice preconditions catch a slice built from the null.
#[test]
fn register_fn_called_as_a_statement() {
    let vm = Vm::new().unwrap();
    let count = shared(0i64);
    let c = count.clone();
    vm.register_fn("bump", move |_vm, _args| {
        *c.borrow_mut() += 1;
        Ok(vec![Value::Int(*c.borrow())])
    })
    .unwrap();
    vm.register_fn("noop", |_vm, _args| Ok(vec![])).unwrap();
    let out = vm.eval("bump() noop() bump() noop() return bump()", "t").unwrap();
    assert_eq!(out[0], Value::Int(3));
    assert_eq!(*count.borrow(), 3);
}

#[test]
fn register_fn_module_field() {
    let vm = Vm::new().unwrap();
    vm.register_fn("host.add", |_vm, args| {
        let a = args[0].as_int().map_err(|e| e.to_string())?;
        let b = args[1].as_int().map_err(|e| e.to_string())?;
        Ok(vec![Value::Int(a + b)])
    })
    .unwrap();
    assert_eq!(vm.eval("return host.add(40, 2)", "t").unwrap()[0], Value::Int(42));
}

#[test]
fn register_fn_rejects_builtin_names() {
    let vm = Vm::new().unwrap();
    for name in ["print", "string.format", "string"] {
        match vm.register_fn(name, |_, _| Ok(vec![])) {
            Err(Error::Api(_)) => {}
            other => panic!("registering {name:?} should be rejected, got {other:?}"),
        }
    }
}

#[test]
fn host_error_is_pcall_catchable() {
    let vm = Vm::new().unwrap();
    vm.register_fn("fail", |_vm, _args| Err("host says no".into())).unwrap();
    let out = vm.eval("local ok, err = pcall(fail) return ok, err", "t").unwrap();
    assert_eq!(out[0], Value::Bool(false));
    let msg = out[1].as_str().unwrap().to_string_lossy();
    assert!(msg.contains("host says no"), "message was {msg:?}");
    // Uncaught, it surfaces as a Runtime error and the VM recovers.
    match vm.eval("fail()", "t") {
        Err(Error::Runtime(m)) => assert!(m.contains("host says no")),
        other => panic!("expected runtime error, got {other:?}"),
    }
    assert_eq!(vm.eval("return 1", "t").unwrap()[0], Value::Int(1));
}

#[test]
fn host_panic_is_contained() {
    let vm = Vm::new().unwrap();
    vm.register_fn("explode", |_vm, _args| -> Result<Vec<Value>, String> {
        panic!("rust panic inside callback");
    })
    .unwrap();
    let out = vm.eval("local ok, err = pcall(explode) return ok, err", "t").unwrap();
    assert_eq!(out[0], Value::Bool(false));
    assert!(out[1].as_str().unwrap().to_string_lossy().contains("panic"));
    // The VM survives a contained panic.
    assert_eq!(vm.eval("return 5", "t").unwrap()[0], Value::Int(5));
}

#[test]
fn callback_can_reenter_the_vm() {
    let vm = Vm::new().unwrap();
    vm.eval("function guest_square(x) return x * x end", "t").unwrap();
    vm.register_fn("via_host", |vm, args| {
        let f = vm.global("guest_square").map_err(|e| e.to_string())?;
        let f = f.as_function().map_err(|e| e.to_string())?;
        let out: Vec<Value> = f.call(&args[0]).map_err(|e| e.to_string())?;
        Ok(out)
    })
    .unwrap();
    assert_eq!(vm.eval("return via_host(9)", "t").unwrap()[0], Value::Int(81));
}

#[test]
fn values_survive_gc_via_auto_refs() {
    let vm = Vm::new().unwrap();
    let s = vm.eval("return 'keep me ' .. 'around'", "t").unwrap().remove(0);
    let t = vm.eval("return {val = 123}", "t").unwrap().remove(0);
    // Churn the heap and force collections; the handles must stay valid.
    for _ in 0..5 {
        vm.eval("local junk = {} for i = 1, 1000 do junk[i] = 'garbage ' .. i end", "t").unwrap();
        vm.collect().unwrap();
    }
    assert_eq!(s.as_str().unwrap().as_bytes(), b"keep me around");
    let got = t.as_table().unwrap().get_str("val").unwrap();
    assert_eq!(got, Value::Int(123));
}

#[test]
fn ref_churn_many_handles() {
    let vm = Vm::new().unwrap();
    for round in 0..10 {
        let mut keep = Vec::new();
        for i in 0..100 {
            keep.push(vm.create_string(format!("r{round}-{i}")).unwrap());
        }
        vm.collect().unwrap();
        for (i, v) in keep.iter().enumerate() {
            assert_eq!(v.as_str().unwrap().as_bytes(), format!("r{round}-{i}").as_bytes());
        }
        // `keep` drops here, releasing all 100 refs; slots get reused next round.
    }
}

#[test]
fn foreign_vm_values_are_rejected() {
    let vm_a = Vm::new().unwrap();
    let vm_b = Vm::new().unwrap();
    let s = vm_a.create_string("from A").unwrap();
    match vm_b.set_global("x", s) {
        Err(Error::ForeignVm) => {}
        other => panic!("expected ForeignVm, got {other:?}"),
    }
}

#[test]
fn output_capture() {
    let vm = Vm::new().unwrap();
    vm.eval("print('hello', 42)", "t").unwrap();
    let out = vm.take_output();
    assert!(out.contains("hello"), "output was {out:?}");
    assert!(out.contains("42"), "output was {out:?}");
    assert_eq!(vm.take_output(), "", "take_output must drain");
}

#[test]
fn values_keep_the_vm_alive() {
    let s;
    {
        let vm = Vm::new().unwrap();
        s = vm.create_string("outlives the Vm handle").unwrap();
        // `vm` drops here, but `s` holds the VM via its handle.
    }
    assert_eq!(s.as_str().unwrap().as_bytes(), b"outlives the Vm handle");
}

#[test]
fn mem_stats_report() {
    let vm = Vm::new().unwrap();
    vm.eval("local t = {} for i = 1, 100 do t[i] = i end keep = t", "t").unwrap();
    let stats = vm.mem_stats();
    assert!(stats.live_bytes > 0);
    assert!(stats.peak_bytes >= stats.live_bytes);
    assert!(stats.live_allocations > 0);
}

#[test]
fn jit_hot_loop_through_embedding() {
    let vm = Vm::new().unwrap(); // JIT defaults on
    let out = vm
        .eval("local s = 0 for i = 1, 200000 do s = s + i end return s", "hot")
        .unwrap();
    assert_eq!(out[0], Value::Int(20000100000));
}

#[test]
fn truthiness_and_type_errors() {
    let vm = Vm::new().unwrap();
    assert!(!Value::Nil.truthy());
    assert!(!Value::Bool(false).truthy());
    assert!(Value::Int(0).truthy());
    let v = vm.eval("return 'str'", "t").unwrap().remove(0);
    match v.as_int() {
        Err(Error::Type { expected: "int", got: "string" }) => {}
        other => panic!("expected type error, got {other:?}"),
    }
}

#[test]
fn os_exit_is_an_error_with_the_status_and_the_vm_stays_usable() {
    let vm = Vm::with_config(Config { system: System::ENV, ..Config::default() }).unwrap();
    assert_eq!(vm.eval("pcall(os.exit, 42) return 1", "t"), Err(Error::Exit(42)));
    assert_eq!(vm.eval("return 2", "t").unwrap()[0], Value::Int(2));
    // Without the environment group there is no os.exit.
    let plain = Vm::new().unwrap();
    assert_eq!(plain.eval("return os.exit == nil", "t").unwrap()[0], Value::Bool(true));
}

#[test]
fn proc_group_installs_proc_run_only_when_enabled() {
    let plain = Vm::new().unwrap();
    assert_eq!(plain.eval("return proc == nil or proc.run == nil", "t").unwrap()[0], Value::Bool(true));
    let vm = Vm::with_config(Config { system: System::PROC, ..Config::default() }).unwrap();
    assert_eq!(vm.eval("return type(proc.run)", "t").unwrap()[0].as_str().unwrap().as_bytes(), b"function");
    assert!(System::ALL.contains(System::PROC));
}

// ---- doc 73 §7.5: tasks and host operations --------------------------------

/// `start_op()`: a new operation, parked in the guest table `ops` (so no
/// closure owns a handle) and returned to the guest.
fn register_start_op(vm: &Vm) {
    vm.eval("ops = {}", "ops").unwrap();
    vm.register_fn("start_op", |vm, _args| {
        let p = vm.pending().map_err(|e| e.to_string())?;
        let ops = vm.global("ops").map_err(|e| e.to_string())?;
        let ops = ops.as_table().map_err(|e| e.to_string())?;
        let n = ops.len().map_err(|e| e.to_string())?;
        ops.set(n + 1, p.to_value()).map_err(|e| e.to_string())?;
        Ok(vec![p.to_value()])
    })
    .unwrap();
}

fn op(vm: &Vm, i: i64) -> Pending {
    let ops = vm.global("ops").unwrap();
    Pending::from_value(&ops.as_table().unwrap().get(i).unwrap()).unwrap()
}

#[test]
fn an_await_on_a_host_operation_comes_back_as_a_waiting_task_and_finishes_once_settled() {
    let vm = Vm::new().unwrap();
    register_start_op(&vm);
    let Step::Waiting(task) = vm.eval_step("local v = await start_op() return v + 1, 'done'", "t").unwrap() else {
        panic!("expected a waiting task");
    };
    assert_eq!(task.result().unwrap().map(|r| r.len()), None);
    assert!(!vm.run_tasks().unwrap());

    op(&vm, 1).resolve(41).unwrap();
    assert!(vm.run_tasks().unwrap());
    let out = task.result().unwrap().expect("done");
    assert_eq!(out[0], Value::Int(42));
    assert_eq!(out[1].as_str().unwrap().as_bytes(), b"done");
}

#[test]
fn a_rejected_operation_fails_the_awaiting_task_with_its_error() {
    let vm = Vm::new().unwrap();
    register_start_op(&vm);
    let Step::Waiting(task) = vm.eval_step("return await start_op()", "t").unwrap() else { panic!() };
    op(&vm, 1).reject("boom").unwrap();
    assert!(vm.run_tasks().unwrap());
    match task.result() {
        Err(Error::Runtime(m)) => assert!(m.contains("boom"), "{m}"),
        other => panic!("expected a runtime error, got {:?}", other.map(|_| ())),
    }
}

#[test]
fn one_script_awaits_several_operations_settled_out_of_order() {
    let vm = Vm::new().unwrap();
    register_start_op(&vm);
    let src = "local a, b = start_op(), start_op() local y = await b local x = await a return x * 10 + y";
    let Step::Waiting(task) = vm.eval_step(src, "t").unwrap() else { panic!() };
    op(&vm, 2).resolve(3).unwrap();
    assert!(!vm.run_tasks().unwrap());
    op(&vm, 1).resolve(4).unwrap();
    assert!(vm.run_tasks().unwrap());
    assert_eq!(task.result().unwrap().unwrap()[0], Value::Int(43));
}

#[test]
fn a_wait_function_settles_operations_and_entries_finish_synchronously() {
    let vm = Vm::new().unwrap();
    register_start_op(&vm);
    let waits = shared(0i64);
    let w = waits.clone();
    vm.set_wait_fn(move |vm| {
        *w.borrow_mut() += 1;
        let ops = vm.global("ops").map_err(|e| e.to_string())?;
        let ops = ops.as_table().map_err(|e| e.to_string())?;
        let p = Pending::from_value(&ops.get(1).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        p.resolve(41).map_err(|e| e.to_string())
    })
    .unwrap();
    let out = vm.eval("local v = await start_op() return v + 1", "t").unwrap();
    assert_eq!(out[0], Value::Int(42));
    assert_eq!(*waits.borrow(), 1);
    vm.clear_wait_fn().unwrap();
}

#[test]
fn a_failing_wait_function_raises_where_the_guest_awaits() {
    let vm = Vm::new().unwrap();
    register_start_op(&vm);
    let fail = shared(true);
    let f = fail.clone();
    vm.set_wait_fn(move |vm| {
        if std::mem::replace(&mut *f.borrow_mut(), false) {
            return Err("no more events".into());
        }
        // The operation is still in flight; the next chunk's drain waits for it.
        let ops = vm.global("ops").map_err(|e| e.to_string())?;
        let p = Pending::from_value(&ops.as_table().unwrap().get(1).unwrap()).map_err(|e| e.to_string())?;
        p.resolve(()).map_err(|e| e.to_string())
    })
    .unwrap();
    match vm.eval("return await start_op()", "t") {
        Err(Error::Runtime(m)) => assert!(m.contains("no more events"), "{m}"),
        other => panic!("expected a runtime error, got {:?}", other.map(|_| ())),
    }
    // The VM stays usable; the operation left in flight is waited for after it.
    assert_eq!(vm.eval("return 1", "t").unwrap()[0], Value::Int(1));
    vm.clear_wait_fn().unwrap();
}

#[test]
fn a_plain_eval_that_waits_reports_it_instead_of_hanging() {
    let vm = Vm::new().unwrap();
    register_start_op(&vm);
    match vm.eval("return await start_op()", "t") {
        Err(Error::Api(m)) => assert!(m.contains("eval_step"), "{m}"),
        other => panic!("expected an API error, got {:?}", other.map(|_| ())),
    }
}

#[test]
fn call_step_hands_back_a_waiting_task() {
    let vm = Vm::new().unwrap();
    register_start_op(&vm);
    vm.eval("function go() return await start_op() + 1 end", "t").unwrap();
    let f = vm.global("go").unwrap().as_function().unwrap().clone();
    let Step::Waiting(task) = f.call_step(()).unwrap() else { panic!() };
    op(&vm, 1).resolve(9).unwrap();
    assert!(vm.run_tasks().unwrap());
    assert_eq!(task.result().unwrap().unwrap()[0], Value::Int(10));
    let _ = Task::from_value(&task.to_value()).unwrap();
}

// ---- spike: what a Lua prelude can do on top of the embedding ---------------

#[test]
fn a_prelude_can_reassign_print_and_stream() {
    let vm = Vm::new().unwrap();
    vm.register_fn("emit", |_vm, args| {
        let _ = args;
        Ok(vec![])
    })
    .unwrap();
    // `print` itself can't be registered, but a prelude may replace the global.
    vm.eval("local real = print print = function(...) real('>', ...) end", "prelude").unwrap();
    vm.eval("print('hi')", "t").unwrap();
    assert_eq!(vm.take_output(), ">\thi\n");
}

#[test]
fn an_error_table_raised_from_a_prelude_survives_pcall() {
    let vm = Vm::new().unwrap();
    vm.eval("fail = function(code, msg) error({ code = code, message = msg }) end", "prelude").unwrap();
    let out = vm.eval("local ok, e = pcall(fail, 'ENOENT', 'no such file') return ok, e.code, e.message", "t").unwrap();
    assert_eq!(out[0], Value::Bool(false));
    assert_eq!(out[1].as_str().unwrap().as_bytes(), b"ENOENT");
    assert_eq!(out[2].as_str().unwrap().as_bytes(), b"no such file");
    // Uncaught, the host sees the table's text only (a string message API).
    assert!(matches!(vm.eval("fail('E', 'x')", "t"), Err(Error::Runtime(_))));
}

#[test]
fn env_group_installs_os_environ_getenv_and_setenv_only_when_enabled() {
    let plain = Vm::new().unwrap();
    let out = plain.eval("return os.environ == nil, os.getenv == nil, os.setenv == nil", "t").unwrap();
    assert_eq!(out, vec![Value::Bool(true), Value::Bool(true), Value::Bool(true)]);

    let vm = Vm::with_config(Config { system: System::ENV, ..Config::default() }).unwrap();
    // os.setenv gives the VM its own environment copy; getenv and environ read it.
    let out = vm
        .eval(
            "os.setenv('MAHINA_EMBED_ENV_TEST', 'hello')
             local e = os.environ()
             local seen = 0 for _ in pairs(e) do seen = seen + 1 end
             return type(e), e.MAHINA_EMBED_ENV_TEST, os.getenv('MAHINA_EMBED_ENV_TEST'), seen > 1",
            "t",
        )
        .unwrap();
    assert_eq!(out[0].as_str().unwrap().as_bytes(), b"table");
    assert_eq!(out[1].as_str().unwrap().as_bytes(), b"hello");
    assert_eq!(out[2].as_str().unwrap().as_bytes(), b"hello");
    assert_eq!(out[3], Value::Bool(true));
    // Removing it with nil removes it from both views.
    let out = vm.eval("os.setenv('MAHINA_EMBED_ENV_TEST', nil) return os.getenv('MAHINA_EMBED_ENV_TEST'), os.environ().MAHINA_EMBED_ENV_TEST", "t").unwrap();
    assert_eq!(out, vec![Value::Nil, Value::Nil]);
}
