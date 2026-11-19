#!/usr/bin/env python3
"""Point a migrated HAOS /config at the BunkerWeb edge (playbooks/migrate_hass.yml).

    rewrite_http.py [--dry-run] CONFIG_DIR EDGE_ADDRESS EXTERNAL_URL LEGACY_HOST

Changes exactly two things and prints a JSON report:

* the top-level `http:` block of configuration.yaml: TLS settings (BunkerWeb terminates
  TLS now), the HAOS proxy add-on's trusted_proxies and any server_port/server_host are
  dropped, and `server_port: 8123`, `use_x_forwarded_for: true` and
  `trusted_proxies: [EDGE_ADDRESS]` are set. Every other key in the block (ip_ban_enabled,
  login_attempts_threshold, cors_allowed_origins, ...) and the rest of the file are kept
  byte for byte. Edited as text, not YAML: HA's !include/!secret tags and comments must
  survive.
* `.storage/http`, if present: since 2026.x HA keeps the http settings it actually uses
  here (`data.stable`, migrated from YAML once: `yaml_migration_done`), and on a failed
  start it falls back to them in recovery mode. The same keys are dropped/set there;
  `ssl_profile` stays (the loader requires the key; without a certificate it is unused)
  and so do ip_ban_enabled, cors_allowed_origins and the rest.
* `.storage/core.config`: external_url becomes EXTERNAL_URL; an internal_url that names
  LEGACY_HOST or uses https (the old TLS add-on) is cleared, so HA falls back to its own
  address.

Refuses (exit 2, nothing written) on anything it cannot edit safely: an inline or
!include'd `http:`, or more than one. With --dry-run it only reports. Standard library
only: it runs in HAOS's homeassistant container (rehearsal) and in the NixOS guest.
"""
import json
import os
import re
import sys

MANAGED = {
    "ssl_certificate",
    "ssl_key",
    "ssl_peer_certificate",
    "ssl_profile",
    "server_port",
    "server_host",
    "use_x_forwarded_for",
    "trusted_proxies",
}


class Refuse(Exception):
    pass


def rewrite_yaml(text, edge):
    lines = text.splitlines(keepends=True)
    heads = [i for i, l in enumerate(lines) if re.match(r"^http\s*:", l)]
    if len(heads) > 1:
        raise Refuse("configuration.yaml has more than one top-level http:")
    if heads and not re.match(r"^http\s*:\s*(#.*)?$", lines[heads[0]].rstrip("\n")):
        raise Refuse("configuration.yaml has an inline or !include'd http: (%s)" % lines[heads[0]].strip())

    if not heads:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines += ["\n", "http:\n"]
        start = end = len(lines)
        body, old = [], ""
    else:
        start = heads[0] + 1
        end = start
        # The block: indented lines, blank lines and indented comments. A column-0 line
        # (key or comment) ends it; trailing blank lines are left outside.
        while end < len(lines) and (lines[end][:1] in (" ", "\t") or not lines[end].strip()):
            end += 1
        while end > start and not lines[end - 1].strip():
            end -= 1
        body = lines[start:end]
        old = "".join(lines[heads[0] : end])

    keyed = [l for l in body if l.strip() and not l.lstrip().startswith("#")]
    indent = re.match(r"^[ ]*", keyed[0]).group(0) if keyed else "  "
    if keyed and "\t" in keyed[0][: len(indent) + 1]:
        raise Refuse("the http: block is indented with tabs")

    # Group the block into entries: one per key at the block's indentation, with every
    # deeper (or same-level list item) line after it.
    entries, cur = [], None
    for l in body:
        m = re.match(r"^%s([A-Za-z_][A-Za-z0-9_]*)\s*:" % re.escape(indent), l)
        if m and not l[len(indent) :].startswith((" ", "-")):
            cur = [m.group(1), [l]]
            entries.append(cur)
        elif cur is None or re.match(r"^%s#" % re.escape(indent), l):
            # A comment at the block's own level stands alone: it may describe the next
            # key, so it must not go away with a dropped one.
            cur = None
            entries.append([None, [l]])
        else:
            cur[1].append(l)

    dropped = [k for k, _ in entries if k in MANAGED]
    kept = [ls for k, ls in entries if k not in MANAGED]
    managed = [
        "%sserver_port: 8123\n" % indent,
        "%suse_x_forwarded_for: true\n" % indent,
        "%strusted_proxies:\n" % indent,
        "%s  - %s\n" % (indent, edge),
    ]
    new_body = [l for ls in kept for l in ls]
    if new_body and not new_body[-1].endswith("\n"):
        new_body[-1] += "\n"
    lines[start:end] = new_body + managed
    return "".join(lines), {"old_http_block": old, "dropped_http_keys": dropped}


STORE_DROPPED = ("ssl_certificate", "ssl_key", "ssl_peer_certificate", "server_host")


def rewrite_http_store(text, edge):
    doc = json.loads(text)
    data = doc.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("stable"), dict):
        raise Refuse(".storage/http has no data.stable object")
    stable = data["stable"]
    dropped = [k for k in STORE_DROPPED if k in stable]
    for k in dropped:
        del stable[k]
    old = {k: stable.get(k) for k in ("server_port", "use_x_forwarded_for", "trusted_proxies")}
    stable.update(server_port=8123, use_x_forwarded_for=True, trusted_proxies=[edge])
    # A pending (not yet confirmed) change would be applied on top at the next start.
    data["pending"] = None
    return json.dumps(doc, indent=2) + "\n", {"store_dropped_keys": dropped, "store_old": old}


def rewrite_core_config(text, external_url, legacy_host):
    doc = json.loads(text)
    data = doc.get("data")
    if not isinstance(data, dict):
        raise Refuse(".storage/core.config has no data object")
    report = {"old_external_url": data.get("external_url"), "old_internal_url": data.get("internal_url")}
    data["external_url"] = external_url
    internal = data.get("internal_url") or ""
    if legacy_host in internal or internal.startswith("https://"):
        data["internal_url"] = None
    report["internal_url"] = data.get("internal_url")
    return json.dumps(doc, indent=4) + "\n", report


def replace(path, content):
    st = os.stat(path)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)


def main(argv):
    dry = argv[:1] == ["--dry-run"]
    if dry:
        argv = argv[1:]
    if len(argv) != 4:
        sys.stderr.write(__doc__)
        return 64
    config_dir, edge, external_url, legacy_host = argv
    yaml_path = os.path.join(config_dir, "configuration.yaml")
    core_path = os.path.join(config_dir, ".storage", "core.config")
    store_path = os.path.join(config_dir, ".storage", "http")
    new_store = None
    try:
        if os.path.exists(store_path):
            with open(store_path) as f:
                new_store, store_report = rewrite_http_store(f.read(), edge)
        with open(yaml_path) as f:
            new_yaml, report = rewrite_yaml(f.read(), edge)
        with open(core_path) as f:
            new_core, core_report = rewrite_core_config(f.read(), external_url, legacy_host)
    except (Refuse, ValueError, OSError) as e:
        print(json.dumps({"refused": str(e)}))
        return 2
    report.update(core_report)
    report["http_store"] = store_report if new_store is not None else None
    block = re.search(r"(?m)^http\s*:.*\n(?:(?:[ \t].*|[ \t]*)\n)*", new_yaml)
    report["new_http_block"] = block.group(0).rstrip("\n") + "\n"
    if not dry:
        replace(yaml_path, new_yaml)
        replace(core_path, new_core)
        if new_store is not None:
            replace(store_path, new_store)
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
