#!/usr/bin/env python3
"""Offline tests for the nightly dump script, with mocked docker and mountpoint.

Run from the repo root: python3 -m unittest discover -s roles/tenant/seafile/tests
The script is taken from tasks/backup.yml and its one Jinja variable substituted.
"""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROLE = Path(__file__).resolve().parents[1]


def render(dest):
    tasks = yaml.safe_load((ROLE / "tasks/backup.yml").read_text())
    script = next(t for t in tasks if "dump script" in t["name"])["ansible.builtin.copy"]["content"]
    script = script.replace("{{ seafile_backup_dir }}", str(dest))
    assert "{{" not in script
    return script


class DumpScript(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.dest = root / "backup"
        self.dest.mkdir()
        self.bin = root / "bin"
        self.bin.mkdir()
        self.script = root / "dump.sh"
        self.script.write_text(render(self.dest))
        self.script.chmod(0o750)
        self.mock("mountpoint", '[ "${MOCK_MOUNTED:-1}" = 1 ]')
        self.mock(
            "docker",
            'case "${MOCK_DOCKER:-ok}" in\n'
            '  ok) echo "-- dump body"; echo "-- Dump completed on 2026-01-01" ;;\n'
            '  fail) exit 1 ;;\n'
            '  failpartial) echo "-- dump body"; exit 1 ;;\n'
            '  truncated) echo "-- dump body" ;;\n'
            "esac",
        )

    def mock(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    def run_script(self, **env):
        e = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", **env}
        return subprocess.run(["sh", str(self.script)], env=e, capture_output=True, text=True)

    def listing(self):
        return sorted(p.name for p in self.dest.iterdir())

    def seed_old(self, n=14):
        for i in range(n):
            f = self.dest / f"seafile-db-2020010{i // 10}-0000{i % 10:02d}.sql.gz"
            f.write_text("old")
            os.utime(f, (1_000_000 + i, 1_000_000 + i))
        return self.listing()

    def test_success_publishes_valid_gzip_and_prunes(self):
        old = self.seed_old(14)
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        names = self.listing()
        self.assertEqual(len(names), 14)
        new = [n for n in names if n not in old]
        self.assertEqual(len(new), 1)
        self.assertNotIn(old[0], names)  # oldest pruned
        self.assertEqual(subprocess.run(["gzip", "-t", str(self.dest / new[0])]).returncode, 0)
        out = subprocess.run(["gzip", "-dc", str(self.dest / new[0])], capture_output=True, text=True).stdout
        self.assertIn("Dump completed", out)
        self.assertEqual(stat.S_IMODE((self.dest / new[0]).stat().st_mode), 0o640)

    def test_failed_dump_publishes_nothing_and_keeps_old_backups(self):
        for mode in ("fail", "failpartial", "truncated"):
            with self.subTest(mode=mode):
                old = self.seed_old(14)
                r = self.run_script(MOCK_DOCKER=mode)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.listing(), old)  # nothing added, pruned, or left as temp
                for f in old:
                    (self.dest / f).unlink()

    def test_missing_mount_refuses_without_touching_anything(self):
        r = self.run_script(MOCK_MOUNTED="0")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not mounted", r.stderr)
        self.assertEqual(self.listing(), [])


if __name__ == "__main__":
    unittest.main()
