# dcs-hub

Datacenter-side tools for the DCS fleet: the Zabbix-VM installer, setup TUI, and admin CLI.

Companion repo: [`dcs-pi-image`](https://github.com/Subterra-Technologies/dcs-pi-image) (the school-side appliance).
Full ops docs live in that repo at [`docs/OPS_RUNBOOK.md`](https://github.com/Subterra-Technologies/dcs-pi-image/blob/main/docs/OPS_RUNBOOK.md).

---

## What this is

Each Zabbix VM monitors one school district. This repo holds the scripts that join a fresh VM to the tailnet, scope it to the correct district, and wire it up so it can reach the district's Pi subnet router. No public IPs, no port forwarding, no per-VM manual config.

## Quick start — new Zabbix VM

**One-time, per tailnet.** In the Tailscale admin console → Settings → OAuth clients → **Generate**. Grant two scopes:
- `devices:read` — for the live district picker.
- `auth_keys:write` — so the TUI can auto-mint pre-auth keys.

Save the client ID and secret in your password manager.

**On every new VM** (Debian/Ubuntu or RHEL-family Linux, outbound internet):

```bash
git clone https://github.com/Subterra-Technologies/dcs-hub /tmp/hub
export DCS_TS_OAUTH_CLIENT_ID=<client-id>
export DCS_TS_OAUTH_CLIENT_SECRET=<client-secret>
sudo -E bash /tmp/hub/zabbix-vm/install.sh
```

The installer pulls `tailscale`, `gum`, and `jq`, drops the `dcs*` binaries into `/usr/local/sbin`, persists the OAuth creds to `/etc/dcs.conf` (chmod 0600), and launches the setup TUI.

Two prompts: **pick the district** from the live list, **confirm the hostname** (default is `zabbix-<slug>-a`). The TUI auto-mints a one-hour tag-scoped pre-auth key, runs `tailscale up`, validates the tag, and persists enrollment metadata. Done.

## Day 2

On any enrolled VM:

```bash
sudo dcs status       # enrollment + tailnet state
sudo dcs districts    # list live Pi districts from the API
sudo dcs logs         # recent tailscaled journal
sudo dcs reconfigure  # re-run setup (swap district)
sudo dcs reset        # logout + wipe local state
```

## Without OAuth

The TUI still works without OAuth creds — it just falls back to asking the operator to type the district slug and paste a hand-minted pre-auth key. OAuth makes it dead-simple; it isn't a hard dependency.

## Managing the tailnet ACL — single source of truth

As the fleet grows past a handful of districts, hand-editing the Tailscale ACL policy stops scaling. Instead, maintain a list of districts in `districts.yaml` and generate the ACL mechanically:

```bash
cp districts.yaml.example districts.yaml
# edit districts.yaml — add each district's slug + CIDRs
bin/dcs-gen-acl > policy.json
# paste policy.json into Tailscale admin → Access Controls
```

The generator produces a coherent policy in one shot: `tagOwners` entries for every `tag:pi-<slug>` and `tag:zabbix-<slug>` (owned by `tag:provisioner` so the OAuth client can mint them), per-district `acls` rules wiring `zabbix-<slug>` → `pi-<slug>`, a blanket `tag:ops` admin rule, `ssh` rules that allow `tag:ops` → all nodes as user `dcs`, and `autoApprovers` for RFC1918 routes on any Pi.

`districts.yaml` is **gitignored** — district names and CIDRs are mildly sensitive operational data. Keep the real file local or in a private vault.

Dependencies for the generator: `yq` (v3+, apt has it) and `jq`.

## Repo layout

| Path | Purpose |
|---|---|
| `districts.yaml.example`   | Template for the district source-of-truth file. |
| `bin/dcs-gen-acl`          | Generates Tailscale ACL JSON from `districts.yaml`. |
| `zabbix-vm/install.sh`     | Idempotent VM installer — run once per VM. |
| `zabbix-vm/dcs-setup`      | First-time enrollment TUI (auto-suggests next hostname letter). |
| `zabbix-vm/dcs`            | Day-2 admin CLI/TUI. |
| `zabbix-vm/dcs-districts`  | Lists Pi-tagged districts via the Tailscale API. |
| `zabbix-vm/dcs-mint-key`   | Mints a one-hour tag-scoped pre-auth key via the API. |
| `zabbix-vm/dcs-query`      | General-purpose Tailscale-API queries (CIDRs, hostnames). |
| `zabbix-vm/bootstrap.sh`   | Headless (flag-based) enrollment — for CI / scripted deploys. |

## Headless path (CI)

If you're scripting deployments and the operator isn't at the TUI:

```bash
sudo /tmp/hub/zabbix-vm/bootstrap.sh \
    --authkey tskey-auth-... \
    --hostname zabbix-oakridge-a
```

Same end state, no prompts.

## What NOT to commit

The tree itself contains no secrets — safe to publish. But never commit:
- `/etc/dcs.conf` (holds the OAuth client secret)
- Raw pre-auth keys (`tskey-auth-...`)
- Customer-specific ACL policies or tailnet exports

The `.gitignore` already blocks the common patterns (`*.key`, `*.pem`, `.env`, etc.) but secrets pasted into commit messages or new files are your responsibility to avoid.
