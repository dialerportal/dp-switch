<p align="center">
  <a href="https://dialerportal.com">
    <img src="portal/public/brand/dialerportal-logo-256.png" width="96" alt="DialerPortal — VoIP billing and session border control">
  </a>
</p>

<h1 align="center"><a href="https://dialerportal.com">DialerPortal</a> · DP Switch</h1>

<p align="center">
  Session border controller + billing portal, installed on a fresh Debian 13 host with one command.<br>
  An open-source component of the <a href="https://dialerportal.com">DialerPortal</a> VoIP platform.
</p>

<p align="center">
  <a href="https://dialerportal.com"><img src="https://img.shields.io/badge/website-dialerportal.com-0b6fa4?style=flat-square" alt="DialerPortal website"></a>
  <a href="https://github.com/dialerportal/dp-switch"><img src="https://img.shields.io/badge/source-dp--switch-24292e?style=flat-square&logo=github" alt="dp-switch on GitHub"></a>
  <a href="https://github.com/dialerportal/dp-switch/issues"><img src="https://img.shields.io/badge/support-issues-64CEFB?style=flat-square" alt="Report an issue"></a>
</p>

<p align="center">
  <a href="https://dialerportal.com">Website</a> ·
  <a href="#install-one-command">Install</a> ·
  <a href="#what-it-does">How it works</a> ·
  <a href="#after-install">After install</a> ·
  <a href="#security-notes">Security</a> ·
  <a href="https://github.com/dialerportal/dp-switch/issues">Support</a>
</p>

---

- **Kamailio 6.0** — public SIP edge (5060/udp+tcp, 5061/tls). Digest auth on REGISTER *and* INVITE, pike flood-limiting, `htable` bans, TLS, in-dialog open-relay guard.
- **FreeSWITCH 1.11** — media, loopback-only, driven by the portal's `xml_curl` dialplan; bridges to carriers.
- **Laravel 12 portal** — carriers, tariffs/ratecards, DIDs, endpoints, customers/resellers, bundles, balances, CDRs, live-call + fail2ban monitoring dashboard. Prepaid credit gate, server-side rating, atomic idempotent billing.
- **Hardening baked in** — nftables (default-drop, per-source rate meters), fail2ban (SIP + web jails), sysctl anti-spoof, TLS everywhere, per-account concurrency + call-duration caps, high-risk-destination blocklist.

## Install (one command)

