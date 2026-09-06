#!/usr/bin/env python3
"""Focused tests for check-jit-boundaries.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).with_name("check-jit-boundaries.py")
SPEC = importlib.util.spec_from_file_location("check_jit_boundaries", CHECKER)
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = checker
SPEC.loader.exec_module(checker)


class TemporarySourceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.src = Path(self.temporary.name) / "src"
        self.src.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, contents: str = "") -> Path:
        path = self.src / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def names(self, path: tuple[Path, ...]) -> list[str]:
        return [item.name for item in path]


class ImportLexingTests(TemporarySourceTest):
    def test_comments_strings_chars_multiline_and_tests_are_not_imports(self) -> None:
        source = self.write(
            "sample.zig",
            r'''
// const comment = @import("comment.zig");
const ordinary = "@import(\"string.zig\") { test";
const character = '@';
const escaped = "quote: \" and slash: \\";
const multiline =
    \\ @import("multiline.zig") {
    \\ test "not syntax" { @import("also_fake.zig"); }
;
test "nested braces do not end exclusion early" {
    if (true) { const fake = @import("test_body.zig"); }
    const after_nested = @import("still_test.zig");
}
test { const anonymous_fake = @import("anonymous_test.zig"); }
const real = @import("real.zig");
''',
        )
        self.assertEqual(["real.zig"], checker.production_imports(source))

    def test_braces_in_test_literals_do_not_end_test_block(self) -> None:
        source = self.write("sample.zig", '''
 test "{" {
     const closing = "}";
     const opening = '{';
     const hidden = @import("hidden.zig");
 }
 const real = @import("real.zig");
 ''')
        self.assertEqual(["real.zig"], checker.production_imports(source))

    def test_production_import_inside_nested_function_is_counted(self) -> None:
        source = self.write(
            "sample.zig",
            '''
fn choose() void {
    if (enabled) {
        const forbidden = @import("nativegen.zig");
    }
}
''',
        )
        self.assertEqual(["nativegen.zig"], checker.production_imports(source))

    def test_dedicated_test_and_testutil_files_and_imports_are_excluded(self) -> None:
        self.write("ir_eval.zig", 'const helper = @import("helper_testutil.zig");\n')
        self.write("helper_testutil.zig", 'const bad = @import("trace.zig");\n')
        self.write("unrelated_test.zig", 'const bad = @import("trace.zig");\n')
        self.write("trace.zig")
        self.assertEqual([], checker.check_boundaries(self.src))


class BoundaryTests(TemporarySourceTest):
    def test_leaf_rules_accept_clean_dependencies(self) -> None:
        self.write("trace_exec.zig", 'const std = @import("std");\n')
        self.write("ir_eval.zig", 'const vocabulary = @import("trace_ir.zig");\n')
        self.write("trace_ir.zig")
        self.write("tropt.zig", 'const evaluator = @import("ir_eval.zig");\n')
        self.assertEqual([], checker.check_boundaries(self.src))

    def test_trace_exec_rejects_any_project_dependency(self) -> None:
        self.write("trace_exec.zig", 'const value = @import("value.zig");\n')
        self.write("value.zig")
        violations = checker.check_boundaries(self.src)
        self.assertEqual(1, len(violations))
        self.assertEqual(["trace_exec.zig", "value.zig"], self.names(violations[0].path))

    def test_transitive_violation_reports_actionable_path_through_cycle(self) -> None:
        self.write("tropt.zig", 'const first = @import("first.zig");\n')
        self.write("first.zig", 'const second = @import("second.zig");\n')
        self.write(
            "second.zig",
            'const cycle = @import("first.zig");\n'
            'const backend = @import("nativegen.zig");\n',
        )
        self.write("nativegen.zig")
        violations = checker.check_boundaries(self.src)
        self.assertEqual(1, len(violations))
        self.assertEqual(
            ["tropt.zig", "first.zig", "second.zig", "nativegen.zig"],
            self.names(violations[0].path),
        )
        self.assertIn(
            "tropt.zig -> first.zig -> second.zig -> nativegen.zig",
            violations[0].format(self.src.resolve()),
        )

    def test_ir_eval_and_optional_trace_code_rules(self) -> None:
        self.write("ir_eval.zig", 'const helper = @import("eval_helper.zig");\n')
        self.write("eval_helper.zig", 'const runtime = @import("irinterp.zig");\n')
        self.write("irinterp.zig")
        self.write("trace_code.zig", 'const helper = @import("code_helper.zig");\n')
        self.write("code_helper.zig", 'const lifecycle = @import("trace.zig");\n')
        self.write("trace.zig")
        violations = checker.check_boundaries(self.src)
        self.assertEqual(2, len(violations))
        self.assertEqual(
            [
                ["ir_eval.zig", "eval_helper.zig", "irinterp.zig"],
                ["trace_code.zig", "code_helper.zig", "trace.zig"],
            ],
            [self.names(violation.path) for violation in violations],
        )

    def test_executor_and_serializer_direct_contracts(self) -> None:
        self.write("trace.zig")
        self.write("nativegen.zig", 'const bad = @import("trace.zig");')
        self.write("irinterp.zig", 'const bad = @import("nativegen.zig");')
        self.write("traceser.zig", 'const bad = @import("irinterp.zig");')
        violations = checker.check_boundaries(self.src)
        self.assertEqual(3, len(violations))
        self.assertEqual(
            [["nativegen.zig", "trace.zig"], ["irinterp.zig", "nativegen.zig"],
             ["traceser.zig", "irinterp.zig"]],
            [self.names(v.path) for v in violations],
        )

    def test_code_consumers_reject_record_dependency(self) -> None:
        self.write("trace_record.zig")
        for name in ("nativegen.zig", "irinterp.zig", "traceser.zig"):
            self.write(name, 'const record = @import("trace_record.zig");')
        self.assertEqual(3, len(checker.check_boundaries(self.src)))

    def test_entry_registry_rejects_coordinator_and_policy(self) -> None:
        self.write("trace_record.zig")
        self.write("trace_entry_registry.zig", 'const record = @import("trace_record.zig");')
        self.assertEqual([], checker.check_boundaries(self.src))
        self.write("trace.zig")
        self.write("trace_regionops.zig")
        self.write("trace_entry_registry.zig",
                   'const coordinator = @import("trace.zig");'
                   'const policy = @import("trace_regionops.zig");')
        self.assertEqual(2, len(checker.check_boundaries(self.src)))

    def test_native_registry_rejects_coordinator_and_policy(self) -> None:
        self.write("trace_record.zig")
        self.write("nativegen.zig")
        self.write("trace_native_registry.zig",
                   'const record = @import("trace_record.zig");'
                   'const backend = @import("nativegen.zig");')
        self.assertEqual([], checker.check_boundaries(self.src))
        self.write("trace_chain.zig")
        self.write("trace_native_registry.zig", 'const bad = @import("trace_chain.zig");')
        self.assertEqual(1, len(checker.check_boundaries(self.src)))

    def test_registry_composes_owners_without_coordinator(self) -> None:
        self.write("trace_native_registry.zig")
        self.write("trace_entry_registry.zig")
        self.write("trace_registry.zig",
                   'const native = @import("trace_native_registry.zig");'
                   'const entry = @import("trace_entry_registry.zig");')
        self.assertEqual([], checker.check_boundaries(self.src))
        self.write("trace.zig")
        self.write("trace_registry.zig", 'const bad = @import("trace.zig");')
        self.assertEqual(1, len(checker.check_boundaries(self.src)))

    def test_policy_and_recording_owners_reject_coordinator_dependencies(self) -> None:
        self.write("trace.zig")
        self.write("trace_registry.zig")
        self.write("trace_region_policy.zig", 'const bad = @import("trace_registry.zig");')
        self.write("trace_recording_session.zig", 'const bad = @import("trace.zig");')
        self.assertEqual(2, len(checker.check_boundaries(self.src)))

    def test_cli_returns_nonzero_and_prints_path(self) -> None:
        self.write("tropt.zig", 'const bad = @import("trace.zig");\n')
        self.write("trace.zig")
        completed = subprocess.run(
            [sys.executable, str(CHECKER), "--src", str(self.src)],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(1, completed.returncode)
        self.assertIn("JIT boundary violation", completed.stderr)
        self.assertIn("tropt.zig -> trace.zig", completed.stderr)


if __name__ == "__main__":
    unittest.main()
