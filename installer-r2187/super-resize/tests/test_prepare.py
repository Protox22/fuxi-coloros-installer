#!/usr/bin/env python3
"""Recovery-script checks with a fake sgdisk. No phone and no block device."""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "prepare-super.sh"
MOCK = Path(__file__).resolve().parent / "mock_gpt.py"
SUPER_TYPE = "89A12DE1-5E41-4CB3-8B4C-B1441EB5DA38"
USER_TYPE = "1B81E7E6-F50D-419B-A739-2AEEF8DA3335"
DISK_BYTES = "253340155904"


def geometry(kind):
    if kind == "32":
        return dict(super_n=32, user_n=33, start=854080, stock_end=3213375,
                    expanded_end=3737663, stock_user=3213376, expanded_user=3737664)
    if kind == "31":
        return dict(super_n=31, user_n=32, start=751680, stock_end=3110975,
                    expanded_end=3635263, stock_user=3110976, expanded_user=3635264)
    raise AssertionError(kind)


def layout(kind, expanded=False, lower=False):
    spec = geometry(kind)
    super_guid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    user_guid = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    super_type = SUPER_TYPE
    user_type = USER_TYPE
    if lower:
        super_guid = super_guid.lower()
        user_guid = user_guid.lower()
        super_type = super_type.lower()
        user_type = user_type.lower()
    state = {
        "case": "valid",
        "disk_guid": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
        "1": dict(name="switch", type="TEST-UNTOUCHED-TYPE",
                  guid="11111111-1111-1111-1111-111111111111", first=6, last=7),
        "30": dict(name="cust", type="TEST-UNTOUCHED-TYPE",
                   guid="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                   first=spec["start"] - 4096, last=spec["start"] - 1),
        str(spec["super_n"]): dict(
            name="super", type=super_type, guid=super_guid, first=spec["start"],
            last=spec["expanded_end"] if expanded else spec["stock_end"]),
        str(spec["user_n"]): dict(
            name="userdata", type=user_type, guid=user_guid,
            first=spec["expanded_user"] if expanded else spec["stock_user"],
            last=61850618),
    }
    return state


def patched_script(directory):
    text = SCRIPT.read_text(encoding="utf-8")
    if "\r" in text:
        raise SystemExit("prepare-super.sh must stay LF-only")
    text = text.replace("[ -b ", "[ -e ")
    path = directory / "prepare-super.sh"
    path.write_text(text, encoding="utf-8", newline="\n")
    path.chmod(0o755)
    return path


def run_case(tmp, name, kind, case, mode, expanded=False, mutate=None, lower=False, mounts=""):
    spec = geometry(kind)
    folder = tmp / name
    folder.mkdir()
    state = layout(kind, expanded=expanded, lower=lower)
    state["case"] = case
    if mutate:
        mutate(state)
    state_path = folder / "state.json"
    state_path.write_text(json.dumps(state), encoding="utf-8")
    log_path = folder / "calls.jsonl"
    log_path.write_text("", encoding="utf-8")
    disk = folder / "disk"
    disk.write_text("synthetic disk\n", encoding="utf-8")
    for number in (spec["super_n"], spec["user_n"]):
        (folder / f"disk{number}").write_text("node\n", encoding="utf-8")
    by_name = folder / "by-name"
    boot_name = folder / "boot-name"
    by_name.mkdir()
    boot_name.mkdir()
    if case != "no-aliases":
        for directory in (by_name, boot_name):
            (directory / "super").write_text("alias\n", encoding="utf-8")
            (directory / "userdata").write_text("alias\n", encoding="utf-8")
    sector = folder / "sector"
    sector.write_text("4096\n", encoding="utf-8")
    mount_file = folder / "mounts"
    mount_file.write_text(mounts, encoding="utf-8")
    backup = folder / "backup.bin"
    script = patched_script(folder)
    runner = folder / "runner.sh"
    runner.write_text(r"""#!/usr/bin/env bash
set -eu
export FUXI_SLEEP=0
getprop() {
    case "${FUXI_GPT_CASE:-}" in
        wrong-device) [ "$1" = ro.product.device ] && { echo nuwa; return; } ;;
        android) [ "$1" = sys.boot_completed ] && { echo 1; return; } ;;
    esac
    case "$1" in
        ro.product.device) echo fuxi ;;
        ro.twrp.version) echo 3.7.0 ;;
        ro.boot.mode) echo recovery ;;
    esac
}
blockdev() {
    [ "$1" = --rereadpt ] && return 0
    [ "$1" = --getsize64 ]
    if [ "$2" = "$FUXI_GPT_DISK" ]; then echo "$FUXI_GPT_BYTES"; return; fi
    echo 11811160064
}
readlink() {
    local path="${*: -1}"
    case "$path" in
        */super) echo "${FUXI_GPT_DISK}${FUXI_SUPER_N}" ;;
        */userdata) echo "${FUXI_GPT_DISK}${FUXI_USER_N}" ;;
        *) echo "$path" ;;
    esac
}
stat() {
    local path="${*: -1}"
    if [ "${FUXI_GPT_CASE:-}" = alias-conflict ] && [[ "$path" == */super ]]; then
        echo 9:9
        return
    fi
    case "$path" in
        "${FUXI_GPT_DISK}${FUXI_SUPER_N}"|*/super) echo 8:20 ;;
        "${FUXI_GPT_DISK}${FUXI_USER_N}"|*/userdata) echo 8:21 ;;
        *) return 1 ;;
    esac
}
umount() { [ "${FUXI_GPT_CASE:-}" != busy ] || return 1; : > "$FUXI_GPT_MOUNTS"; }
sync() { :; }
# The sourced recovery script exits the runner with its own status.
source "$FUXI_GPT_SCRIPT" "$1"
""", encoding="utf-8", newline="\n")
    runner.chmod(0o755)
    env = os.environ.copy()
    env.update(
        FUXI_GPT_STATE=str(state_path),
        FUXI_GPT_LOG=str(log_path),
        FUXI_GPT_CASE=case,
        FUXI_GPT_DISK=str(disk),
        FUXI_GPT_SCRIPT=str(script),
        FUXI_GPT_SGDISK=str(MOCK),
        FUXI_GPT_BACKUP=str(backup),
        FUXI_GPT_CURRENT=str(folder / "current.bin"),
        FUXI_GPT_BY_NAME=str(by_name),
        FUXI_GPT_BOOT_NAME=str(boot_name),
        FUXI_GPT_SECTOR=str(sector),
        FUXI_GPT_MOUNTS=str(mount_file),
        FUXI_GPT_RESTORE=str(folder / "restore.bin"),
        FUXI_GPT_BYTES=DISK_BYTES,
        FUXI_SUPER_N=str(spec["super_n"]),
        FUXI_USER_N=str(spec["user_n"]),
        FUXI_SLEEP="0",
    )
    audit = subprocess.run(["bash", str(runner), "audit"], env=env, capture_output=True, text=True, timeout=30)
    if mode == "audit":
        return audit, state_path, log_path, backup, spec
    if audit.returncode != 0:
        return audit, state_path, log_path, backup, spec
    env["FUXI_BACKUP_SHA256"] = hashlib.sha256(backup.read_bytes()).hexdigest()
    env["FUXI_CONFIRM"] = "RESTORE_STOCK_SUPER" if mode == "restore" else "LOAD_GPT_BACKUP" if mode == "load-backup" else "ERASE_AND_RESIZE"
    if case == "missing-confirm":
        env.pop("FUXI_CONFIRM", None)
    if mode == "load-backup":
        shutil.copyfile(backup, folder / "restore.bin")
    log_path.write_text("", encoding="utf-8")
    result = subprocess.run(["bash", str(runner), mode], env=env, capture_output=True, text=True, timeout=30)
    (folder / "output.txt").write_text(audit.stdout + audit.stderr + result.stdout + result.stderr, encoding="utf-8")
    return result, state_path, log_path, backup, spec


def calls(log_path):
    if not log_path.read_text(encoding="utf-8").strip():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]


