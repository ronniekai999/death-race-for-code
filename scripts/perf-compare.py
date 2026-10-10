#!/usr/bin/env python3
"""Capture repeated engine benchmarks and compare matched machines/toolchains."""
import argparse
import datetime
import json
import math
import platform
import re
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKLOADS = {"ascii", "sgr", "unicode", "cursor"}


def processor_model():
    if platform.system() == "Darwin":
        return subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string", "hw.model"], text=True).strip()
    if platform.system() == "Linux":
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    return platform.processor() or platform.machine()


def capture(args):
    if args.rounds < 3 or not math.isfinite(args.seconds) or not .1 <= args.seconds <= 60:
        raise SystemExit("Use at least three rounds and 0.1–60 seconds per workload.")
    samples = {name: [] for name in WORKLOADS}
    for index in range(args.rounds):
        result = subprocess.check_output([str(args.binary.resolve()), "bench", "--seconds", str(args.seconds)], text=True)
        found = dict(re.findall(r"^(ascii|sgr|unicode|cursor)\s+([0-9.]+) MB/s$", result, re.MULTILINE))
        if set(found) != WORKLOADS or "debug build" in result:
            raise SystemExit("A release vthost with all four workloads is required.")
        for name, value in found.items():
            number = float(value)
            if not math.isfinite(number) or number <= 0:
                raise SystemExit("Invalid benchmark sample")
            samples[name].append(number)
        print(f"Round {index + 1}/{args.rounds} captured", flush=True)
    report = {
        "schema": 1,
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "commit": args.commit or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": processor_model(),
        "toolchain": subprocess.check_output(["swift", "--version"], text=True).strip(),
        "seconds": args.seconds,
        "rounds": args.rounds,
        "samples_mib_s": samples,
        "median_mib_s": {name: statistics.median(values) for name, values in samples.items()},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Wrote {args.output}")


def compare(args):
    if not math.isfinite(args.max_regression) or not 0 <= args.max_regression < 100:
        raise SystemExit("Regression budget must be finite and between 0 and 100 percent.")
    baseline, current = (json.loads(path.read_text()) for path in (args.baseline, args.current))
    for key in ("schema", "platform", "machine", "processor", "toolchain", "seconds", "rounds"):
        if baseline.get(key) != current.get(key):
            raise SystemExit(f"Incomparable runs: {key} differs. Capture both on the same machine/toolchain.")
    failures = []
    for name in sorted(WORKLOADS):
        for report in (baseline, current):
            values = report.get("samples_mib_s", {}).get(name, [])
            if len(values) < 3 or any(not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0 for value in values):
                raise SystemExit(f"Missing/invalid samples for {name}")
            middle = statistics.median(values)
            if (max(values) - min(values)) / middle > .15:
                raise SystemExit(f"Inconclusive: {name} varied more than 15%; rerun on an idle machine.")
        before = statistics.median(baseline["samples_mib_s"][name])
        after = statistics.median(current["samples_mib_s"][name])
        delta = (after / before - 1) * 100
        print(f"{name:8s} {before:7.1f} → {after:7.1f} MiB/s ({delta:+.1f}%)")
        if delta < -args.max_regression:
            failures.append(name)
    if failures:
        raise SystemExit("Performance regression exceeds budget: " + ", ".join(failures))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    record = actions.add_parser("capture")
    record.add_argument("--binary", type=Path, required=True)
    record.add_argument("--output", type=Path, required=True)
    record.add_argument("--commit")
    record.add_argument("--rounds", type=int, default=5)
    record.add_argument("--seconds", type=float, default=2)
    check = actions.add_parser("compare")
    check.add_argument("baseline", type=Path)
    check.add_argument("current", type=Path)
    check.add_argument("--max-regression", type=float, default=10)
    args = parser.parse_args()
    {"capture": capture, "compare": compare}[args.action](args)
