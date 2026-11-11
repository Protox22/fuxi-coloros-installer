#!/usr/bin/env python3
"""Stand-in sgdisk for prepare-super.sh. It never touches a real disk."""
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["FUXI_GPT_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
with Path(os.environ["FUXI_GPT_LOG"]).open("a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\n")


def parts():
    return {key: value for key, value in state.items() if key.isdigit()}


def save():
    state_path.write_text(json.dumps(state), encoding="utf-8")


if not args:
    sys.exit(2)

if args[0] == "--print":
    print("Disk marker: synthetic")
    print("Sector size (logical/physical): 4096/4096 bytes")
    print("Number Start (sector) End (sector) Size Code Name")
    for key in sorted(parts(), key=int):
        part = parts()[key]
        print(f"{key} {part['first']} {part['last']} 1.0 GiB FFFF {part['name']}")
    sys.exit(0)

if args[0].startswith("--info="):
    part = state[args[0].split("=", 1)[1]]
    print("Partition GUID code: " + part["type"] + " (Unknown)")
    print("Partition unique GUID: " + part["guid"])
    print("First sector: " + str(part["first"]) + " (at 0 B)")
    print("Last sector: " + str(part["last"]) + " (at 0 B)")
    print("Attribute flags: " + part.get("attrs", "0000000000000000"))
    print("Partition name: '" + part["name"] + "'")
    sys.exit(0)

if args[0] == "--verify":
    ranges = sorted((part["first"], part["last"]) for part in parts().values())
    overlap = any(left[1] >= right[0] for left, right in zip(ranges, ranges[1:]))
    if state.get("case") == "bad-gpt" or overlap:
        print("Identified 1 problems!")
    else:
        print("No problems found. 0 free sectors available.")
    sys.exit(0)

if args[0].startswith("--backup="):
    target = Path(args[0].split("=", 1)[1])
    if state.get("case") == "current-backup-failed" and target.name == "current.bin":
        sys.exit(0)
    snapshot = {"disk_guid": state.get("disk_guid", "TEST-DISK"), "partitions": parts()}
    target.write_text(json.dumps(snapshot, sort_keys=True), encoding="utf-8")
    sys.exit(0)

if args[0].startswith("--load-backup="):
    snapshot = json.loads(Path(args[0].split("=", 1)[1]).read_text(encoding="utf-8"))
    for key in list(parts()):
        del state[key]
    for key, value in snapshot["partitions"].items():
        state[key] = value
    state["disk_guid"] = snapshot.get("disk_guid", state.get("disk_guid"))
    save()
    sys.exit(0)

if any(item.startswith("--delete=") for item in args):
    if args[0] != "--set-alignment=1":
        print("alignment required", file=sys.stderr)
        sys.exit(1)
    numbers = [int(item.split("=", 1)[1]) for item in args if item.startswith("--delete=")]
    if [state[str(number)]["name"] for number in numbers] != ["super", "userdata"]:
        print("refusing to delete an unexpected entry", file=sys.stderr)
        sys.exit(1)
    for number in numbers:
        part = state[str(number)]
        guid = part["guid"].upper()
        ptype = part["type"].upper()
        if f"--partition-guid={number}:{guid}" not in args:
            print("unique GUID was not preserved", file=sys.stderr)
            sys.exit(1)
        if f"--typecode={number}:{ptype}" not in args:
            print("type GUID was not preserved", file=sys.stderr)
            sys.exit(1)
        if f"--change-name={number}:{part['name']}" not in args:
            print("partition name was not preserved", file=sys.stderr)
            sys.exit(1)
        spec = next(item for item in args if item.startswith(f"--new={number}:"))
        _, first, last = spec.split(":")
        part["first"] = int(first)
        part["last"] = int(last)
        part["guid"] = guid
        part["type"] = ptype
    if state.get("case") == "wrong-result":
        state[str(numbers[0])]["last"] -= 1
    if state.get("case") == "touched-other":
        state["30"]["last"] -= 1
    save()
    sys.exit(0)

print("unexpected sgdisk arguments", file=sys.stderr)
sys.exit(2)
