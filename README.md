# wget-site-mirror

A fast, simple bash script for cloning websites using `wget` with rotating proxies and user agents.

## What it does

`mirror.sh` recursively downloads a website, including associated assets such as CSS, JavaScript, images, and fonts, while preserving the original directory structure. It is designed as a website mirroring tool, not a scraper. It does not use browser automation, headless Chrome, or bot-bypass trickery. It is simply reliable, time-tested `wget`, with a few practical enhancements.

Browser automation tools (Puppeteer, Playwright, Selenium) are overkill for mirroring static or semi-static sites. `wget` is fast, lightweight, and available on virtually every Linux/macOS system. By rotating proxies and user agents and adding randomized delays, this script avoids the most common blocking mechanisms without resorting to anything exotic. In practice, with reasonable settings, it rarely gets blocked, even on larger sites.

## Features

- **Rotating proxies.** Randomly selects a proxy from `proxies.txt` on every request, rotating again on retry.
- **Rotating user agents.** Randomly selects a user agent from `user_agents.txt` on every request.
- **Full asset download.** Grabs page requisites (images, stylesheets, scripts, fonts) by default so cloned pages render correctly offline.
- **Customizable asset filtering.** Skip asset types with `--no-assets`, or use `--reject` / `--accept` to block or allow specific file extensions (e.g., `--reject mp4,pdf,zip`).
- **Retry with rotation.** Automatically retries on HTTP 403/429 with a fresh proxy and user agent.
- **Randomized delays.** Configurable random wait between requests to avoid hammering servers.
- **Adjustable concurrency.** Set a fixed number of parallel `wget` processes or let the script pick randomly (2 to 8).
- **Recursive depth control.** Unlimited recursion by default, or set `--depth N` to limit.
- **Multi-domain support.** Follow links across subdomains or related domains with `--domains`.
- **Auto-zip.** Optionally archives the output when done (disable with `--no-zip`).
- **Logging.** All output is timestamped and tee'd to a log file in the output directory.
- **Single file, no dependencies.** Pure bash + `wget` + `zip`. Nothing to install.

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/youruser/wget-mirror.git
cd wget-mirror

# 2. Add your proxies (one per line)
cat > proxies.txt << 'EOF'
http://user:pass@proxy1.example.com:8080
http://user:pass@proxy2.example.com:8080
socks5://user:pass@proxy3.example.com:1080
EOF

# 3. Add user agent strings (one per line)
cat > user_agents.txt << 'EOF'
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0
Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0
EOF

# 4. Run it
chmod +x mirror.sh
./mirror.sh --url https://example.com
```

Output lands in `./mirror_output/example.com/` by default.

## Usage

```
./mirror.sh [OPTIONS]

Required:
  -u, --url URL             Target URL to mirror

Optional:
  -d, --domains DOMAINS     Comma-separated domains to follow (default: extracted from URL)
  -o, --output DIR          Output directory (default: ./mirror_output/<domain>)
  -r, --retries N           Max retries per URL on failure (default: 5)
  -c, --concurrency N       Max concurrent wget processes (default: random 2-8)
  -w, --wait N [MAX]        Delay in seconds: one value = fixed, two = random range (default: 1 3)
  --depth N                 Recursion depth (0 = unlimited, default: unlimited)
  --no-assets               Skip downloading page assets (images, CSS, JS)
  --reject TYPES            Comma-separated extensions to reject (e.g., mp4,pdf,zip)
  --accept TYPES            Comma-separated extensions to accept (download only these)
  --no-zip                  Skip creating zip archive after download
  --robots-on               Respect robots.txt (see note below)
  --proxies FILE            Path to proxy list file (default: proxies.txt in script dir)
  --user-agents FILE        Path to user agent list file (default: user_agents.txt in script dir)
  -h, --help                Show help
```

## Examples

Mirror a subdomain, including assets hosted on the parent domain:
```bash
./mirror.sh -u https://docs.example.com -d docs.example.com,example.com
```

Mirror a site with assets spread across multiple domains:
```bash
./mirror.sh -u https://themes.example.com -d themes.example.com,example.com,cdn.example.com
```

Mirror HTML only, skip large media files:
```bash
./mirror.sh -u https://example.com --reject mp4,mov,avi,mkv,zip,tar.gz,pdf
```

Shallow clone (2 levels deep), no zip:
```bash
./mirror.sh -u https://example.com --depth 2 --no-zip
```

Slow and polite (5 to 10 second delays, 2 concurrent):
```bash
./mirror.sh -u https://example.com -w 5 10 -c 2 --robots-on
```

## File structure

```
wget-mirror/
├── mirror.sh           # The script
├── proxies.txt         # Your proxy list, one per line (optional)
├── user_agents.txt     # Your user agent strings, one per line (optional)
├── README.md
└── mirror_output/      # Created automatically
    └── example.com/    # Mirrored site files
        └── mirror.log  # Timestamped log
