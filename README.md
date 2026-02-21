# cgit-looking-glass

A looking glass into your git repos — cgit on a tiny VPS, zero open ports.

```
Internet -> Cloudflare -> [tunnel] -> Anubis (127.0.0.1:8923) -> lighttpd (127.0.0.1:8080) -> cgit.cgi
```

- Zero public ports — all HTTP traffic via Cloudflare Tunnel (outbound-only)
- Modern dark + light theme (system preference + manual toggle)
- Anubis proof-of-work challenge to block AI scrapers (same as kernel.org)
- lighttpd for minimal memory footprint with native CGI (no fcgiwrap)
- cgit disk cache with aggressive TTLs — Cloudflare + Anubis handle the heavy lifting
- Adaptive tuning — auto-detects RAM and adjusts cache sizes, creates swap on low-memory boxes
- fail2ban, ufw, sysctl hardening

Designed for VPS as small as 256 MB RAM / 1 vCPU.

## Quick start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ssmirr/cgit-looking-glass/master/quick-install.sh)"
```

The wizard walks you through domain, owner, tunnel token, etc. Hit Enter to accept defaults.

For fully non-interactive setup, set environment variables and pass `--yes`:

```bash
export CGIT_DOMAIN="git.example.com"
export CGIT_OWNER="yourname"
export CLOUDFLARE_TUNNEL_TOKEN="eyJ..."
sudo -E /opt/cgit-setup/setup.sh --yes
```

## Detailed setup

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `CGIT_DOMAIN` | `git.example.com` | Your domain |
| `CGIT_REPOS_DIR` | `/srv/git` | Where bare repos live |
| `CGIT_OWNER` | `admin` | Displayed owner name |
| `CGIT_SITE_TITLE` | `git` | Page title |
| `CGIT_CLONE_PREFIX` | `https://$DOMAIN` | Clone URL prefix |
| `CGIT_CACHE_SIZE` | `2000` | Max cached pages (auto-tuned by RAM) |
| `CGIT_ANUBIS_DIFFICULTY` | `4` | PoW difficulty (raise if under attack) |
| `CLOUDFLARE_TUNNEL_TOKEN` | *(none)* | Tunnel token for automated setup |

### Cloudflare Tunnel

The tunnel connects Cloudflare's edge to your VPS. Nothing listens on any public port — `cloudflared` opens an outbound connection to Cloudflare.

**Option A: Token from dashboard** (recommended for headless servers)

1. Go to **Cloudflare Dashboard -> Zero Trust -> Networks -> Tunnels**
2. Create a tunnel named `cgit`
3. Add a **public hostname**: `git.example.com` -> `http://127.0.0.1:8923`
4. Copy the tunnel token
5. Either set `CLOUDFLARE_TUNNEL_TOKEN` before running `setup.sh`, or run `cloudflared service install <TOKEN>` after setup

**Option B: CLI login** (interactive)

```bash
cloudflared tunnel login
cloudflared tunnel create cgit
```

Create `/etc/cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: git.example.com
    service: http://127.0.0.1:8923
  - service: http_status:404
```

Then add the DNS route and start:

```bash
cloudflared tunnel route dns cgit git.example.com
systemctl enable --now cloudflared
```

## Mirror a GitHub repo

```bash
sudo cgit-mirror https://github.com/user/repo "Short description"
```

Initial clone requires root (to `chown` to the git user). Subsequent updates run as the `git` user automatically via cron.

Mirrors sync every 30 minutes. Force a sync:

```bash
cgit-sync-all
```

## Architecture

```
┌──────────┐     ┌─────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────┐
│ Internet │────▶│ Cloudflare  │──╌──▶│ Anubis           │────▶│ lighttpd         │────▶│ cgit │
│          │     │ CDN + DDoS  │tunnel│ 127.0.0.1:8923   │     │ 127.0.0.1:8080   │     │ CGI  │
│          │     │ TLS         │  ╌──▶│ PoW gate         │     │ cache headers    │     │      │
└──────────┘     └─────────────┘     └──────────────────┘     └──────────────────┘     └──────┘
                        │
                   cloudflared
                 (outbound-only)
```

### What's exposed to the internet?

**Nothing.** There are zero listening ports on the VPS (besides SSH).

`cloudflared` opens an outbound-only persistent connection to Cloudflare's edge network. Cloudflare routes incoming requests through this tunnel. An attacker who discovers your VPS IP sees only a closed SSH port — no HTTP, no 8923, no 8080. There is no way to reach Anubis, lighttpd, or cgit without going through Cloudflare.

### Why this stack?