On a **fresh Debian 13 (trixie)** server, as root. Managed hosting and support for this stack are available from [DialerPortal](https://dialerportal.com).

```bash
curl -O https://raw.githubusercontent.com/dialerportal/dp-switch/main/install.sh
bash install.sh
```

It prompts for everything it needs, up front:

| Prompt | What it is |
|---|---|
| **Domain** | FQDN for the portal + SIP realm (e.g. `sbc.example.com`). Point its DNS `A` record at the server first. |
| **Email** | For the Let's Encrypt certificate + expiry notices. |
| **SignalWire token** | Free personal access token from [signalwire.com](https://signalwire.com) — FreeSWITCH 1.11 packages are gated behind it. |
| **Open SIP now?** | Whether to open 5060/5061/RTP to the public internet immediately (default: no — SIP stays restricted to trusted carrier/admin IPs until you're ready). |

The SignalWire token is entered hidden (not echoed). Non-interactive / unattended:

```bash
curl -O https://raw.githubusercontent.com/dialerportal/dp-switch/main/install.sh
bash install.sh --domain sbc.example.com --email you@example.com \
  --signalwire-token pt_XXXX --open-sip
```

**Safe to re-run.** If the install fails partway (a network blip, a bad token, DNS not ready), just run `bash install.sh` again on the same machine. It reuses the secrets it already generated (`/root/.dpswitch/install-credentials`), skips databases that are already loaded, keeps an existing certificate, and only redoes what's missing — so it converges instead of starting over.

## What it does

1. Adds the sury (PHP 8.3), Kamailio, and SignalWire (FreeSWITCH) apt repos and installs the stack.
2. **Generates every secret on the machine** — DB passwords, switch shared secret, ESL password, admin password — and writes them to `/root/.dpswitch/install-credentials` (root-only). Nothing sensitive ships in this repo.
3. Creates the `dpswitch_app` / `switch` / `switchcdr` / `kamailio` databases and loads the schema (structure only — no customer, carrier, or billing data).
4. Deploys the portal (`composer install`, `.env`, key, seeds the first admin).
5. Renders every server config from templates (your domain, the server's own public IP, the generated secrets) and applies firewall + hardening.
6. Obtains a Let's Encrypt certificate (self-signed fallback if DNS isn't live yet).

At the end it prints the portal URL and the generated admin login. For a walkthrough of the platform this installs, see [dialerportal.com](https://dialerportal.com).

## Where things land

| Path | What |
|---|---|
| `/opt/dp-switch` | This repo, cloned by the installer |
| `/var/www/dpswitch` | The Laravel portal |
| `/root/.dpswitch/install-credentials` | Generated secrets (0600, root-only) |
| `/etc/ssl/dpswitch` | Stable cert path read by nginx + Kamailio |
| `dpswitch-scheduler.timer`, `dp-stats.timer` | Scheduler tick + dashboard stats collector |
| `dpswitch-auth`, `dpswitch-probe`, `dpsip-auth`, `dpsip-scanner` | fail2ban jails |

## After install

If you would rather not run your own switch, [DialerPortal](https://dialerportal.com) offers the same stack as a managed service.

- **Log in and change the admin password immediately.**
- Add a carrier: `nft add element inet filter carrier_v4 { <carrier-ip> }` (and create it in the portal).
- Add your admin/office IP: `nft add element inet filter admin_v4 { <your-ip> }`.
- Extend the toll-fraud destination blocklist (`SWITCH_BLOCKED_PREFIXES` in the portal `.env`) to your own risk profile.
- If a self-signed cert was used, re-run `certbot certonly --webroot -w /var/www/html -d <domain>` once DNS resolves.

## Security notes

- This repository is public and contains **no** IP addresses, secrets, credentials, tokens, or customer/carrier data — only templates with `__PLACEHOLDER__` tokens the installer fills locally.
- Per-install secrets are generated fresh and never leave the target machine.
- FreeSWITCH's control socket (ESL) and external profile, MariaDB, and the switch API are loopback-only and firewalled; the portal login has nginx rate-limiting + app throttle + fail2ban.

## Brand assets

`portal/public/brand/` holds the [DialerPortal](https://dialerportal.com) mark used by the portal chrome. The marks are property of [DialerPortal](https://dialerportal.com); replace them if you deploy this under your own brand.

| File | Use |
|---|---|
| `dialerportal-logo.svg` | Horizontal lockup — sidebar and login card. Inherits `currentColor`, so it works on light and dark. |
| `dialerportal-icon.svg` | Square mark — browser tab icon. |
| `dialerportal-logo-256.png` | Raster mark — apple-touch-icon, README. |
| `portal/public/favicon.ico` | Fallback tab icon. |

Palette: ink `#0d1117`, accent `#64CEFB`, action `#0b6fa4`.

## Requirements

Fresh Debian 13 (trixie), root access, a domain with DNS pointing at the host, and a SignalWire token. ~2 vCPU / 2 GB RAM minimum.

---

<p align="center">
  Built and maintained by <a href="https://dialerportal.com"><strong>DialerPortal</strong></a> — VoIP billing, session border control and dialer infrastructure.
</p>

<p align="center">
  <a href="https://dialerportal.com">dialerportal.com</a> ·
  <a href="https://github.com/dialerportal/dp-switch">Source</a> ·
  <a href="https://github.com/dialerportal/dp-switch/issues">Report an issue</a> ·
  <a href="https://github.com/dialerportal/dp-switch/blob/main/install.sh">install.sh</a>
</p>
