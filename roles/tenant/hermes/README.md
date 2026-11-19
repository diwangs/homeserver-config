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
| Services | Agent API :8642, dashboard :9119 | Matrix gateway, nginx :80 (origin for the edge) |
| Public name | Behind CT108 only | `hermes.us.example.org` (via the BunkerWeb edge, CT110) |
| Backup path on host | `Backup/hermes` | `Backup/hermes-gateway` |

CT108 runs upstream `hermes gateway` in proxy mode. It decrypts Matrix messages,
forwards turns to CT107 over the authenticated API, and encrypts replies. CT107
keeps model credentials, sessions, tools, and the dashboard. The dashboard uses
Nous Portal OAuth client `agent:cmuqdu4i60002qe06c1a72bve` and the public
callback `https://hermes.us.example.org/auth/callback`. Public clients reach
CT108 only through the BunkerWeb edge (`roles/tenant/bunkerweb`), which
terminates TLS (IPv6 directly, IPv4 through the router's Jool NAT64).

## Network and secrets

Prydwen reserves CT108's hostid `29` with MAC `BC:24:11:6C:29:01`, DUID
`00020000ab116865726d6777006c`, and IAID `0x686d6777`; that address is only
used inside the house. `hermes.us.example.org` is a CNAME to `edge.us.example.org`, the
BunkerWeb edge, which holds the `*.us` wildcard (DNS-01) and proxies to CT108's nginx over
plain HTTP on its ULA; CT108 has no certificate of its own. The router forwards nothing
from wan to CT108.

CT108's Matrix client reaches the homeserver by its public name, through the edge like
any other client, so it gets the real certificate. Its traffic is a few long-polls a
minute, well under the edge's rate limits.

The router's existing VLAN 6 to VLAN 3 forwarding is unchanged. CT107's NixOS
firewall accepts API :8642 only from CT108 and dashboard :9119 only from CT108
or VLAN 2 management. Neither guest runs sshd;
Ansible manages both with `pct exec` through the Proxmox host. CT108 accepts
:80 from the edge's ULA only (`networking.firewall.extraCommands`); the router
forwards nothing from wan to it.

The Matrix token and cross-signing recovery key stay in
`vault_hermes_matrix_token` and `vault_hermes_matrix_recovery_key`; both are
rendered only into CT108. The private API bearer key is `vault_hermes_proxy_key`, shared between
CT107's `API_SERVER_KEY` and CT108's `GATEWAY_PROXY_KEY`. Runtime secrets are
in `/var/lib/hermes/secrets.env` (0400), outside the Nix store. The dashboard
OAuth client ID is public and declared in CT107's NixOS configuration. The old
basic-auth password remains in the vault for rollback only.

## Deploy

Day to day, `ansible-playbook playbooks/configure.yml --limit hermes,hermes-gateway`. CT108 was
split out of CT107 by a one-off playbook, since removed
(`git show e1b4a21:playbooks/migrate_hermes.yml`): it built CT108's image on CT107, staged its
secrets, then stopped the old gateway, copied the Matrix platform directory (including
`crypto.db` and its WAL/SHM files) and switched CT107 to API-only mode. CT108 keeps its
`ConditionPathExists` guard, so a rebuilt CT108 cannot connect to Matrix until that E2EE store
is back in place.

After a change, verify an encrypted Matrix message and a reply, OAuth sign-in, and that CT107's
API rejects requests without the bearer key; check `systemctl status hermes-agent` on both
guests, `hermes-backend` on CT107, and nginx on CT108, and that CT108 stays below its 2 GiB
memory limit.

Public ingress is the BunkerWeb edge (`roles/tenant/bunkerweb/README.md`):
`hermes.us.example.org` is a CNAME to `edge.us.example.org`. Check HTTPS and the HTTP
redirect over both IPv4 and IPv6 after changing the records.

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

## Linear Kanban workers

CT107 turns Linear issues into GitHub pull requests with Hermes Kanban. Every
two minutes the `hermes-linear-poller` timer asks Linear for the issues delegated
to the Hermes Linear app that are not completed or canceled. For each new one it
clones the target repository into `/var/lib/hermes/work/<ISSUE-ID>` and
creates a Kanban card. The gateway's built-in dispatcher then starts the
`coder-claude-code` worker profile on the card. The worker follows
`files/nixos/skills/linear-issue-worker/SKILL.md`: it delegates the change to
Claude Code (`claude -p`), pushes a branch `hermes/<issue-id>`, opens a PR as
the GitHub bot account, and updates the Linear issue through Linear's MCP
server. The card can close only once the PR's required checks pass. That is the
Kanban completion gate, which needs at least one required check on the
repository. The poller only reads Linear. CT107 still accepts no traffic from the
internet.

### Conventions in Linear

- **Pick-up:** pick the Hermes app in the issue's assignee menu. That makes the
  app the issue's *delegate*; the person assigned stays the assignee. The worker
  moves the issue to the team's first started state (*In Progress*), then to
  *In Review* with the PR link, and comments when it is blocked.
- **Target repository:** one Linear project maps to one repository, through a
  project label (a label on the project, not the issue): either a label named
  `OWNER/NAME` inside a project label group called `repo`, or a label named
  `repo:OWNER/NAME`. Issues outside a project, or in a project that names no
  repository or more than one, are skipped with a line in the poller's journal.
- An issue is queued once. The poller records it in
  `/var/lib/hermes/linear-poller-state.json`, and the card's idempotency key is
  derived from the issue id, so moving an issue back to Todo or delegating it
  again does not create a second card.
- **Follow-ups:** comment on the issue. On each pass the poller passes new
  comments from people (not the app's own, not integrations') to the issue's
  latest card. A blocked card gets them as a card comment and is unblocked; a
  finished card gets a follow-up card, linked to it as its parent, in the same
  clone, which pushes to the same PR (or opens a new one from a new branch if
  that PR was merged or closed); a card still in progress gets them as a card
  comment. This only works while the issue is open and still delegated: to
  follow up on a completed issue, move it back to an open state first.
  Comments are untrusted input to the worker, the same as the description.

### Accounts and secrets

The secrets live in the vault, as inline-vault variables in
`group_vars/all/hermes_kanban.yml`. The bot's commit identity is plain
`hermes_github_name` / `hermes_github_email` in the same file.
`tasks/linear_kanban.yml` is skipped until all of these are set:

| Variable | Value |
|---|---|
| `vault_hermes_github_token` | Fine-grained PAT of the GitHub bot account, limited to the repositories it may work on. Repository permissions: Contents read/write, Pull requests read/write, Checks read, Commit statuses read, Metadata read, Administration read (the completion gate reads branch protection) |
| `vault_hermes_linear_client_id`, `vault_hermes_linear_client_secret` | Client credentials of the Hermes Linear OAuth app (see below) |
| `vault_hermes_claude_code_oauth_token` | Output of `claude setup-token`, run once on any machine signed in to the Claude subscription |

### The Linear app

Hermes is a Linear OAuth application installed with the app actor, so it shows
up and acts as its own app user, which takes no seat. A workspace admin creates
it under Settings → API → OAuth applications:

- **Redirect URI:** `http://localhost/callback`. The form requires one, but the
  client-credentials grant never uses it.
- **Client credentials:** on.
- **Webhooks / Agent session events:** off. Agent sessions expect a webhook
  receiver that answers within seconds, and CT107 has none; with them on, every
  delegation would show an unresponsive session.

The poller requests the app's token with the client-credentials grant and the
scopes `read,write,app:assignable`. The first such request installs the app in
the workspace; only then does it appear in assignee menus. The token lasts 30
days, has no refresh token, and is cached in
`/var/lib/hermes/credentials/linear-token.json`; the poller requests a new one a
week before expiry or when Linear rejects the old one, and writes it to the
worker profile's `.env` as `LINEAR_ACCESS_TOKEN` for the Linear MCP server.
Keep the scope set unchanged: requesting a different one revokes the app's
other tokens. The app sees every public team. Grant it private teams on its
page in Linear.

The bot GitHub account's repository access is the real allowlist. A repository
label naming a repository the bot cannot read fails at the clone step.

The tokens are written to `/var/lib/hermes/credentials/` (0400). The `gh` and
`claude` on the agent's PATH are wrappers from `configuration.nix` that export the
token from there. Hermes strips credentials from the environment of commands an
agent runs, so a plain environment variable would not reach them. The worker
profile's own files (`$HERMES_HOME/profiles/coder-claude-code/{config.yaml,.env}`)
and the poller's `/var/lib/hermes/linear-poller.env` are rewritten by Ansible on
every run, except the profile `.env`'s `LINEAR_ACCESS_TOKEN` line, which belongs to
the poller. The profile `.env` carries `GH_TOKEN` because the completion gate uses
the assignee profile's own GitHub login, never the ambient one. The worker's
model is the root profile's OpenAI Codex login, which named profiles share.

Deploy with `ansible-playbook playbooks/configure.yml --limit hermes`.

### Checks and troubleshooting

As the `hermes` user on CT107 (`pct enter 107`, then `runuser -u hermes -- bash`):

~~~sh
hermes profile list                       # coder-claude-code is present
gh auth status                            # signed in as the bot
claude -p 'reply with ok'                 # Claude Code subscription sign-in works
hermes -p coder-claude-code mcp list      # linear is connected
hermes kanban list                        # cards created by linear-poller
hermes kanban tail <card id>              # follow one worker
hermes kanban diagnostics                 # stranded or stuck cards
~~~

`journalctl -u hermes-linear-poller` shows each pass: the cards it created, the
comments it passed on, and the issues it skipped and why. Clones of cards
finished more than seven days ago are removed by the poller, unless a follow-up
card still uses them. At most two cards run at once (`kanban.max_in_progress`),
and the 8 GiB memory limit is the reason.
