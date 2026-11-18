#!/usr/bin/env bash
# Nightly logical dump of the Seafile databases. Wrapped by configuration.nix with
# writeShellApplication (shellcheck + `set -euo pipefail` + a fixed PATH); the offline
# test in tests/test_db_dump.py runs this same file with mocked docker/mountpoint.
set -euo pipefail

dest=${SEAFILE_BACKUP_DIR:?}
keep=${SEAFILE_BACKUP_KEEP:-14}

# Never fill the rootfs if the mount is missing (mp1 is a Proxmox bind mount).
mountpoint -q "$dest" || { echo "$dest is not mounted" >&2; exit 1; }

# Dump to a raw temp file first, verify, then publish: a failed docker/mariadb-dump
# must not leave a valid-looking (even empty-but-valid gzip) backup behind.
raw=$(mktemp "$dest/.dump.XXXXXX")
gz="$raw.gz"
trap 'rm -f "$raw" "$gz"' EXIT

# The single quotes are deliberate: the variable is expanded inside the container,
# where MariaDB's own root password already is. Nothing is written to the host.
# shellcheck disable=SC2016
docker exec seafile-mysql sh -c \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --databases ccnet_db seafile_db seahub_db' \
  > "$raw"

# mariadb-dump ends a complete dump with this marker; a truncated one lacks it.
tail -n 1 "$raw" | grep -q '^-- Dump completed' || { echo "incomplete dump" >&2; exit 1; }
gzip -c "$raw" > "$gz"
gzip -t "$gz"
chmod 0640 "$gz"
mv "$gz" "$dest/seafile-db-$(date +%Y%m%d-%H%M%S).sql.gz"

# Keep the newest $keep dumps. Only reached after a verified new dump, so a failing
# night never prunes the good ones.
# shellcheck disable=SC2012
ls -1t "$dest"/seafile-db-*.sql.gz | tail -n +"$((keep + 1))" | xargs -r rm --
