#!/usr/bin/env python3
"""Print "<devicectl identifier>\t<hardware udid>" for the device in $DEVICE.

devicectl and xcodebuild identify the same phone differently. devicectl takes
its own identifier; xcodebuild's `-destination platform=iOS,id=…` takes the
hardware UDID. Accept either and print both, so scripts can use each tool with
the identifier it wants. Prints two empty fields when the device is absent.
"""
import json
import os
import sys

want = os.environ.get("DEVICE", "")
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    print("\t")
    raise SystemExit(0)

for device in devices:
    udid = device.get("hardwareProperties", {}).get("udid", "")
    if want in (device.get("identifier", ""), udid):
        print(f"{device.get('identifier', '')}\t{udid}")
        break
else:
    print("\t")
