#!/usr/bin/env python3
import json
import os
import platform
import re
import subprocess


PROCESS = re.compile(r'\("(?P<name>[^"\n]+)",pid=(?P<pid>[0-9]+),fd=[0-9]+\)')
UNIT = re.compile(r"^[A-Za-z0-9_.@\\x-]+\.service$")


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout or "command failed").strip())
    return result.stdout


def parse_processes(sockets):
    return sorted({(match.group("name"), int(match.group("pid"))) for match in PROCESS.finditer(sockets)}, key=lambda item: item[1])


def process_unit(pid, proc_root="/proc"):
    with open(os.path.join(proc_root, str(pid), "cgroup"), encoding="utf-8") as source:
        for line in source:
            path = line.rstrip().rsplit(":", 1)[-1]
            for component in reversed(path.split("/")):
                if UNIT.fullmatch(component):
                    return component
    return ""


def inspect():
    sockets = run(["ss", "-H", "-ltnp", "sport", "=", ":443"])
    occupied = bool(sockets.strip())
    processes = parse_processes(sockets)
    if occupied and not processes:
        raise RuntimeError("port 443 is occupied but listener PIDs are hidden; rerun with permission to inspect sockets")
    owners = []
    for name, pid in processes:
        cgroup_unit = process_unit(pid)
        executable = os.path.realpath(f"/proc/{pid}/exe")
        owner = {"process": name, "pid": pid, "executable": executable, "manager": "process", "unit": "", "definition": ""}
        if cgroup_unit:
            definition = run(["systemctl", "show", cgroup_unit, "--property=FragmentPath", "--value"]).strip()
            if not definition.startswith("/"):
                raise RuntimeError(f"systemd unit {cgroup_unit} has no absolute FragmentPath")
            owner.update({"manager": "systemd", "unit": cgroup_unit, "definition": definition})
        owners.append(owner)
    return {"ok": True, "occupied": occupied, "owners": owners}


def main():
    if platform.system() != "Linux":
        raise SystemExit("inspect_443.py runs on the Linux public server")
    try:
        result = inspect()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False, separators=(",", ":")))
        raise SystemExit(1)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
