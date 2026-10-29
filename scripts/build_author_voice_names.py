#!/usr/bin/env python3
"""Build the offline narration lookup from SSA names.zip or merged SSA records.

Input records: name,sex,count (year from yobYYYY.txt), or name,sex,count,year.
SSA national data: https://www.ssa.gov/oact/babynames/names.zip (CC0).
Usage: python3 scripts/build_author_voice_names.py /path/to/names.zip
No download or inference runs during an app build.
"""
import argparse
from collections import defaultdict
import hashlib
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
args = parser.parse_args()
counts = defaultdict(lambda: [0, 0])
years = set()

def consume(lines, year=None):
    for line in lines:
        parts = line.strip().split(",")
        if len(parts) < 3:
            continue
        name, sex, count = parts[:3]
        if sex not in ("F", "M") or not name.isalpha():
            continue
        counts[name.lower()][sex == "M"] += int(count)
        years.add(year if year is not None else int(parts[3]))

if zipfile.is_zipfile(args.source):
    with zipfile.ZipFile(args.source) as archive:
        for entry in archive.namelist():
            if entry.startswith("yob") and entry.endswith(".txt"):
                consume(archive.read(entry).decode("utf-8-sig").splitlines(), int(entry[3:7]))
else:
    consume(args.source.read_text(encoding="utf-8-sig").splitlines())

lines = [
    "# SSA national given-name counts; CC0; https://www.ssa.gov/oact/babynames/names.zip",
    f"# Years: {min(years)}-{max(years)}; input SHA256: {hashlib.sha256(args.source.read_bytes()).hexdigest()}",
    "# At least 1000 occurrences; >=95% one recorded sex; U = ambiguous. Name association only.",
]
for name, (female, male) in sorted(counts.items()):
    total = female + male
    if total >= 1000:
        label = "F" if female / total >= 0.95 else "M" if male / total >= 0.95 else "U"
        lines.append(f"{name},{label}")
output = Path(__file__).resolve().parents[1] / "LunaLibraries/Sources/LunaAudioPlayback/Resources/AuthorVoiceNames.txt"
output.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Wrote {len(lines) - 3} names ({output.stat().st_size} bytes), {min(years)}-{max(years)}")