```

## Proxy format

`proxies.txt` supports any format `wget` accepts via the `https_proxy` / `http_proxy` environment variables:

```
http://host:port
http://user:password@host:port
socks5://user:password@host:port
```

Residential or datacenter proxies both work. The script rotates to a new proxy on every request and on every retry, so a larger pool reduces the chance of any single IP getting flagged.

## Proxies and user agents

Both files are **optional**. The script works fine without either one. That said, there will be a much greater chance of being blocked without using one or both options.

By default, the script looks for `proxies.txt` and `user_agents.txt` in the same directory as `mirror.sh`. You can point to files elsewhere with the `--proxies` and `--user-agents` flags:

```bash
./mirror.sh -u https://example.com --proxies /path/to/my_proxies.txt --user-agents /path/to/my_uas.txt
```

If no proxy file is found, requests go out on your own IP with a warning. If no user agent file is found, a default Chrome user agent string is used. This means the simplest possible invocation is just:

```bash
./mirror.sh -u https://example.com
```

No extra files needed. For small sites or sites you own, this is perfectly fine. For larger or third-party sites, you'll want proxies and a diverse user agent list to avoid getting rate-limited.

## How it avoids blocks

This script is intentionally simple by design. This is not a stealth tool and does not attempt to defeat sophisticated bot protection (Cloudflare turnstile, Akamai Bot Manager, etc.). It works well against basic rate limiting and IP-based blocking due to:

1. **Proxy rotation.** Each request can come from a different IP.
2. **User agent rotation.** No single fingerprint pattern.
3. **Randomized delays.** Requests don't arrive in a machine-like cadence.
4. **No cookies/keep-alive.** Each request is stateless, reducing fingerprinting surface.

## Missing styles or broken assets after cloning

This is the most common issue people run into, and it's almost always a domain problem.

Many sites serve their HTML from one domain but load CSS, JS, images, and fonts from a different domain or subdomain. For example, you might be cloning `themes.example.com`, but the stylesheets are hosted on `cdn.example.com` or even just `example.com`. By default, `wget --no-parent` restricts downloads to the domain in your `--url`, so those cross-domain assets get skipped and you end up with unstyled pages.

**The fix:** use `--domains` to include every domain the site loads assets from.

```bash
# You want to clone themes.example.com, but assets live on example.com and cdn.example.com
./mirror.sh -u https://themes.example.com -d themes.example.com,example.com,cdn.example.com
```

**How to figure out which domains you need:**

1. Open the site in a browser and open DevTools (F12)
2. Go to the Network tab and reload the page
3. Look at the domains in the request list. You'll see where CSS, JS, fonts, and images are coming from.
4. Add all of those domains to your `--domains` list

Alternatively, clone the site first, open the local HTML files, and check whether the styling loads. If pages look unstyled or broken, view the page source, find the `<link>` and `<script>` tags, and note what domains they reference. Then re-run with those domains added.

This pattern of setting `--url` to the subdomain or subfolder you want and then broadening `--domains` to include the parent or CDN domain is the intended workflow for partial site clones.

## Responsible use

**Please respect website owners and their terms of service.**

- **Check robots.txt** before mirroring. The script disables robots.txt by default for flexibility, but you should review it manually and consider using `--robots-on` if the site's robots.txt is reasonable.
- **Don't mirror sites you don't have permission to clone** for redistribution or commercial use.
- **Use polite settings.** Increase delay intervals, reduce concurrency, and respect rate limits for sites you don't own.
- **This script is provided as-is for legitimate use cases like local development reference, offline browsing, archival, and site migration.** Redistributing copyrighted content you've mirrored is your responsibility, not the tool's.

## Requirements

- `bash` 4+
- `wget`
- `zip` (optional, for auto-archiving)
- A proxy list (optional but recommended)

## License

MIT
