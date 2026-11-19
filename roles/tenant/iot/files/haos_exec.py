#!/usr/bin/env python3
"""Run a shell script inside the HAOS VM through the QEMU guest agent (playbooks/migrate_iot.yml).

    haos_exec.py VMID [--b64-out FILE] < script.sh

The script comes on stdin (so it needs no quoting through Ansible, the host shell and
the guest shell). Prints the guest's stdout, or with --b64-out decodes it as base64 into
FILE (mode 0600) and prints nothing, so state that holds the Zigbee network key never
reaches a terminal or an Ansible log. Exits with the guest script's exit code.
"""
import base64
import json
import os
import subprocess
import sys


def main():
    vmid = sys.argv[1]
    out = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--b64-out" else None
    script = sys.stdin.read()
    r = subprocess.run(
        ["qm", "guest", "exec", vmid, "--timeout", "300", "--", "sh", "-c", script],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 and not r.stdout.strip():
        sys.stderr.write(r.stderr)
        return r.returncode or 1
    res = json.loads(r.stdout)
    if res.get("out-truncated"):
        sys.stderr.write("guest output truncated\n")
        return 1
    sys.stderr.write(res.get("err-data", ""))
    data = res.get("out-data", "")
    if out:
        if not data.strip():
            sys.stderr.write("guest produced no output\n")
            return 1
        os.umask(0o077)
        with open(out, "wb") as f:
            f.write(base64.b64decode(data))
    else:
        sys.stdout.write(data)
    return int(res.get("exitcode", 1))


if __name__ == "__main__":
    sys.exit(main())
