# Sourced by scripts: picks the simulators to build and test on.

# An iPhone simulator's UDID: a Pro, not a Max or a foldable, on the newest runtime that has one.
iphone_simulator() {
    xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS" in r), key=lambda r: [int(x) for x in r.split("iOS-")[-1].split("-")])
phones = [d for runtime in reversed(runtimes) for d in devices[runtime] if d["name"].startswith("iPhone")]
phones.sort(key=lambda d: ("Pro" not in d["name"], "Max" in d["name"], "Duo" in d["name"]))
if phones:
    print(phones[0]["udid"])
'
}

# An iPad simulator's UDID, preferring the 13-inch iPad Pro.
ipad_simulator() {
    xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS" in r), key=lambda r: [int(x) for x in r.split("iOS-")[-1].split("-")])
pads = [d for runtime in reversed(runtimes) for d in devices[runtime] if d["name"].startswith("iPad")]
pads.sort(key=lambda d: ("Pro 13" not in d["name"], "Pro" not in d["name"]))
if pads:
    print(pads[0]["udid"])
'
}
