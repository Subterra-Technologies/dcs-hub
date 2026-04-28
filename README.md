# dcs-hub

Datacenter-side tools for the DCS fleet: the Zabbix-VM installer, setup TUI, and admin CLI.

Companion repo: [`dcs-pi-image`](https://github.com/Subterra-Technologies/dcs-pi-image) (the school-side appliance).
Full ops docs live in that repo at [`docs/OPS_RUNBOOK.md`](https://github.com/Subterra-Technologies/dcs-pi-image/blob/main/docs/OPS_RUNBOOK.md).

---

## What this is

Each Zabbix VM monitors one school district. This repo holds the scripts that join a fresh VM to the tailnet, scope it to the correct district, and wire it up so it can reach the district's Pi subnet router. No public IPs, no port forwarding, no per-VM manual config.

## Quick start — new Zabbix VM

**One-time, per tailnet.** In the Tailscale admin console → [Trust credentials](https://login.tailscale.com/admin/settings/trust-credentials) → OAuth clients → **Generate**. Grant two scopes:
- `devices:core` with **Read** — for the live district picker.
- `auth_keys` with **Write** — so the TUI can auto-mint pre-auth keys. **Select every `tag:zabbix-*` you'll provision** in the tag picker (per-tag selection is required even if you grant the broader `all` scope).

The client secret starts with `tskey-client-` (not `tskey-auth-`). Save it in your password manager.

**On every new VM** (Debian/Ubuntu or RHEL-family Linux, outbound internet):

```bash
# install git if it's not already there — minimal cloud images often don't have it
command -v git >/dev/null || sudo apt update && sudo apt install -y git \
  || sudo dnf install -y git || sudo yum install -y git

git clone https://github.com/Subterra-Technologies/dcs-hub /tmp/hub
sudo bash /tmp/hub/zabbix-vm/install.sh
```

The installer pulls `tailscale`, `gum`, `jq`, and `git`, drops the `dcs*` binaries into `/usr/local/sbin`, records the source SHA to `/var/lib/dcs/installed-sha`, and launches the setup TUI.

**TUI prompts** (first VM on this image only for OAuth):
- **OAuth client** — client ID + secret from the Trust credentials page. Validated live against the Tailscale token endpoint before being persisted to `/etc/dcs.conf`. Subsequent VMs on the same image skip this step.
- **District** — pick from the live Pi-tagged list or type a new slug.
- **Hostname** — default is the next free letter (`zabbix-<slug>-a`, `-b`, …).
- **ACL precheck** — the TUI reads the tailnet ACL and verifies `tag:zabbix-<district>` is in `tagOwners`. If missing, it prints a paste-ready snippet and exits rather than silently failing at the mint step.
- **Auth key** — minted automatically for `tag:zabbix-<district>`. No paste unless auto-mint fails (in which case you get Tailscale's actual error message + a manual-paste fallback).

**Pre-bake OAuth creds** (skip the TUI OAuth prompt on the first VM):
```bash
export DCS_TS_OAUTH_CLIENT_ID=<client-id>
export DCS_TS_OAUTH_CLIENT_SECRET=<client-secret>
sudo -E bash /tmp/hub/zabbix-vm/install.sh
```

## VM network requirements

Tailscale needs unfettered egress to its coordination plane and DERP relays. Most cloud providers and home networks already allow this; **office networks with DPI-aware firewalls (Palo Alto, Fortinet, Sophos, etc.) often classify Tailscale as a VPN/anonymizer and silently drop or throttle it**, which manifests as ~50% packet loss to the district Pi with `tailscale status` cheerfully reporting `direct`.

Before enrolling a VM, the network in front of it must allow:

- **UDP/3478** outbound to public IPs (STUN — Tailscale + Google).
- **UDP** outbound to high ephemeral ports (Tailscale uses random source/dest for direct paths).
- **TCP/443** outbound to `*.tailscale.com` **without TLS/SSL inspection**. DERP servers pin their certs and reject MITM.
- The firewall must **not** classify `tailscale.com` SNIs under "VPN", "anonymizer", or "proxy avoidance" categories.

Full reference: https://tailscale.com/kb/1082/firewall-ports.

### Quick check from a fresh VM

```bash
tailscale netcheck
```

A healthy result has `UDP: true` and a populated `Nearest DERP` with sub-100ms latency. If you see `UDP: false` or `Nearest DERP: unknown — no response to latency probes`, the egress is the problem — not the VM, not Tailscale.

To distinguish a hard block from SNI-based DPI, compare hostname-SNI vs raw-IP curl:

```bash
curl -sS --max-time 5 -o /dev/null -w "%{http_code}\n"    https://derp.tailscale.com/        # SNI = tailscale.com
curl -sS --max-time 5 -o /dev/null -w "%{http_code}\n" -k https://159.89.225.99:443/         # SNI = raw IP
```

Hostname times out + raw IP connects → SNI-based blocking. Both fail → IP-layer block. Both succeed → connectivity is fine and the issue is elsewhere.

## Day 2

On any enrolled VM:

```bash
sudo dcs status       # enrollment + tailnet state + installed version
sudo dcs districts    # list live Pi districts from the API
sudo dcs logs         # recent tailscaled journal
sudo dcs preflight    # verify this VM's egress permits Tailscale
sudo dcs update       # pull latest dcs tools from the repo
sudo dcs reconfigure  # re-run setup (swap district)
sudo dcs reset        # logout + wipe local state
```

`dcs preflight` is what you run when ping to a district Pi flaps despite `tailscale status` saying everything's fine — it runs the real UDP/STUN probes Tailscale uses, distinguishes SNI-based DPI from hard IP blocks, and exits non-zero with a specific failure pointing at the firewall rule that needs to change. Hand the [`HOST_NETWORK_REQUIREMENTS.md`](docs/HOST_NETWORK_REQUIREMENTS.md) doc to whoever administers the VM's egress (corporate IT, hosting provider, MSP) for the per-vendor firewall guidance.

`sudo dcs update` fetches the latest scripts from `main` (override with `DCS_REPO_REF=<branch|tag|sha>`), shows a changelog from your installed SHA, and reinstalls atomically. Preserves `/etc/dcs.conf` and enrollment state.

## Without OAuth

The TUI works without OAuth if you set `DCS_AUTHKEY=tskey-auth-…` — it skips both the OAuth prompt and the mint step and uses your key directly. Useful for air-gapped or scripted deploys where reaching the Tailscale API isn't possible.

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
