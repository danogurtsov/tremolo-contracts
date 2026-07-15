#!/usr/bin/env python3
"""
Mutation testing: does the test suite actually catch anything?

Line coverage says a line ran. It does not say that anything would have noticed had the line
been wrong. This introduces small, plausible defects into the source one at a time, runs the
suite against each, and counts how many go unnoticed.

A surviving mutant is a hole in the argument, not necessarily a bug in the code: it means some
behaviour is unconstrained by any test, so nothing would stop a future change from breaking it.

Usage:
    python3 tools/mutate.py                       # every source file, default operators
    python3 tools/mutate.py --file src/VarianceMarket.sol
    python3 tools/mutate.py --limit 20            # sample, for a quick signal
    python3 tools/mutate.py --report docs/measurements/mutation_report.md

Fork tests are excluded: they need network access and their cost dominates the run.
"""

from __future__ import annotations

import argparse
import atexit
import signal
import json
import random
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"

# Each operator is a (name, pattern, replacement). They are chosen to be *plausible* mistakes —
# an inverted comparison, a swapped rounding direction, a dropped guard — rather than arbitrary
# corruption, which the compiler would reject anyway.
OPERATORS: list[tuple[str, str, str]] = [
    ("le-to-lt", r"(?<![<>=!])<=", "<"),
    ("ge-to-gt", r"(?<![<>=!])>=", ">"),
    ("lt-to-le", r"(?<![<>=!])<(?!=)", "<="),
    ("gt-to-ge", r"(?<![<>=!])>(?!=)", ">="),
    ("eq-to-ne", r"==", "!="),
    ("plus-to-minus", r"(?<![+\-=<>!*/%])\+(?![+=])", "-"),
    ("minus-to-plus", r"(?<![+\-=<>!*/%])-(?![-=>])", "+"),
    ("mul-to-div", r"(?<![*/=])\*(?![*=/])", "/"),
    ("div-to-mul", r"(?<![*/=])/(?![/*=])", "*"),
]

# Lines that are documentation, pragmas or imports are never mutated.
SKIP_LINE = re.compile(r"^\s*(///|//|/\*|\*|pragma|import|SPDX)")


@dataclass
class Mutant:
    file: str
    line: int
    operator: str
    before: str
    after: str
    killed: bool = False
    detail: str = ""


@dataclass
class Result:
    mutants: list[Mutant] = field(default_factory=list)

    @property
    def killed(self) -> int:
        return sum(1 for m in self.mutants if m.killed)

    @property
    def survived(self) -> list[Mutant]:
        return [m for m in self.mutants if not m.killed]

    @property
    def score(self) -> float:
        return 100.0 * self.killed / len(self.mutants) if self.mutants else 0.0


def source_files(only: str | None) -> list[Path]:
    if only:
        return [ROOT / only]
    return [p for p in sorted(SRC.rglob("*.sol")) if "mocks" not in p.parts]


def generate(files: list[Path]) -> list[Mutant]:
    out: list[Mutant] = []
    for path in files:
        rel = str(path.relative_to(ROOT))
        for lineno, line in enumerate(path.read_text().splitlines(), start=1):
            if SKIP_LINE.match(line) or not line.strip():
                continue
            for name, pattern, repl in OPERATORS:
                if re.search(pattern, line):
                    mutated = re.sub(pattern, repl, line, count=1)
                    if mutated != line:
                        out.append(Mutant(rel, lineno, name, line.strip(), mutated.strip()))
    return out


def apply(path: Path, lineno: int, new_line: str) -> None:
    lines = path.read_text().splitlines(keepends=True)
    indent = len(lines[lineno - 1]) - len(lines[lineno - 1].lstrip())
    lines[lineno - 1] = " " * indent + new_line + "\n"
    path.write_text("".join(lines))


def run_suite(timeout: int) -> tuple[bool, str]:
    """True if the suite passed, i.e. the mutant survived."""
    try:
        proc = subprocess.run(
            ["forge", "test", "--no-match-path", "test/fork/*", "--fail-fast"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, "timeout (killed by slow-down, counts as caught)"

    if proc.returncode != 0:
        tail = (proc.stdout or "")[-400:]
        if "Compiler run failed" in proc.stdout or "Compiler run failed" in proc.stderr:
            return False, "did not compile"
        return False, tail.strip().splitlines()[-1] if tail.strip() else "suite failed"
    return True, ""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file")
    ap.add_argument("--limit", type=int, default=0, help="random sample of N mutants")
    ap.add_argument("--seed", type=int, default=20260728)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--report")
    args = ap.parse_args()

    files = source_files(args.file)
    mutants = generate(files)
    if args.limit and args.limit < len(mutants):
        random.Random(args.seed).shuffle(mutants)
        mutants = mutants[: args.limit]

    print(f"{len(mutants)} mutants across {len(files)} files\n")
    backups = {f: f.read_text() for f in files}

    # A `finally` block is not enough: this run can be killed from outside, and a SIGKILL leaves
    # a mutated source file on disk that looks exactly like a real edit. Restoring from an exit
    # handler covers ordinary termination, and the signal handlers cover the rest.
    def restore(*_):
        for f, text in backups.items():
            f.write_text(text)

    atexit.register(restore)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: (restore(), sys.exit(130)))
    result = Result()
    started = time.time()

    try:
        for i, m in enumerate(mutants, start=1):
            path = ROOT / m.file
            apply(path, m.line, m.after)
            survived, detail = run_suite(args.timeout)
            path.write_text(backups[path])

            m.killed = not survived
            m.detail = detail
            result.mutants.append(m)

            mark = "killed " if m.killed else "SURVIVED"
            print(f"[{i}/{len(mutants)}] {mark} {m.file}:{m.line} {m.operator}")
            if not m.killed:
                print(f"           {m.before}")
                print(f"        -> {m.after}")
    finally:
        for f, text in backups.items():
            f.write_text(text)

    elapsed = time.time() - started
    print(f"\nscore {result.score:.1f}%  ({result.killed}/{len(result.mutants)} killed)"
          f"  in {elapsed / 60:.1f} min")

    if result.survived:
        print(f"\n{len(result.survived)} survivors:")
        for m in result.survived:
            print(f"  {m.file}:{m.line}  {m.operator}  {m.before}  ->  {m.after}")

    if args.report:
        write_report(Path(ROOT / args.report), result, elapsed)
        print(f"\nwrote {args.report}")

    sys.exit(0)


def write_report(path: Path, result: Result, elapsed: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Measurement — mutation testing",
        "",
        f"**Date:** 2026-07-28 · **Reproduce:** `python3 tools/mutate.py --report {path.relative_to(ROOT)}`",
        "",
        "Line coverage says a line ran. It does not say anything would have noticed had that",
        "line been wrong. This introduces one plausible defect at a time and checks whether the",
        "suite catches it.",
        "",
        f"**Score: {result.score:.1f}%** — {result.killed} of {len(result.mutants)} mutants killed,",
        f"in {elapsed / 60:.1f} minutes.",
        "",
    ]
    if result.survived:
        lines += [
            "## Survivors",
            "",
            "Each is behaviour no test constrains. Not necessarily a bug — but nothing would",
            "stop a future change from breaking it.",
            "",
            "| File | Line | Operator | Change |",
            "|---|---|---|---|",
        ]
        for m in result.survived:
            change = f"`{m.before}` → `{m.after}`"
            lines.append(f"| {m.file} | {m.line} | {m.operator} | {change} |")
    else:
        lines += ["## Survivors", "", "None."]
    path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
