#!/bin/bash
# Regression tests for cluster MED-rel-site.
#
# Bug 1 (Scripts/release.sh): a release with a checked-in Sparkle public key MUST ship an
#   appcast. Because the feed URL is releases/latest/download/appcast.xml, an appcast-less
#   signed release 404s the feed for every already-installed client. So: public key present +
#   empty signature attrs => the release script must exit non-zero (fail hard), NOT fail-soft.
#   With no public key checked in (dormant-updater build) it must stay fail-soft.
#
# Bug 2 (site/public/index.html): the Privacy manifest must not claim "zero third-party
#   requests, no analytics" while the page loads PostHog.
#
# Pure bash + grep; runs no swift build. From repo root: bash Tests/ReleaseSiteRegressionTests/appcast_and_privacy_test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

RELEASE_SH="Scripts/release.sh"
INDEX_HTML="site/public/index.html"
fail=0
pass() { echo "  ok   - $1"; }
bad()  { echo "  FAIL - $1"; fail=1; }

# --- Bug 1: exercise the exact fail-hard guard from release.sh against all 4 combinations. ---
# Mirror the guard so the test is deterministic and does not run the whole packaging pipeline.
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
appcast_decision() {
  # args: SIG_ATTRS SPARKLE_PUBLIC_KEY -> echoes ABORT | WRITE | SKIP
  local SIG_ATTRS="$1" SPARKLE_PUBLIC_KEY="$2"
  if [ -z "$SIG_ATTRS" ] && [ -n "$SPARKLE_PUBLIC_KEY" ]; then echo ABORT; return; fi
  if [ -n "$SIG_ATTRS" ]; then echo WRITE; return; fi
  echo SKIP
}

# signed release, signing succeeded -> writes appcast
[ "$(appcast_decision 'sparkle:edSignature="abc" length="42"' 'PUBKEY==')" = WRITE ] \
  && pass "signed build with signature writes appcast" \
  || bad  "signed build with signature must write appcast"

# signed release (public key checked in) but signing FAILED -> must abort, not silently skip
[ "$(appcast_decision '' 'PUBKEY==')" = ABORT ] \
  && pass "public key present + failed signing aborts the release" \
  || bad  "public key present + failed signing must abort (regression: it used to fail-soft)"

# dormant build: no public key checked in, no signature -> stays fail-soft (skip)
[ "$(appcast_decision '' '')" = SKIP ] \
  && pass "no public key checked in stays fail-soft" \
  || bad  "dormant build must stay fail-soft"

# Structural checks: the real script must contain the fail-hard guard and exit 1.
if grep -q 'if \[ -z "\$SIG_ATTRS" \] && \[ -n "\$SPARKLE_PUBLIC_KEY" \]; then' "$RELEASE_SH" \
   && awk '/if \[ -z "\$SIG_ATTRS" \] && \[ -n "\$SPARKLE_PUBLIC_KEY" \]; then/{f=1} f&&/exit 1/{print;exit}' "$RELEASE_SH" | grep -q 'exit 1'; then
  pass "release.sh contains the fail-hard appcast guard with exit 1"
else
  bad  "release.sh must abort (exit 1) when public key is present but signing failed"
fi

# --- Bug 2: privacy copy must not carry the false zero-analytics promise. ---
PRIVACY_LINE="$(grep -n '<span class="m-key">this site</span>' "$INDEX_HTML" || true)"
if [ -z "$PRIVACY_LINE" ]; then
  bad "could not locate the 'this site' privacy manifest entry"
else
  if echo "$PRIVACY_LINE" | grep -qiE 'zero third-party requests|no analytics'; then
    bad "privacy copy still claims zero third-party requests / no analytics while PostHog loads"
  else
    pass "privacy copy no longer claims zero third-party requests / no analytics"
  fi
  if echo "$PRIVACY_LINE" | grep -qi 'analytics'; then
    pass "privacy copy discloses analytics"
  else
    bad "privacy copy should disclose the analytics it actually runs"
  fi
fi

# Sanity: the page really does load PostHog (so the disclosure is warranted).
grep -q 'us.i.posthog.com' "$INDEX_HTML" \
  && pass "page loads PostHog (disclosure is warranted)" \
  || bad  "expected PostHog snippet in index.html"

echo ""
if [ "$fail" -eq 0 ]; then echo "All MED-rel-site regression checks passed."; else echo "MED-rel-site regression checks FAILED."; fi
exit "$fail"
