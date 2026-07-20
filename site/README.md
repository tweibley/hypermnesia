# hypermnesia.app

The marketing site — a single static page served from Cloudflare Workers static assets.

- `public/` — everything that ships: `index.html`, `style.css`, self-hosted fonts
  (`fonts/`, latin subsets of Instrument Serif + IBM Plex Sans/Mono), and `media/`
  (copied from `../docs/media/`; `og.jpg` is a compressed `social-preview.png`).
- `wrangler.jsonc` — Workers config; binds the `hypermnesia.app` and
  `www.hypermnesia.app` custom domains (DNS + certs are created automatically since
  the zone is on the same Cloudflare account).

The page self-hosts its fonts and makes a single third-party request: privacy-friendly
PostHog page analytics (no memory content ever leaves the device, and the app itself sends
zero telemetry). Keep that boundary — it's part of the local-first pitch and is disclosed
in the page's Privacy section.

## Deploy

```bash
cd site
wrangler login     # once
wrangler deploy
```

## Preview locally

```bash
cd site && wrangler dev     # or: python3 -m http.server -d public 8788
```

When README media is regenerated (`docs/media/`), re-copy `replay.gif` and
`share-card.png` into `public/media/` and rebuild `og.jpg`:

```bash
sips -s format jpeg -s formatOptions 82 docs/media/social-preview.png --out site/public/media/og.jpg
```
