# Hermes Agent and Matrix Gateway

> Hostnames below use `example.org` (the hosting zone, `vault_public_domain`) and
> `example.com` (the Matrix `server_name`, `vault_matrix_server_name`) as
> placeholders; the real values are in `group_vars/all/vault.yml`.

Two NixOS LXCs share one pinned Hermes flake but have separate state and processes.

| | Agent | Gateway |
|---|---|---|
| VMID / name | 107 / `hermes` | 108 / `hermes-gateway` |
| Network | VLAN 3, `fd5a:715f:1edc:a703::28` | VLAN 6, `fd5a:715f:1edc:a706::29` |
| Memory / swap | 8 / 8 GiB | 2 / 2 GiB |
| Services | Agent API :8642, dashboard :9119 | Matrix gateway, nginx :80/:443 |
| Public name | Behind CT108 only | `hermes.us.example.org` (direct AAAA, Fly A) |
| Backup path on host | `Backup/hermes` | `Backup/hermes-gateway` |

CT108 runs upstream `hermes gateway` in proxy mode. It decrypts Matrix messages,
forwards turns to CT107 over the authenticated API, and encrypts replies. CT107
keeps model credentials, sessions, tools, and the dashboard. The dashboard uses
Nous Portal OAuth client `agent:cmuqdu4i60002qe06c1a72bve` and the public
callback `https://hermes.us.example.org/auth/callback`. IPv6 clients reach
CT108 directly; IPv4 clients reach it through the shared Fly proxy.

## Network and secrets

Prydwen reserves CT108's hostid `29` with MAC `BC:24:11:6C:29:01`, DUID
`00020000ab116865726d6777006c`, and IAID `0x686d6777`. Its DDNS service
updates the direct, DNS-only AAAA record from the current VLAN 6 lease. The
first record must exist before DDNS can update it; create it from CT108's GUA
once the container boots. HTTP-01 on port 80 issues the nginx certificate.
The DNS-only A record points at the existing Fly app's dedicated IPv4. The Fly
nginx proxy routes port 443 by TLS SNI, forwards only Hermes's HTTP-01 challenge
path on port 80 to CT108 over IPv6, and redirects other Hermes HTTP requests to
HTTPS. CT108 still owns the TLS certificate and OAuth callback; Fly does not
decrypt HTTPS. The Fly app and its IPv4 address are shared with Nextcloud and
Matrix, so an outage there affects their IPv4 access together.

The router's existing VLAN 6 to VLAN 3 forwarding is unchanged. CT107's NixOS
firewall accepts API :8642 only from CT108 and dashboard :9119 only from CT108
or VLAN 2 management. Neither guest runs sshd;
Ansible manages both with `pct exec` through the Proxmox host. CT108 accepts
public :80/:443 only.

The Matrix token and cross-signing recovery key stay in
`vault_hermes_matrix_token` and `vault_hermes_matrix_recovery_key`; both are
rendered only into CT108. The private API bearer key is `vault_hermes_proxy_key`, shared between
CT107's `API_SERVER_KEY` and CT108's `GATEWAY_PROXY_KEY`. Runtime secrets are
in `/var/lib/hermes/secrets.env` (0400), outside the Nix store. The dashboard
OAuth client ID is public and declared in CT107's NixOS configuration. The old
basic-auth password remains in the vault for rollback only.

## Deploy and migrate

1. Apply the prydwen role before CT108 starts:
   `ansible-playbook playbooks/configure.yml --limit prydwen`.
2. Run `ansible-playbook playbooks/migrate_hermes.yml --tags provision`. The image is built
   on CT107, which already caches the pinned Hermes package, and uploaded to
   Proxmox. CT108 has a `ConditionPathExists` guard and cannot connect to Matrix
   before the E2EE store has been copied.
3. Create the Cloudflare DNS-only AAAA record from CT108's leased GUA, then run
   `ansible-playbook playbooks/migrate_hermes.yml --tags stage`. This deploys secrets and
   builds CT108's NixOS system on CT107, never inside the 2 GiB gateway guest.
   Check that HTTPS and `/api/status` work through nginx before cutover.
4. Run `ansible-playbook playbooks/migrate_hermes.yml --tags cutover`. It stops the old
   gateway, saves an offline Matrix archive on CT107, copies the Matrix platform
   directory including `crypto.db` and its WAL/SHM files, checks the database
   digest, enables CT108's gateway, then switches CT107 to API-only mode.
5. Verify an encrypted Matrix message, a reply, OAuth sign-in, and that CT107's
   API rejects requests without the bearer key. Check `systemctl status
   hermes-agent` on both guests, `hermes-backend` on CT107, and nginx/ACME on
   CT108. Confirm CT108 stays below its 2 GiB memory limit in normal use.

