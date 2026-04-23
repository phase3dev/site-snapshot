<p align="center">
  <img src="./.assets/ss-icon.png" srcset="./.assets/ss-icon@2x.png 2x" alt="Site Snapshot icon" width="128">
</p>

# Site Snapshot

A bash script for mirroring and creating recursive snapshots of static and semi-static websites using `wget`. Features include dynamic proxy and user agent rotation, full asset filtering and download, adjustable concurrency, multi-domain support, depth control, optional offline link conversion, archive creation, and detailed logging.

Designed to clone static templates, theme repositories, marketing pages, and other sites where HTML and assets are present in the server response. Useful for pulling styles, scripts, and media for local development (e.g., reusable blocks and components), preserving asset structure for inspection and adaptation, and archiving site sections for offline browsing or migration work.

## Note: Static sites vs. JavaScript apps

At its core, Site Snapshot is a controlled wrapper around `wget` that adds practical features such as proxy and user-agent rotation, scope management, logging, and state tracking.

It includes a fallback discovery pass that may sometimes recover additional URLs from embedded content, but **it is not a browser crawler or scraper framework.** If the target site is primarily a JavaScript-rendered app, an SPA-only site, or relies on tabbed, virtualized, or lazy-loaded routes, a browser-capable crawler such as Playwright, Puppeteer, Crawlee, or Selenium will be necessary.

## Features

- **Rotating proxies.** Load proxies from `proxies.txt`, point to another file with `--proxies FILE`, or pass inline values with repeated `--proxy URL`. Randomly selects a proxy on every request, rotating again on retry.
- **Rotating user agents.** Load user agents from `user_agents.txt`, point to another file with `--user-agents FILE`, or pass inline values with repeated `--user-agent STRING`. Randomly selects a user agent on every request and retry.
- **Recursive mirroring with `wget`.** Uses `wget` for the core mirror pass.
- **Full asset download.** Grabs page requisites by default so mirrored pages render locally.
- **Optional offline link conversion.** `--convert-links` rewrites local links for easier offline browsing.
- **Fallback discovery pass.** Scans downloaded HTML for additional in-scope URLs and feeds them back into `wget`.
- **Path scoping for discovered URLs.** `--scope-prefixes` prevents discovery from exploding outside the section you care about.
- **Asset filtering.** Use `--no-assets`, `--reject`, or `--accept`.
- **Retry support.** Retries failed requests with rotated proxy and user agent.
- **Randomized delays.** Configurable fixed or ranged delays.
- **Adjustable concurrency.** Parallel top-level URL jobs, not browser-style internal request concurrency.
- **Depth control.** Unlimited by default, or cap with `--depth`.
- **Multi-domain support.** Follow only the domains you allow.
- **Zip packaging.** Optional archive creation at the end.
- **Logging and state tracking.** Logs to `snapshot.log` and stores visited/discovered URL lists in `.snapshot_state/`.

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/phase3dev/site-snapshot.git
cd site-snapshot

# 2. Make it executable
chmod +x snapshot.sh

# 3. Run it
./snapshot.sh --url https://example.com
```

Output lands in `./snapshot_output/example.com/` by default.

## Proxies and user agents

Adding proxies and user agents is optional. If no proxy list or file is found, requests go out on your own IP with a warning. If no user agent list or file is found, a default user agent string is used.

For small sites or sites you own, this should work fine. For larger or third-party sites, rotating proxies and a diverse user agent list help avoid rate limiting.

The script supports both file-based and inline proxy/user-agent input.

## Proxy input formats

### 1. File-based

`proxies.txt` supports values accepted by `wget` through proxy environment variables. For example:

```text
http://host:port
http://user:password@host:port
socks5://user:password@host:port
```

Blank lines and lines beginning with `#` are ignored.

### 2. Inline CLI values

Repeat `--proxy` as needed:

```bash
./snapshot.sh \
  --url https://example.com \
  --proxy http://host1:port \
  --proxy http://user:password@host2:port
```

## User-agent input formats

### 1. File-based

`user_agents.txt` should contain one user-agent string per line. Blank lines and lines beginning with `#` are ignored.

Example:

```text
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36
Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0
```

### 2. Inline CLI values

Repeat `--user-agent` as needed:

```bash
./snapshot.sh \
  --url https://example.com \
  --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
  --user-agent "Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0"
```

### Combining inline and file-based proxies and user agents

The script supports concurrent use of file-based and inline proxy/user-agent sources:

```bash
./snapshot.sh \
  --url https://example.com \
  --proxies /path/to/proxies.txt \
  --proxy http://extra-proxy.example.com:8080 \
  --user-agents /path/to/user_agents.txt \
  --user-agent "Mozilla/5.0 custom test agent"
```

### Location of proxy and user agent files

By default, the script looks for `proxies.txt` and `user_agents.txt` in the same directory as `snapshot.sh`. You can also point to files elsewhere with the `--proxies` and `--user-agents` flags:

```bash
./snapshot.sh -u https://example.com --proxies /path/to/my_proxies.txt --user-agents /path/to/my_uas.txt
```

### Generating new proxy and user agent files

In addition to using pre-existing external files, you can also create new  `proxies.txt` and `user_agents.txt` files through inline CLI:

#### `proxies.txt`

```bash
cat > proxies.txt << 'EOF'
http://user:pass@proxy1.example.com:8080
http://user:pass@proxy2.example.com:8080
socks5://user:pass@proxy3.example.com:1080
EOF
```

