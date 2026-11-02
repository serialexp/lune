#!/usr/bin/env python3
"""Join the JUnit fragments tests/test_runner.zig writes (one `<testcase>` line
per test, one file per test process) into one JUnit report.

    MAHINA_TEST_JUNIT_DIR=/tmp/junit zig build test
    tools/junit-merge.py /tmp/junit > junit.xml

Doc 79. Every fragment line is already well-formed XML; this only counts and
wraps them."""
import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    cases = []
    for frag in sorted(pathlib.Path(sys.argv[1]).glob("*.frag")):
        cases += [line for line in frag.read_text().splitlines() if line.startswith("<testcase")]
    failures = sum(1 for c in cases if "<failure" in c)
    skipped = sum(1 for c in cases if "<skipped" in c)
    traced = sum(1 for c in cases if re.search(r'name="requirements"', c))
    print('<?xml version="1.0" encoding="UTF-8"?>')
    print(f'<testsuites tests="{len(cases)}" failures="{failures}" skipped="{skipped}">')
    print(f'<testsuite name="mahina" tests="{len(cases)}" failures="{failures}" skipped="{skipped}">')
    for c in cases:
        print(c)
    print("</testsuite>")
    print("</testsuites>")
    print(f"{traced} of {len(cases)} cases cite a requirement", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
