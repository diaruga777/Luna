#!/usr/bin/env python3
"""Capture every staged screen of every Luna app and write a review guide.

Staged mode (`claudedocs/staging.md`) lets an app boot straight into a named
screen in a named state, so a screenshot pass is one `simctl launch` per
screen with no navigation script at all. This drives that:

    build (once, all four apps)
      -> boot a simulator
      -> install
      -> per app: ask it for its stage manifest (`-LunaStageList`)
      -> per stage: relaunch with `-LunaStage <id>`, screenshot
      -> write index.md grouping every capture by app -> screen -> state

Output goes to a gitignored directory (default `build/stage-screenshots/`):
the guide is only meaningful with its ~200MB of PNGs beside it, and those do
not belong in the repository. Regenerate it whenever you want to look.

    scripts/stage_screenshots.py                    # everything
    scripts/stage_screenshots.py --apps reader      # one app
    scripts/stage_screenshots.py --only 'deck\\.'    # one family of stages
    scripts/stage_screenshots.py --no-build         # reuse the built products
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# scheme, bundle id, built product name, human name — the four apps, in the
# order the guide should read.
APPS = [
    ("luna", "Luna", "com.hsanabria.luna", "Luna.app", "Luna (central)"),
    ("reader", "LunaReader", "com.hsanabria.luna.reader", "LunaReader.app", "Luna Reader"),
    ("downloader", "LunaDownloader", "com.hsanabria.luna.downloader",
     "LunaDownloader.app", "Luna Downloader"),
    ("pricetracker", "LunaPriceTracker", "com.hsanabria.luna.pricetracker",
     "LunaPriceTracker.app", "Luna Price Tracker"),
]

SIMULATOR_NAME = "LunaStageShots"
DEVICE_TYPE = "iPhone 17 Pro"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def simctl(*args, check=True):
    return subprocess.run(
        ["xcrun", "simctl", *args], check=check, capture_output=True, text=True)


def resolve_simulator(explicit):
    if explicit:
        return explicit
    listing = json.loads(simctl("list", "devices", "--json").stdout)
    for devices in listing["devices"].values():
        for device in devices:
            if device["name"] == SIMULATOR_NAME:
                return device["udid"]
    print(f"creating simulator {SIMULATOR_NAME}…")
    return simctl("create", SIMULATOR_NAME, DEVICE_TYPE, RUNTIME).stdout.strip()


def boot(udid):
    state = json.loads(simctl("list", "devices", "--json").stdout)
    booted = any(
        d["udid"] == udid and d["state"] == "Booted"
        for devices in state["devices"].values() for d in devices)
    if not booted:
        simctl("boot", udid)
    simctl("bootstatus", udid, check=False)


def build(derived_data):
    print("building AllLunaApps…")
    run([
        "xcodebuild", "build", "-scheme", "AllLunaApps",
        "-destination", "generic/platform=iOS Simulator",
        "-configuration", "Debug",
        "DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO",
        "-derivedDataPath", str(derived_data),
    ], cwd=REPO)


def manifest(udid, bundle_id):
    """Ask a running-once app for its own stage list. The app prints JSON and
    exits, so this is the enumeration point — no source is read."""
    result = subprocess.run(
        ["xcrun", "simctl", "launch", "--console-pty", udid, bundle_id, "-LunaStageList"],
        capture_output=True, text=True, timeout=180)
    text = result.stdout
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < 0:
        raise RuntimeError(f"{bundle_id} printed no manifest:\n{text}\n{result.stderr}")
    return json.loads(text[start:end + 1])


def capture(udid, bundle_id, stage_id, destination, settle, max_settle):
    """Launch a stage and screenshot it once the screen has stopped changing.

    A fixed delay does not work here: a settings list is drawn in under a
    second, while a deck stage whose centred card is a live WebKit reader takes
    the better part of ten on a cold simulator, and a too-short wait captures
    black. So: poll, and take the first frame that is byte-identical to the one
    before it.
    """
    simctl("terminate", udid, bundle_id, check=False)
    simctl("launch", udid, bundle_id, "-LunaStage", stage_id)
    time.sleep(settle)
    previous = None
    waited = settle
    while True:
        simctl("io", udid, "screenshot", "--type=png", str(destination))
        current = destination.read_bytes()
        if current == previous or waited >= max_settle:
            break
        previous = current
        time.sleep(settle)
        waited += settle
    # Shrink for the guide: a 1206x2622 device shot is ~2MB and nobody reviews
    # it at native size.
    if shutil.which("sips"):
        subprocess.run(
            ["sips", "--resampleWidth", "480", str(destination)],
            capture_output=True, check=False)


def write_guide(out_dir, captured):
    """captured: [(app_label, stage_dict, relative_png_path or None)]"""
    lines = [
        "# Luna staged screens",
        "",
        "Every screen of every app, in every state staged mode can put it in.",
        "Generated by `scripts/stage_screenshots.py`; see `claudedocs/staging.md`.",
        "",
        f"Captured {sum(1 for _, _, p in captured if p)} of {len(captured)} stages.",
        "",
        "## Contents",
        "",
    ]
    by_app = {}
    for app_label, stage, png in captured:
        by_app.setdefault(app_label, {}).setdefault(stage["screen"], []).append((stage, png))

    for app_label in by_app:
        anchor = re.sub(r"[^a-z0-9]+", "-", app_label.lower()).strip("-")
        lines.append(f"- [{app_label}](#{anchor})")
    lines.append("")

    for app_label, screens in by_app.items():
        lines += [f"## {app_label}", ""]
        for screen, entries in sorted(screens.items()):
            lines += [f"### {screen}", ""]
            for stage, png in sorted(entries, key=lambda e: e[0]["variant"]):
                lines += [
                    f"#### {stage['variant']}",
                    "",
                    stage["summary"],
                    "",
                    f"`-LunaStage {stage['id']}`",
                    "",
                ]
                if png:
                    lines += [f'<img src="{png}" width="300" alt="{stage["id"]}">', ""]
                else:
                    lines += ["> capture failed", ""]
    (out_dir / "index.md").write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apps", default="all",
                        help="comma-separated: luna,reader,downloader,pricetracker")
    parser.add_argument("--sim", default=None, help="simulator udid (default: a dedicated one)")
    parser.add_argument("--out", default=str(REPO / "build" / "stage-screenshots"))
    parser.add_argument("--derived-data", default=str(REPO / ".build-dd-stage"))
    parser.add_argument("--only", default=None, help="regex over stage ids")
    parser.add_argument("--settle", type=float, default=1.5,
                        help="seconds between successive settle polls")
    parser.add_argument("--max-settle", type=float, default=15.0,
                        help="give up waiting for the screen to settle after this")
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()

    wanted = APPS if args.apps == "all" else [
        a for a in APPS if a[0] in args.apps.split(",")]
    if not wanted:
        sys.exit(f"no apps matched {args.apps!r}")
    only = re.compile(args.only) if args.only else None

    derived_data = Path(args.derived_data)
    if not args.no_build:
        build(derived_data)
    products = derived_data / "Build" / "Products" / "Debug-iphonesimulator"

    udid = resolve_simulator(args.sim)
    print(f"simulator {udid}")
    boot(udid)

    out_dir = Path(args.out)
    shutil.rmtree(out_dir, ignore_errors=True)
    (out_dir / "shots").mkdir(parents=True)

    captured = []
    for key, _scheme, bundle_id, product, label in wanted:
        app_path = products / product
        if not app_path.exists():
            sys.exit(f"missing {app_path} — build first")
        simctl("install", udid, str(app_path))
        stages = manifest(udid, bundle_id)["stages"]
        if only:
            stages = [s for s in stages if only.search(s["id"])]
        print(f"{label}: {len(stages)} stages")
        for index, stage in enumerate(stages, 1):
            name = f"{key}-{stage['id'].replace('.', '_')}.png"
            destination = out_dir / "shots" / name
            print(f"  [{index}/{len(stages)}] {stage['id']}")
            try:
                capture(udid, bundle_id, stage["id"], destination, args.settle, args.max_settle)
                captured.append((label, stage, f"shots/{name}"))
            except subprocess.CalledProcessError as error:
                print(f"    FAILED: {error.stderr.strip()[:200]}")
                captured.append((label, stage, None))
        simctl("terminate", udid, bundle_id, check=False)

    write_guide(out_dir, captured)
    print(f"\nguide: {out_dir / 'index.md'}")


if __name__ == "__main__":
    main()
