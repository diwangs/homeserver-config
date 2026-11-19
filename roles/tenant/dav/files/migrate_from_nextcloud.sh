#!/usr/bin/env bash
# One-off: copy one user's address books and calendars from Nextcloud into Radicale's storage,
# with no logins on either side. Runs ON THE PROXMOX HOST (it needs `pct`), piped from the
# workstation:
#
#   ssh root@sentinel-lp 'bash -s -- <nextcloud-user> <radicale-user>' \
#     < roles/tenant/dav/files/migrate_from_nextcloud.sh
#   ssh root@sentinel-lp 'DRY_RUN=1 bash -s -- diwangs diwangs' < ...    # list only
#
# Source: the raw vCards / iCalendar objects in Nextcloud's Postgres (CT103, the AIO database
# container), read-only. Nextcloud 35 has no `occ` export command for them.
# Destination: Radicale's filesystem storage on the ZFS dataset (host_vars/dav.yml mp0), i.e.
#   <dir>/collections/collection-root/<radicale-user>/<collection>/<item>.vcf|.ics
#   <dir>/collections/collection-root/<radicale-user>/<collection>/.Radicale.props
# Each collection is built in a staging directory and renamed into place, so Radicale never sees
# a half-written one. An existing destination collection is never touched (set FORCE=1 to
# replace it). Skipped: Nextcloud's generated "contact_birthdays" calendar, calendar subscriptions,
# trashed calendars and the system address book. Nothing in Nextcloud is changed.
set -euo pipefail

NC_USER=${1:?usage: migrate_from_nextcloud.sh <nextcloud-user> <radicale-user>}
DAV_USER=${2:?usage: migrate_from_nextcloud.sh <nextcloud-user> <radicale-user>}
NC_CT=${NC_CT:-103}
NC_DB_CONTAINER=${NC_DB_CONTAINER:-nextcloud-aio-database}
NC_DB_USER=${NC_DB_USER:-oc_nextcloud}
NC_DB_NAME=${NC_DB_NAME:-nextcloud_database}
DATASET=${DATASET:-/mnt/frontpanel-pool/frontpanel-dataset/Radicale}
OWNER=${OWNER:-101000} # host uid/gid the unprivileged CT maps the container's uid 1000 to
DRY_RUN=${DRY_RUN:-0}
FORCE=${FORCE:-0}

[[ $NC_USER =~ ^[A-Za-z0-9._@-]+$ && $DAV_USER =~ ^[A-Za-z0-9._@-]+$ ]] || { echo "bad user name" >&2; exit 2; }
root=$DATASET/collections/collection-root
[ "$DRY_RUN" = 1 ] || mountpoint -q "$(dirname "$DATASET")" || { echo "dataset is not mounted" >&2; exit 1; }
[ "$DRY_RUN" = 1 ] || [ -d "$root" ] || { echo "$root missing: has Radicale started once?" >&2; exit 1; }

tab=$(printf '\t')
psql_nc() { pct exec "$NC_CT" -- docker exec -i "$NC_DB_CONTAINER" psql -U "$NC_DB_USER" -d "$NC_DB_NAME" -v ON_ERROR_STOP=1 -v u="$NC_USER" -At -F "$tab" "$@"; }

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
STAGE=
trap '[ -z "$STAGE" ] || rm -rf "$STAGE"' EXIT

# copy KIND ID SLUG DISPLAYNAME TAG EXTRA_PROPS TABLE KEYCOL DATACOL EXT
copy() {
  local kind=$1 id=$2 slug=$3 name=$4 tag=$5 extra=$6 table=$7 keycol=$8 datacol=$9 ext=${10}
  local dest n=0 uri b64 count_sql items_sql
  [[ $slug =~ ^[A-Za-z0-9._-]+$ ]] || { echo "skip $kind '$slug': unsafe name" >&2; return 0; }
  dest=$root/$DAV_USER/$slug
  if [ -e "$dest" ] && [ "$FORCE" != 1 ]; then echo "skip $kind '$slug': $dest exists (FORCE=1 to replace)"; return 0; fi
  local where="$keycol = :id"
  [ "$table" = oc_calendarobjects ] && where="$where and calendartype = 0"
  count_sql="select count(*) from $table where $where;"
  # One line per item: <file name> TAB <base64 of the stored object, newlines removed>.
  items_sql="select uri, translate(encode($datacol, 'base64'), E'\\n', '') from $table where $where order by id;"
  if [ "$DRY_RUN" = 1 ]; then
    n=$(psql_nc -v id="$id" <<<"$count_sql")
    echo "would copy $kind '$name' -> $DAV_USER/$slug ($n item(s))"; return 0
  fi
  mkdir -p "$root/$DAV_USER"
  stage=$(mktemp -d "$root/$DAV_USER/.stage.XXXXXX"); STAGE=$stage
  while IFS="$tab" read -r uri b64; do
    [[ $uri =~ ^[A-Za-z0-9._@-]+$ ]] || { echo "unsafe item name in $slug" >&2; rm -rf "$stage"; exit 1; }
    [[ $uri == *"$ext" ]] || uri=$uri$ext
    printf '%s' "$b64" | base64 -d >"$stage/$uri"
    n=$((n + 1))
  done < <(psql_nc -v id="$id" <<<"$items_sql")
  printf '{"tag": "%s", "D:displayname": "%s"%s}\n' "$tag" "$(json_escape "$name")" "$extra" >"$stage/.Radicale.props"
  chown -R "$OWNER:$OWNER" "$stage"
  find "$stage" -type d -exec chmod 0750 {} +
  find "$stage" -type f -exec chmod 0640 {} +
  if [ -e "$dest" ]; then mv "$dest" "$dest.replaced.$(date +%s)"; fi
  mv "$stage" "$dest"; STAGE=
  echo "copied $kind '$name' -> $DAV_USER/$slug ($n item(s))"
}

while IFS="$tab" read -r id uri name; do
  [ -n "$id" ] || continue
  copy "address book" "$id" "$uri" "$name" VADDRESSBOOK "" oc_cards addressbookid carddata .vcf
done < <(psql_nc <<<"select id, uri, displayname from oc_addressbooks where principaluri = 'principals/users/' || :'u' order by id;")

while IFS="$tab" read -r id uri name components; do
  [ -n "$id" ] || continue
  copy "calendar" "$id" "$uri" "$name" VCALENDAR ", \"C:supported-calendar-component-set\": \"$components\"" \
    oc_calendarobjects calendarid calendardata .ics
done < <(psql_nc <<<"select id, uri, displayname, components from oc_calendars where principaluri = 'principals/users/' || :'u' and deleted_at is null and uri <> 'contact_birthdays' order by id;")
