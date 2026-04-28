# DCS Zabbix VM — Network Requirements

**Purpose:** This document lists the egress rules a DCS Zabbix VM needs to
operate. Hand it to whoever administers the network the VM lives on
(corporate IT, hosting provider security team, MSP, etc.) before
attempting to enroll a new VM.

If your VM is already enrolled and showing flaky connectivity to district
Pis (intermittent ping loss, "online" status but ~50% packet drop), run
`sudo dcs preflight` on the VM — it'll tell you which of these rules is
not currently satisfied.

---

## What this VM is

A monitoring server that runs Zabbix and connects to a fleet of remote
Raspberry Pi appliances at school district sites. The VM connects to
those Pis through a service called Tailscale, which is how the
monitoring traffic reaches each district without requiring open ports
or static public IPs at the school side.

**Outbound only.** This VM never accepts inbound connections from the
public internet. No public IP needed, no DMZ, no port forwards. All
connectivity is initiated outbound from the VM.

---

## What it needs from your network

### Required egress

| Protocol | Destination | Purpose |
|---|---|---|
| **UDP/3478** | `*.tailscale.com` and any public IP | STUN — NAT traversal probe |
| **UDP** ephemeral high ports | any public IP | Direct peer-to-peer keepalive (preferred path) |
| **TCP/443** | `*.tailscale.com` (DERP relay servers) | Fallback when UDP is blocked |
| **TCP/443** | `controlplane.tailscale.com` | Authentication and tailnet membership |
| **TCP/443** | `pkgs.tailscale.com`, `repo.charm.sh` | Package updates (apt sources) |
| **UDP/53** + **TCP/53** | your DNS resolver | Standard name resolution |
| **UDP/123** | NTP servers | Time sync |

Vendor reference: https://tailscale.com/kb/1082/firewall-ports

### What must NOT happen to its traffic

- **No SSL/TLS deep inspection** of traffic to `*.tailscale.com`.
  Tailscale's DERP relay servers pin their own TLS certificates and will
  reject connections that go through an interception proxy installing a
  corporate CA cert. SSL inspection on this domain breaks the VM.
- **No "VPN", "anonymizer", or "proxy avoidance" category blocks**
  applied to this VM. Application-aware firewalls (Palo Alto, Fortinet,
  Sophos, Check Point, Cisco) classify Tailscale under these categories
  by default. Exempt this VM, or whitelist `*.tailscale.com` explicitly.

### What the VM will NOT do

- Will not initiate connections to anything other than its tailnet peers
  and the upstream Tailscale infrastructure.
- Will not proxy user traffic, run an exit node, or function as a VPN
  for end users.
- Will not open ports inbound from the internet.

---

## Symptoms of a misconfigured network

If the VM is enrolled but the network is interfering with Tailscale, the
classic signature is **~50% packet loss to district Pis with periodic
~25-second outages**, while `tailscale status` reports `direct` and
`Online: true`. This happens because the existing tailscaled session
limps along on a stale connection while new probes are dropped.

Run `sudo dcs preflight` to confirm. A failing network shows:
- `UDP: false` from `tailscale netcheck`
- `Nearest DERP: unknown`
- TCP/443 to `derp.tailscale.com` (hostname) timing out, but TCP/443 to
  the same IP via raw IP succeeds → SNI-based DPI block

---

## Easiest setup paths by hosting context

### Self-hosted Proxmox / VMware / on-prem hypervisor

The VM's traffic almost certainly traverses the corporate edge firewall.
The most efficient ask is a **per-IP exemption from anti-VPN/anonymizer
filtering** plus **disable SSL inspection for `*.tailscale.com`**.

Most enterprise firewalls let you exempt a single IP from a specific
threat-prevention/URL-filtering category in 2-3 minutes. Do that rather
than trying to whitelist Tailscale's entire infrastructure IP-by-IP.

### Cloud-hosted (AWS / GCP / Azure / DigitalOcean / Hetzner / Linode)

By default, all major cloud providers permit the egress Tailscale needs
out of the box — no firewall changes required. Just make sure:

- **Security group / VPC firewall** allows outbound `0.0.0.0/0` on UDP
  and TCP. Most defaults do.
- **No NACLs** drop UDP traffic.
- **No transit-gateway / on-prem-routed egress** that funnels VM traffic
  through a corporate firewall (this puts you back in the on-prem case).

### Behind a cloud SSE / SASE product (Zscaler, Netskope, Palo Alto Prisma)

These products tunnel all VM egress through a centralized inspection
plane. Most of them block Tailscale by default. You'll need a tenant-
admin to add a **bypass rule for `*.tailscale.com`** that disables
SSL inspection and category-based blocking. This is a 10-minute change
on their end but requires their cooperation.

---

## Common firewall product specifics

**Palo Alto / Prisma Access:**
Create a Security Policy from the VM to `any` allowing App-ID
`tailscale` (it has an explicit App-ID). No Decryption profile applied
to that traffic.

**Fortinet FortiGate:**
Create a policy from the VM IP to `all` outbound with no SSL inspection
profile. Or exempt `*.tailscale.com` in the existing SSL inspection
profile's exemption list.

**Cisco ASA / FTD / Umbrella:**
Add the VM's IP to the "Internal Networks" allow list. Ensure no
application filter (under Threat Defense) blocks the `Anonymizer` or
`VPN/Proxy` categories for that IP.

**Sophos UTM / XG / SG:**
Exempt the VM's IP from "Web Protection" → "Filter" group. Disable SSL
decryption on `*.tailscale.com`.

**Check Point:**
Add the VM to a `Trusted Source` host group with a rule that bypasses
HTTPS Inspection and Application Control for the Tailscale category.

**OPNsense / pfSense / pfBlockerNG:**
Remove the VM's IP from any IP-block lists. DigitalOcean ASN ranges
(where Tailscale's DERP servers run) sometimes show up in low-quality
threat feeds.

**Sophos Intercept X / Microsoft Defender for Endpoint / CrowdStrike:**
These run on the OS, not the network. They generally don't block
Tailscale, but if the VM has aggressive endpoint policies, exempt the
`tailscaled` process.

---

## Verifying after the firewall change

On the VM, after the network admin makes changes:

```bash
sudo systemctl restart tailscaled
sleep 10
sudo dcs preflight
```

A clean result looks like:

```
▸ 3. Tailscale netcheck (real UDP/DERP probes)
  ✓ UDP egress reaches Tailscale STUN
  ✓ Nearest DERP: dfw, 16.1ms
▸ 4. SNI-based DPI detection
  ✓ TCP/443 to DERP reachable, no SNI-based blocking detected
▸ 5. Summary
  ✓ All checks passed — network permits Tailscale operation
```

After that, `ping <pi-tailnet-ip>` from the VM should show clean,
single-digit-millisecond latency with zero loss. If it doesn't, the
problem is on the Pi side, not the VM side.

---

## Questions

If your network admin has questions or hits a corner case not covered
above, contact:

**Subterra Technologies** — `noah@subterratechnologies.com`

We're happy to get on a call and walk through firewall configuration
with your team. We've done this dance with several flavors of
restrictive enterprise networks and can usually identify the
specific rule that needs to change in a few minutes.

---

*This document lives at*
*`https://github.com/Subterra-Technologies/dcs-hub/blob/main/docs/HOST_NETWORK_REQUIREMENTS.md`*
*— always pull the latest version before each deployment.*
