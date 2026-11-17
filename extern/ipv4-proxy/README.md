# IPv4 proxy

An L4 (SNI passthrough) nginx on Fly.io giving the IPv6-only dmz tenants a shared
IPv4 address. TLS is not terminated here.

## Setup
`nginx.conf` and `fly.toml` name the real hostnames and Fly app, so they are
gitignored. Create them from the committed templates and fill in the placeholders
(the real values are recorded in `group_vars/all/vault.yml`: `vault_public_domain`,
`vault_matrix_server_name`, `vault_fly_app_name`, `vault_fly_primary_region`):

```bash
cp nginx.conf.example nginx.conf
cp fly.toml.example fly.toml
```

## Deploy
```bash
# cd to this directory
nix shell nixpkgs#flyctl
fly deploy
```
