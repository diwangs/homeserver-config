#!/usr/bin/env python3
"""Offline tests for the nightly dump script, with mocked docker and mountpoint.

Run from the repo root: python3 -m unittest discover -s roles/tenant/seafile/tests
The script under test is files/nixos/seafile-db-dump.sh, byte for byte what
configuration.nix wraps with writeShellApplication; its inputs are the
SEAFILE_BACKUP_DIR / SEAFILE_BACKUP_KEEP environment variables set on the unit.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "files/nixos/seafile-db-dump.sh"


class DumpScript(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.dest = root / "backup"
        self.dest.mkdir()
        self.bin = root / "bin"
        self.bin.mkdir()
        self.mock("mountpoint", '[ "${MOCK_MOUNTED:-1}" = 1 ]')
        self.mock(
            "docker",
            # Record the call so the test can check the dump runs inside the container
            # and that no credential is passed on the host command line.
            'echo "$@" >> "$MOCK_DOCKER_LOG"\n'
            'case "${MOCK_DOCKER:-ok}" in\n'
            '  ok) echo "-- dump body"; echo "-- Dump completed on 2026-01-01" ;;\n'
            "  fail) exit 1 ;;\n"
            '  failpartial) echo "-- dump body"; exit 1 ;;\n'
            '  truncated) echo "-- dump body" ;;\n'
            "esac",
        )
        self.docker_log = root / "docker.log"

    def mock(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    def run_script(self, **env):
        e = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "SEAFILE_BACKUP_DIR": str(self.dest),
            "MOCK_DOCKER_LOG": str(self.docker_log),
            **env,
        }
        # writeShellApplication runs the text under bash with `set -euo pipefail`.
        return subprocess.run([shutil.which("bash"), str(SCRIPT)], env=e, capture_output=True, text=True)

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

    def test_dump_runs_inside_the_db_container_without_host_credentials(self):
        self.assertEqual(self.run_script().returncode, 0)
        call = self.docker_log.read_text()
        self.assertTrue(call.startswith("exec seafile-mysql sh -c"), call)
        self.assertIn("--single-transaction --databases ccnet_db seafile_db seahub_db", call)
        # The password is read from the container's own environment, never expanded here.
        self.assertIn('MYSQL_PWD="$MYSQL_ROOT_PASSWORD"', call)

    def test_retention_is_configurable(self):
        self.seed_old(14)
        self.assertEqual(self.run_script(SEAFILE_BACKUP_KEEP="3").returncode, 0)
        self.assertEqual(len(self.listing()), 3)

    def test_failed_dump_publishes_nothing_and_keeps_old_backups(self):
        for mode in ("fail", "failpartial", "truncated"):
            with self.subTest(mode=mode):
                old = self.seed_old(14)
                r = self.run_script(MOCK_DOCKER=mode)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.listing(), old)  # nothing added, pruned, or left as temp
                for f in old:
                    (self.dest / f).unlink()

    def test_corrupt_gzip_is_not_published(self):
        # A gzip that fails its integrity test must never replace good backups.
        shutil.copy(shutil.which("gzip"), self.bin / "real-gzip")
        self.mock("gzip", 'case "$1" in -t) exit 1 ;; *) exec "$(dirname "$0")/real-gzip" "$@" ;; esac')
        old = self.seed_old(14)
        r = self.run_script()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.listing(), old)

    def test_missing_mount_refuses_without_touching_anything(self):
        r = self.run_script(MOCK_MOUNTED="0")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not mounted", r.stderr)
        self.assertEqual(self.listing(), [])
        self.assertFalse(self.docker_log.exists())  # never reached the database

    def test_backup_dir_is_required(self):
        e = {k: v for k, v in os.environ.items() if k != "SEAFILE_BACKUP_DIR"}
        r = subprocess.run([shutil.which("bash"), str(SCRIPT)], env=e, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