#### `user_agents.txt`

```bash
cat > user_agents.txt << 'EOF'
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0
Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0
EOF
```

## Usage

```bash
./snapshot.sh [OPTIONS]
```

### Required

```text
-u, --url URL
    Target URL to mirror
```

### Optional

```text
-d, --domains DOMAINS
    Comma-separated domains to follow.
    Default: extracted from --url.
    Accepts bare domains or full URLs. Schemes and paths are stripped.

-o, --output DIR
    Output directory.
    Default: ./snapshot_output/<domain>

-r, --retries N
    Max retries per URL on failure.
    Default: 5

-c, --concurrency N
    Max parallel top-level URL jobs.
    Default: random value between 2 and 8

-w, --wait N [MAX]
    Delay in seconds.
    One value = fixed delay.
    Two values = random range.
    Default: 1 3

--depth N
    Recursion depth for wget.
    0 = unlimited.
    Default: unlimited

--no-assets
    Skip downloading page assets

--reject TYPES
    Comma-separated file extensions to reject

--accept TYPES
    Comma-separated file extensions to accept

--convert-links
    Convert local links for better offline browsing

--discover-off
    Disable fallback discovery pass

--discover-passes N
    Number of fallback discovery passes.
    Default: 2

--discover-limit N
    Maximum number of new discovered URLs to attempt per pass.
    Default: 2000

--scope-prefixes PREFIXES
    Optional comma-separated path prefixes to keep discovery in scope.
    Example: /docs,/blog

--no-zip
    Skip zip archive creation

--robots-on
    Respect robots.txt

--proxies FILE
    Path to proxy list file.
    Default: proxies.txt in the script directory

--proxy URL
    Inline proxy value.
    Repeat this option to provide multiple proxies.

--user-agents FILE
    Path to user-agent list file.
    Default: user_agents.txt in the script directory

--user-agent STRING
    Inline user-agent value.
    Repeat this option to provide multiple user agents.

-h, --help
    Show help
```

## Examples

Mirror a basic static site:

```bash
./snapshot.sh --url https://example.com
```

Mirror a docs section and improve local browsing:

```bash
./snapshot.sh \
  --url https://docs.example.com/guide/ \
  --domains docs.example.com,cdn.example.com \
  --convert-links
```

Mirror a site section and keep fallback discovery inside known paths:

```bash
./snapshot.sh \
  --url https://example.com/docs/ \
  --domains example.com \
  --scope-prefixes /docs,/assets/docs
```

Mirror HTML while skipping large media:

```bash
./snapshot.sh \
  --url https://example.com \
  --reject mp4,mov,avi,mkv,zip,pdf
```

Use inline proxies and inline user agents for a one-off run:

```bash
./snapshot.sh \
  --url https://example.com \
  --proxy http://user:pass@proxy1.example.com:8080 \
  --proxy socks5://proxy2.example.com:1080 \
  --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
  --user-agent "Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0"
```

Slow and polite:

```bash
./snapshot.sh \
  --url https://example.com \
  --wait 5 10 \
  --concurrency 2 \
  --robots-on
```

Disable fallback discovery entirely:

```bash
./snapshot.sh \
  --url https://example.com \
  --discover-off
```

## How fallback discovery works

After the initial `wget` pass, the script can scan downloaded HTML files and extract additional candidate URLs from raw page content.

This can be helpful with semi-static docs sites and other sites that do not expose all routes as normal `<a href="...">` links but still embed them somewhere in HTML, JSON, canonical metadata, preload hints, or inline script/config blobs.

The discovery pass:

1. scans mirrored HTML files
2. extracts candidate URLs and root-relative paths
3. normalizes and deduplicates them
4. filters them to your allowed domains and optional scope prefixes
5. feeds them back into `wget` for additional passes

## Troubleshooting

### Styles or assets are missing

This is usually a domain issue.

Many sites serve HTML from one domain and assets from another, such as a CDN or parent domain. Add every required asset domain to `--domains`.

Example:

```bash
./snapshot.sh \
  --url https://themes.example.com \
  --domains themes.example.com,example.com,cdn.example.com
```

### The script used the wrong domains from `--domains`

The script supports passing either bare domains or full URLs and will normalize them. All of these are accepted:

```bash
--domains example.com,cdn.example.com
--domains https://example.com/docs/,https://cdn.example.com/assets/
```

### The script downloaded only one page

Usually one of these is true:

1. The site is a JS-heavy app and does not expose crawlable links in raw HTML
2. The `--domains` list is too narrow
3. The `--scope-prefixes` are too restrictive
4. The page really is a single giant HTML document

Potential fixes:

- Inspect the downloaded HTML and search for internal URLs
- Broaden `--domains` if assets or pages live on other allowed domains
- Remove or widen `--scope-prefixes`
- Increase `--discover-passes`

## File structure

```text
site-snapshot/
├── snapshot.sh
├── proxies.txt
├── user_agents.txt
├── README.md
└── snapshot_output/
    └── example.com/
        ├── snapshot.log
        └── .snapshot_state/
            ├── visited_urls.txt
            ├── discovered_urls.txt
            └── seed_urls.txt
```

## Responsible use

Please respect website owners and their terms of service.

- Check robots.txt before mirroring
- Use polite settings when mirroring sites you do not own
- Do not redistribute copyrighted mirrored content unless you have the proper permissions

## Requirements

- bash 4+
- wget
- zip (optional)
- proxy list (optional)
- user-agent list (optional)

## License

MIT