def deletes(log_path):
    return [item for item in calls(log_path) if any(arg.startswith("--delete=") for arg in item)]


def check_windows_sources():
    script = (ROOT / "resize.ps1").read_bytes()
    if not script.startswith(b"\xef\xbb\xbf"):
        raise SystemExit("resize.ps1 must start with a UTF-8 BOM for Windows PowerShell 5.1")
    text = script.decode("utf-8-sig")
    bat = (ROOT / "RESIZE.bat").read_text(encoding="utf-8")
    problems = []
    if "Devine Machinery" not in text or "Devine Machinery" not in bat:
        problems.append("missing authorship")
    if "&&" in text or "??" in text:
        problems.append("PowerShell 7-only operator")
    if ".Replace(\"`r\", '')" not in text:
        problems.append("CR is not stripped before adb push")
    if "@('a', 'b')" not in text or "recovery_" not in text:
        problems.append("both slots are not flashed")
    if text.count("{") != text.count("}") or text.count("(") != text.count(")"):
        problems.append("unbalanced brackets")
    for line in text.splitlines():
        if "Join-Path" in line and line.count(",") >= 2:
            problems.append("Join-Path has more than two arguments: " + line.strip())
    if problems:
        raise SystemExit("resize.ps1: " + "; ".join(problems))