| Layer | Purpose | Memory | Listens on |
|---|---|---|---|
| **Cloudflare** | CDN, DDoS, TLS termination, edge caching | 0 (external) | edge |
| **cloudflared** | Outbound tunnel to Cloudflare edge | ~20-30 MB | outbound only |
| **Anubis** | Blocks AI scrapers via proof-of-work | ~50-128 MB | 127.0.0.1:8923 |
| **lighttpd** | Serves cgit CGI + static assets | ~1-3 MB | 127.0.0.1:8080 |
| **cgit** | Renders git repos as HTML | on-demand | — |

Total origin footprint: ~80-170 MB depending on traffic.

## Cloudflare configuration

| Setting | Value |
|---|---|
| SSL/TLS | Full |
| Always Use HTTPS | On |
| Minimum TLS Version | 1.2 |
| Browser Cache TTL | Respect Existing Headers |
| Caching Level | Standard |

SSL mode is "Full" (not "Full (Strict)") because the tunnel connection from Cloudflare to your origin is already encrypted and authenticated by `cloudflared` — no origin certificate needed.

### Edge caching of HTML pages

lighttpd sets `Cache-Control`, `s-maxage`, and `CDN-Cache-Control` headers on all cgit responses so Cloudflare caches HTML pages at the edge — not just static assets.

| Page type | Edge TTL | Why |
|---|---|---|
| Static assets (CSS/JS/SVG) | 30 days | Immutable, cache-bust via query string |
| Snapshot downloads | 24 hours | Immutable archives |
| Commit, tree, blob, diff | 1 hour | Content never changes for a given hash |
| Log, refs, summary, index | 5 min | Changes on mirror sync |
| Other CGI responses | 2 min | Safe fallback |

The vast majority of traffic is served from Cloudflare's edge. Your origin only gets hit on cache misses.

Create a Cloudflare Cache Rule:
- **When**: hostname equals `git.example.com`
- **Then**: Cache eligibility = **Eligible for cache**, Respect origin cache headers

## Theme

Uses `prefers-color-scheme` by default. Manual toggle:
- Click the button in the bottom-right corner
- Press `t` on your keyboard

Preference is saved in `localStorage`.

## RAM auto-tuning

| RAM | Swap | cgit cache entries |
|---|---|---|
| < 384 MB | 512 MB created | 500 |
| 384-511 MB | 512 MB created | 1000 |
| 512+ MB | none | 2000 |

## Security

The tunnel architecture means **zero attack surface** from the network:

- **Cloudflare Tunnel**: no public ports, outbound-only connection, no IP exposure
- **Anubis**: proof-of-work challenge blocks bots before they touch cgit
- **ufw**: deny all incoming except SSH
- **fail2ban**: SSH brute-force protection
- **sysctl**: SYN cookies, no redirects, rp_filter, low swappiness
- **lighttpd**: binds to 127.0.0.1 only — unreachable from outside
- **Anubis**: binds to 127.0.0.1 only — unreachable from outside
- **Security headers**: X-Content-Type-Options, X-Frame-Options, Referrer-Policy
- **git user**: locked to git-shell (no login)
- **Anubis systemd**: hardened with NoNewPrivileges, ProtectSystem, MemoryMax
- **Logrotate**: sync logs rotated weekly

Even if someone discovers your VPS IP (e.g., from historical DNS records), they can't reach any HTTP service. The only possible attack vector is SSH, which is protected by fail2ban and key-only auth (which you should configure).

## Bot policies

The included `botPolicies.yaml` is tuned for a public git host:

- **Allow**: Googlebot, Bingbot, DuckDuckBot, Internet Archive
- **Deny**: AI scrapers (GPTBot, CCBot, ClaudeBot, Bytespider, etc.), vulnerability scanners, empty user agents
- **Challenge**: everything else (browsers solve instantly)

Edit `/etc/anubis/cgit.botPolicies.yaml` to customize.

## File structure

```
.
├── setup.sh                    # Main setup script (run as root)
├── cgitrc.template             # cgit config template
├── lighttpd/
│   └── cgit.conf               # lighttpd CGI + cache headers
├── anubis/
│   ├── cgit.env                # Anubis env config template
│   ├── botPolicies.yaml        # Bot allow/deny/challenge rules
│   └── anubis@.service         # systemd template unit (fallback)
└── theme/
    ├── cgit.css                # Full theme — dark + light mode
    ├── cgit.js                 # Theme toggle + keyboard shortcut
    ├── header.html             # Injected into <head>
    ├── footer.html             # Loads JS before </body>
    └── favicon.svg             # Simple git icon
```

## Requirements

- Debian 12 or Ubuntu 22.04+
- Root access
- Domain pointed at Cloudflare (proxied)
- Cloudflare account (free tier works)

## License

This project is licensed under the GNU General Public License v3.0 — see the
[LICENSE](LICENSE) file for details.
