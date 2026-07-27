#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Gebruik sudo bash tests/post-presentation-cache-test.sh" >&2; exit 1; }

SCRIPT=/opt/digitalsignage/scripts/sync-presentation-cache.py
[ -x "${SCRIPT}" ] || { echo "Cachescript ontbreekt of is niet uitvoerbaar." >&2; exit 1; }

for file in \
  /opt/digitalsignage/offline-player/index.html \
  /opt/digitalsignage/offline-player/slideshow.css \
  /opt/digitalsignage/offline-player/slideshow.js \
  /opt/digitalsignage/offline-fallback/index.html \
  /opt/digitalsignage/offline-fallback/offline.css; do
  [ -f "${file}" ] || { echo "Installatiebestand ontbreekt: ${file}" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/fixture" "${TMP}/cache"

cat > "${TMP}/fixture/presentation.json" <<'JSON'
{"title":"Fixture","slides":[{"objectId":"zichtbaar","slideProperties":{"isSkipped":false}},{"objectId":"verborgen","slideProperties":{"isSkipped":true}}]}
JSON

png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlYQAAAAASUVORK5CYII='
for id in zichtbaar verborgen; do
  printf '%s' "${png}" | base64 -d > "${TMP}/fixture/${id}.png"
done

cat > "${TMP}/config" <<'EOF'
CONTENT_MODE="presentation"
PRESENTATION_URL="https://docs.google.com/presentation/d/fixture/present"
PRESENTATION_CACHE_ENABLED=true
PRESENTATION_CACHE_INCLUDE_SKIPPED_SLIDES=false
EOF

"${SCRIPT}" \
  --config "${TMP}/config" \
  --cache-root "${TMP}/cache" \
  --player-dir /opt/digitalsignage/offline-player \
  --fallback-dir /opt/digitalsignage/offline-fallback \
  --fixture-dir "${TMP}/fixture"

python3 - "${TMP}/cache/cache-manifest.json" <<'PY'
import json
import sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert [slide["objectId"] for slide in manifest["slides"]] == ["zichtbaar"]
assert manifest["skippedSlideCount"] == 1
assert manifest["includeSkippedSlides"] is False
PY

cat > "${TMP}/config" <<'EOF'
CONTENT_MODE="website"
PRESENTATION_CACHE_ENABLED=true
EOF

"${SCRIPT}" \
  --config "${TMP}/config" \
  --cache-root "${TMP}/cache" \
  --player-dir /opt/digitalsignage/offline-player \
  --fallback-dir /opt/digitalsignage/offline-fallback

cmp -s /opt/digitalsignage/offline-fallback/index.html "${TMP}/cache/index.html"
test ! -f "${TMP}/cache/cache-manifest.json"

echo "Post-install presentation cache test OK."