def main():
    check_windows_sources()
    MOCK.chmod(0o755)
    failures = []
    with tempfile.TemporaryDirectory(prefix="fuxi-resize-") as raw:
        tmp = Path(raw)
        checks = []

        def expect(name, ok, detail):
            checks.append((name, ok))
            print(("PASS " if ok else "FAIL ") + name + ("" if ok else " " + detail))
            if not ok:
                failures.append(name)

        for kind in ("32", "31"):
            result, state_path, log_path, _backup, spec = run_case(
                tmp, f"expand-{kind}", kind, "valid", "apply")
            final = json.loads(state_path.read_text(encoding="utf-8"))
            super_part = final[str(spec["super_n"])]
            user_part = final[str(spec["user_n"])]
            ok = result.returncode == 0 and "FUXI_RESULT=applied" in result.stdout
            ok = ok and super_part["first"] == spec["start"] and super_part["last"] == spec["expanded_end"]
            ok = ok and user_part["first"] == spec["expanded_user"] and user_part["last"] == 61850618
            ok = ok and super_part["guid"].endswith("AAAAAAAAAAAA") and user_part["guid"].endswith("BBBBBBBBBBBB")
            ok = ok and final["30"]["last"] == spec["start"] - 1 and final["1"]["last"] == 7
            ok = ok and len(deletes(log_path)) == 1
            ok = ok and not any(item[0].startswith("--load-backup=") for item in calls(log_path))
            expect(f"expand {kind}/ {kind}", ok, (result.stdout + result.stderr)[-500:])

            result, state_path, log_path, _backup, spec = run_case(
                tmp, f"restore-{kind}", kind, "valid", "restore", expanded=True)
            final = json.loads(state_path.read_text(encoding="utf-8"))
            ok = result.returncode == 0 and "FUXI_RESULT=restored" in result.stdout
            ok = ok and final[str(spec["super_n"])]["last"] == spec["stock_end"]
            ok = ok and final[str(spec["user_n"])]["first"] == spec["stock_user"]
            ok = ok and final[str(spec["user_n"])]["last"] == 61850618
            ok = ok and final["30"] == layout(kind)["30"]
            expect(f"restore {kind}", ok, (result.stdout + result.stderr)[-500:])

        result, state_path, log_path, _backup, _spec = run_case(
            tmp, "already", "32", "valid", "apply", expanded=True)
        ok = result.returncode == 0 and "FUXI_RESULT=unchanged" in result.stdout and not deletes(log_path)
        expect("already expanded writes nothing", ok, result.stderr[-300:])

        result, _state_path, log_path, _backup, _spec = run_case(
            tmp, "lower", "32", "valid", "apply", lower=True)
        final = json.loads((tmp / "lower" / "state.json").read_text(encoding="utf-8"))
        ok = result.returncode == 0 and final["32"]["guid"] == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        ok = ok and final["32"]["type"] == SUPER_TYPE
        expect("lowercase GUIDs are normalized", ok, result.stderr[-300:])

        result, state_path, log_path, _backup, spec = run_case(
            tmp, "wrong-result", "32", "wrong-result", "apply")
        final = json.loads(state_path.read_text(encoding="utf-8"))
        original = layout("32")
        ok = result.returncode != 0 and "FUXI_RESULT=rollback" in result.stderr
        ok = ok and final["32"]["last"] == original["32"]["last"]
        ok = ok and final["33"]["first"] == original["33"]["first"]
        ok = ok and any(item[0].startswith("--load-backup=") for item in calls(log_path))
        expect("bad sgdisk result rolls back", ok, (result.stdout + result.stderr)[-600:])

        result, state_path, log_path, _backup, _spec = run_case(
            tmp, "touched", "32", "touched-other", "apply")
        final = json.loads(state_path.read_text(encoding="utf-8"))
        ok = result.returncode != 0 and final["30"]["last"] == layout("32")["30"]["last"]
        ok = ok and final["32"]["last"] == layout("32")["32"]["last"]
        expect("unrelated partition change rolls back", ok, result.stderr[-400:])

        result, state_path, log_path, _backup, _spec = run_case(
            tmp, "busy", "32", "busy", "apply", mounts="/dev/block/sda30 /cache ext4 rw 0 0\n")
        final = json.loads(state_path.read_text(encoding="utf-8"))
        ok = result.returncode != 0 and not deletes(log_path)
        ok = ok and final["32"]["last"] == layout("32")["32"]["last"]
        expect("busy mount does not write GPT", ok, result.stderr[-300:])

        result, _state, log_path, _backup, _spec = run_case(
            tmp, "confirm", "32", "missing-confirm", "apply")
        ok = result.returncode != 0 and not deletes(log_path)
        expect("missing confirmation does not write", ok, result.stderr[-300:])

        result, _state, log_path, _backup, _spec = run_case(
            tmp, "device", "31", "wrong-device", "audit")
        ok = result.returncode != 0 and not calls(log_path)
        expect("non-fuxi is refused", ok, result.stderr[-200:])

        result, _state, log_path, _backup, _spec = run_case(
            tmp, "android", "32", "android", "audit")
        ok = result.returncode != 0 and not calls(log_path)
        expect("booted Android is refused", ok, result.stderr[-200:])

        base = run_case(tmp, "stale-base", "32", "valid", "audit")
        audit, state_path, log_path, backup, _spec = base
        state = json.loads(state_path.read_text(encoding="utf-8"))
        state["30"]["guid"] = "00000000-0000-0000-0000-000000000001"
        state_path.write_text(json.dumps(state), encoding="utf-8")
        env = os.environ.copy()
        # Use the same runner by invoking run_case's files through a second apply is hard.
        # Call bash with the environment reconstructed from the audit folder.
        audit_folder = tmp / "stale-base"
        script = patched_script(audit_folder)
        env.update(
            FUXI_GPT_STATE=str(state_path), FUXI_GPT_LOG=str(log_path), FUXI_GPT_CASE="valid",
            FUXI_GPT_DISK=str(audit_folder / "disk"), FUXI_GPT_SCRIPT=str(script),
            FUXI_GPT_SGDISK=str(MOCK), FUXI_GPT_BACKUP=str(backup),
            FUXI_GPT_CURRENT=str(audit_folder / "current.bin"),
            FUXI_GPT_BY_NAME=str(audit_folder / "by-name"),
            FUXI_GPT_BOOT_NAME=str(audit_folder / "boot-name"),
            FUXI_GPT_SECTOR=str(audit_folder / "sector"),
            FUXI_GPT_MOUNTS=str(audit_folder / "mounts"),
            FUXI_GPT_BYTES=DISK_BYTES, FUXI_SUPER_N="32", FUXI_USER_N="33", FUXI_SLEEP="0",
            FUXI_BACKUP_SHA256=hashlib.sha256(backup.read_bytes()).hexdigest(),
            FUXI_CONFIRM="ERASE_AND_RESIZE",
        )
        log_path.write_text("", encoding="utf-8")
        stale_run = subprocess.run(["bash", str(audit_folder / "runner.sh"), "apply"],
                                   env=env, capture_output=True, text=True, timeout=30)
        ok = audit.returncode == 0 and stale_run.returncode != 0 and not deletes(log_path)
        expect("GPT change between audit and apply is refused", ok, stale_run.stderr[-300:])

        result, state_path, log_path, backup, spec = run_case(
            tmp, "rescue", "31", "valid", "load-backup")
        state = json.loads(state_path.read_text(encoding="utf-8"))
        state["31"]["last"] = 1
        state_path.write_text(json.dumps(state), encoding="utf-8")
        # The run_case already executed load-backup before this corruption.
        # Do an explicit second load from the saved backup.
        folder = tmp / "rescue"
        env = os.environ.copy()
        env.update(
            FUXI_GPT_STATE=str(state_path), FUXI_GPT_LOG=str(log_path), FUXI_GPT_CASE="valid",
            FUXI_GPT_DISK=str(folder / "disk"), FUXI_GPT_SCRIPT=str(patched_script(folder)),
            FUXI_GPT_SGDISK=str(MOCK), FUXI_GPT_BACKUP=str(backup),
            FUXI_GPT_CURRENT=str(folder / "current.bin"),
            FUXI_GPT_BY_NAME=str(folder / "by-name"), FUXI_GPT_BOOT_NAME=str(folder / "boot-name"),
            FUXI_GPT_SECTOR=str(folder / "sector"), FUXI_GPT_MOUNTS=str(folder / "mounts"),
            FUXI_GPT_RESTORE=str(folder / "restore.bin"), FUXI_GPT_BYTES=DISK_BYTES,
            FUXI_SUPER_N="31", FUXI_USER_N="32", FUXI_SLEEP="0",
            FUXI_BACKUP_SHA256=hashlib.sha256((folder / "restore.bin").read_bytes()).hexdigest(),
            FUXI_CONFIRM="LOAD_GPT_BACKUP",
        )
        log_path.write_text("", encoding="utf-8")
        rescue = subprocess.run(["bash", str(folder / "runner.sh"), "load-backup"],
                                env=env, capture_output=True, text=True, timeout=30)
        final = json.loads(state_path.read_text(encoding="utf-8"))
        ok = rescue.returncode == 0 and "FUXI_RESULT=backup-loaded" in rescue.stdout
        ok = ok and final["31"]["last"] == geometry("31")["stock_end"]
        expect("computer backup can be loaded", ok, rescue.stderr[-400:])

        result, _state, _log, _backup, _spec = run_case(tmp, "verify-ok", "32", "valid", "verify", expanded=True)
        ok = result.returncode == 0 and "FUXI_RESULT=verified" in result.stdout
        expect("verify accepts 11 GiB", ok, result.stderr[-200:])

        result, _state, _log, _backup, _spec = run_case(tmp, "verify-no", "32", "valid", "verify")
        ok = result.returncode != 0
        expect("verify rejects 9 GiB", ok, result.stdout[-200:])

        def overlap(state):
            state["30"]["last"] = state["32"]["first"] + 10
        result, _state, log_path, _backup, _spec = run_case(
            tmp, "overlap", "32", "valid", "audit", mutate=overlap)
        ok = result.returncode != 0 and not deletes(log_path)
        expect("overlapping partition is refused", ok, result.stderr[-250:])

        result, _state, log_path, _backup, _spec = run_case(
            tmp, "aliases", "31", "no-aliases", "apply")
        ok = result.returncode == 0 and "FUXI_RESULT=applied" in result.stdout
        expect("missing by-name links still work", ok, result.stderr[-250:])

        result, _state, log_path, _backup, _spec = run_case(
            tmp, "conflict", "32", "alias-conflict", "audit")
        ok = result.returncode != 0
        expect("conflicting super alias is refused", ok, result.stderr[-250:])

        crlf = tmp / "crlf.sh"
        crlf.write_bytes(SCRIPT.read_bytes().replace(b"\n", b"\r\n"))
        crlf_run = subprocess.run(["bash", str(crlf), "audit"], capture_output=True, text=True, timeout=30)
        expect("CRLF script is not executed as success", crlf_run.returncode != 0, "exit 0")

    if failures:
        print(f"{len(failures)} failed")
        return 1
    print(f"PASS {len(checks)} prepare-super scenarios")
    return 0


if __name__ == "__main__":
    sys.exit(main())