For IPv4 ingress, deploy `extern/ipv4-proxy/` to the existing
IPv4 proxy Fly app (`vault_fly_app_name`), then create a DNS-only A record for
`hermes.us.example.org` pointing at that app's dedicated IPv4. Keep the
DDNS-managed AAAA record. Check HTTPS, the HTTP redirect, and the HTTP-01
challenge path over IPv4 after publishing the A record.

When running Ansible from the sandboxed workstation, override the default SSH
ControlMaster path for the sentinel-lp/prydwen connections, which may be blocked by
the AF_UNIX allowlist (the guests' Paramiko-based `pct exec` connection is unaffected):

~~~sh
export ANSIBLE_SSH_ARGS='-F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ControlMaster=no'
~~~

The Matrix identity remains `@hermes:example.com` on device `HERMESGW01`.
Keeping the entire Matrix platform directory is required to decrypt previous
messages. Proxy mode does not relay dangerous-command approvals to Matrix;
those approvals occur on CT107.
The bot's cross-signing key is held in the encrypted Ansible vault so Hermes
can verify its Matrix device after a restart. Preserve that vault entry along
with the E2EE store when restoring the gateway.

The OpenAI Codex sign-in is stored on CT107, separate from the dashboard's Nous
Portal login. If model calls return HTTP 401, run `hermes auth refresh
openai-codex` as the `hermes` user on CT107. If the saved session is invalid,
run `hermes auth add openai-codex --type oauth --no-browser`, approve the device
code in a browser, and remove the revoked older credential with `hermes auth
remove openai-codex <index>`. Check the pool with `hermes auth list openai-codex`.

## Updates, backup, and rollback

CT107 declares the `obs` HTTP MCP server in `settings.mcp_servers`, currently
disabled with `enabled = false`. When enabled, it exposes
only `get_current_frame` and disables MCP prompt/resource tools. While it is
disabled, `explain-code` cannot capture the screen. The
`explain-code` skill is installed through `hermesHomeFiles` into
`$HERMES_HOME/skills/explain-code/SKILL.md`; its source lives in
`files/nixos/skills/explain-code/`. Ask Hermes to "use explain-code to explain
the coding problem on my screen" for a fresh OBS capture and a short numbered
explanation of the solution's intuition. Deploy changes to this configuration
or skill with `ansible-playbook playbooks/configure.yml --limit hermes`.

The shared flake applies `files/nixos/overlay.nix` to both guests and their
installation images. It patches the Python source before uv2nix builds the
Hermes wheel, preserving upstream's pinned dependency set and the gateway's
Matrix dependency group. Patching the final wrapper derivation would not
change the Python code it runs.

`patches/matrix-proxy-origin.patch` forwards `hermes_origin_platform: matrix`
from CT108 through chat completions to CT107's agent constructor. Matrix turns
use the existing Matrix prompt, which permits Markdown; requests without that
field keep the API prompt. The override requires API-key authentication and
accepts only `matrix`. Tool policy, session binding, and approvals still use
the API adapter. HTML remains subject to Matrix's existing sanitizer.

When updating Hermes, check that this patch still applies. To run the overlay's
HTTP regression tests, apply the patch to a disposable checkout of the pinned
Hermes revision, copy `tests/test_matrix_proxy_origin.py` from this role into
that checkout's `tests/gateway/`, and run its `scripts/run_tests.sh
tests/gateway/test_matrix_proxy_origin.py tests/gateway/test_proxy_mode.py
tests/gateway/test_api_server.py` with the checkout's test environment.

After changing the overlay, its patch, or `flake.lock`, run
`ansible-playbook playbooks/configure.yml --limit
sentinel-lp,hermes,hermes-gateway`. Both guests rebuild in-guest (`nixos-rebuild
switch` over `pct exec`). CT108 has only 2 GiB RAM + 2 GiB swap, so a gateway
change that has to compile rather than substitute is slow there; CT107 still
builds the gateway's LXC *image* (roles/tenant/hermes_gateway/tasks/build_template.yml).

CT107 and CT108 each run a weekly `hermes backup` to a separate ZFS bind mount,
retaining four archives. The gateway archive includes the Matrix E2EE SQLite
database via Hermes' safe SQLite snapshot. CT108 uses the ordinary unprivileged
LXC uid map, so its host backup directory belongs to uid/gid 101000; CT107
retains its existing uid 1000 passthrough.

For rollback, stop CT108's `hermes-agent` first so two clients never use the
same Matrix device simultaneously. On CT107, restore the old NixOS generation
and its prior `/var/lib/hermes/secrets.env`, then reactivate the generation so
its `.env` again contains the Matrix token and restart `hermes-agent`. The
pre-split Matrix directory and `/var/lib/hermes/matrix-pre-split.tar` remain on
CT107 until the new gateway has been verified. Do not copy a newer CT108 crypto
store back while either gateway is running.
