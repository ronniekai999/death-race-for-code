#!/usr/bin/env python3
"""Collect reproducible Mac evidence; completion requires reviewed hardware results."""
import argparse
import hashlib
import json
import math
import platform
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GOLDENS = ("htop", "vim-syntax", "tmux-split", "less-search", "vttest-colors", "vttest-colors-glow")


def manual_checks():
    checklist = {}
    for text in (ROOT / "docs/MANUAL-TESTS.md").read_text().splitlines():
        match = re.match(r"\s*- \[[ xX]\] (.*)", text)
        if match:
            label = match.group(1)
            key = hashlib.sha256(label.encode()).hexdigest()[:12]
            checklist[key] = {"check": label, "status": "unverified", "evidence": ""}
    return checklist


def output(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def run(directory):
    if platform.system() != "Darwin":
        raise SystemExit("Mac acceptance needs macOS 26 and a real Metal display/GPU.")
    directory.mkdir(parents=True, exist_ok=True)
    report = {
        "schema": 1,
        "commit": output(["git", "rev-parse", "HEAD"]),
        "dirty": bool(output(["git", "status", "--porcelain"])),
        "os": output(["sw_vers"]),
        "hardware": output(["sysctl", "-n", "hw.model"]),
        "processor": output(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "toolchain": output(["swift", "--version"]),
        "checks": {},
    }
    commands = {
        "tests": ["swift", "test", "--package-path", "Packages/DeathRaceKit"],
        "render": ["make", "test-render"],
        "throughput": ["make", "bench"],
    }
    for name, command in commands.items():
        print(f"Running {name}; log: {directory / (name + '.log')}", flush=True)
        with (directory / (name + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        report["checks"][name] = {"exit": result.returncode, "log": name + ".log"}
        (directory / "run.json").write_text(json.dumps(report, indent=2) + "\n")
    fixtures = ROOT / "Packages/DeathRaceKit/Tests/Fixtures/render"
    report["goldens"] = {
        name: hashlib.sha256((fixtures / (name + ".png")).read_bytes()).hexdigest()
        for name in GOLDENS if (fixtures / (name + ".png")).exists()
    }
    manual_path = directory / "manual.json"
    if not manual_path.exists():
        manual = {
            "real_hardware": False,
            "privacy_verdict": "unverified",
            "privacy_reports": [],
            "goldens_reviewed": False,
            "idle_wakeups_per_second": None,
            "idle_frames": None,
            "hidden_frames": None,
            "key_to_screen_p95_ms": None,
            "refresh_period_ms": None,
            "idle_tab_memory_mb": None,
            "hitches_at_120hz": None,
            "engine_ascii_mib_s": None,
            "engine_mixed_mib_s": None,
            "end_to_end_ratio_to_ghostty": None,
            "benchmark_regression_percent": None,
            "checklist": manual_checks(),
        }
        manual_path.write_text(json.dumps(manual, indent=2) + "\n")
    (directory / "run.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Evidence captured. Complete {manual_path} using docs/SPIKE.md and docs/PERF.md; then run verify.")


def verify(directory):
    report = json.loads((directory / "run.json").read_text())
    manual = json.loads((directory / "manual.json").read_text())
    failures = []
    def require(condition, reason):
        if not condition:
            failures.append(reason)
    require(report.get("commit") == output(["git", "rev-parse", "HEAD"]), "Evidence belongs to a different commit")
    require(not report.get("dirty") and not output(["git", "status", "--porcelain"]), "Evidence must identify a clean committed tree")
    require(manual.get("real_hardware") is True, "Real display/GPU evidence is required")
    for name in ("tests", "render", "throughput"):
        check = report.get("checks", {}).get(name, {})
        log_path = directory / check.get("log", name + ".log")
        require(check.get("exit") == 0 and log_path.is_file(), f"{name} did not pass or its log is missing")
        if name in ("tests", "render") and log_path.is_file():
            log = log_path.read_text()
            require(bool(re.search(r"Test run with [1-9][0-9]* tests? .* passed", log)),
                    f"{name} has no completed test summary")
            if name == "render":
                require('Test theColourScreenWithTheGlowOn() passed' in log
                        and 'Test screensMatchGoldens(_:) passed' in log,
                        "Render comparisons were skipped or incomplete")
    require(set(report.get("goldens", {})) == set(GOLDENS) and manual.get("goldens_reviewed") is True,
            "All six PNG baselines need review and a passing comparison")
    fixtures = ROOT / "Packages/DeathRaceKit/Tests/Fixtures/render"
    for name in GOLDENS:
        path = fixtures / (name + ".png")
        require(path.is_file() and report.get("goldens", {}).get(name)
                == hashlib.sha256(path.read_bytes()).hexdigest(), f"Golden changed or is missing: {name}")
    require(manual.get("privacy_verdict") == "spawned-daemon-inherits-app-before-and-after-quit",
            "Record the privacy verdict; a failed verdict requires changing the daemon default/design")
    privacy = manual.get("privacy_reports", [])
    require(bool(privacy) and all((directory / p).is_file() for p in privacy), "Privacy reports are missing")
    for key, maximum in (("idle_wakeups_per_second", .5), ("idle_frames", 0), ("hidden_frames", 0),
                         ("idle_tab_memory_mb", 50), ("hitches_at_120hz", 0), ("end_to_end_ratio_to_ghostty", 1.5)):
        value = manual.get(key)
        require(isinstance(value, (int, float)) and 0 <= value <= maximum, f"{key} is missing or exceeds its budget")
    latency, refresh = manual.get("key_to_screen_p95_ms"), manual.get("refresh_period_ms")
    require(isinstance(latency, (int, float)) and isinstance(refresh, (int, float))
            and math.isfinite(latency) and math.isfinite(refresh)
            and refresh > 0 and 0 <= latency <= refresh + 3, "Key latency is missing or exceeds refresh period + 3 ms")
    require("Apple M5" in report.get("processor", ""), "Absolute throughput acceptance needs the target Apple M5")
    for key, minimum in (("engine_ascii_mib_s", 300), ("engine_mixed_mib_s", 100)):
        value = manual.get(key)
        require(isinstance(value, (int, float)) and math.isfinite(value) and value >= minimum,
                f"{key} is missing or below its target budget")
    regression = manual.get("benchmark_regression_percent")
    require(isinstance(regression, (int, float)) and math.isfinite(regression) and -100 < regression <= 10,
            "Matched repeated benchmark regression evidence is missing or exceeds 10%")
    checklist = manual.get("checklist", {})
    expected = manual_checks()
    require(bool(expected) and set(checklist) == set(expected), "Manual checklist entries are missing or stale")
    for key, item in expected.items():
        require(checklist.get(key, {}).get("check") == item["check"], f"Checklist label changed: {key}")
    for item in checklist.values():
        require(item.get("status") == "passed" and bool(item.get("evidence")), f"Unverified: {item.get('check')}")
    if failures:
        print("Acceptance remains open:\n" + "\n".join("- " + failure for failure in failures))
        raise SystemExit(1)
    print("Mac acceptance passed for " + report["commit"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("run", "verify"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/mac-acceptance")
    args = parser.parse_args()
    {"run": run, "verify": verify}[args.action](args.output.resolve())
