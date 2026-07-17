# Media assets

Everything here is rendered from `SampleMemories` — never from a real memory store — by the share
preview harness:

```bash
HYPERMNESIA_SHARE_PREVIEW_DIR=/tmp/share-preview swift run HypermnesiaApp
```

| File | Source | Used for |
|---|---|---|
| `replay.gif` | `replay.gif` (verbatim) | README hero |
| `share-card.png` | `share-card-wide.png`, downscaled (`sips -Z 1600`) | README "How it works" |
| `social-preview.jpg` | `share-card-social.png` (2:1), JPEG q85 (GitHub caps the upload at 1 MB) | GitHub **Settings → General → Social preview** — upload it there so shared links unfurl into the card |

Regenerate after any share-chrome change so the README never drifts from what the app actually
exports.
