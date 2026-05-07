#!/usr/bin/env python3
"""Print uncovered lines per file from kcov's cobertura.xml.

Run after `zig build coverage` (or `./run_tests.sh`) writes
coverage/test/cobertura.xml. Lists every line with zero hits in any
file that's below 100% covered, so we can write tests for the gaps.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPORT = Path("coverage/test/cobertura.xml")


def main() -> int:
    if not REPORT.exists():
        print(f"no coverage report at {REPORT}; run ./run_tests.sh first", file=sys.stderr)
        return 1

    tree = ET.parse(REPORT)
    root = tree.getroot()
    any_gaps = False
    for cls in root.iter("class"):
        filename = cls.get("filename", "?")
        rate = float(cls.get("line-rate", "1"))
        if rate >= 1.0:
            continue
        gaps = [int(line.get("number")) for line in cls.iter("line") if int(line.get("hits", "0")) == 0]
        if not gaps:
            continue
        any_gaps = True
        pct = rate * 100
        print(f"=== {filename} ({pct:.2f}%)")
        for n in gaps:
            print(f"  line {n}")

    if not any_gaps:
        print("100% covered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
