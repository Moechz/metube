#!/bin/bash
# ===========================================================================
# Build BOTH architectures required by the TOS store (default policy).
# ===========================================================================
# TOS accepts one package per architecture; the package file name must carry
# the architecture suffix, and the two packages are submitted as two App
# records with the same app_id but different `platform`.
#
# `scripts/build.sh` cleans out/ on every run and writes the unsuffixed
# `out/<appid>.tar.gz`, so this wrapper preserves each architecture outside
# out/ while the other one is being built, then restores both suffixed assets.
#
# Usage: scripts/build-dual.sh [version]
#        (default: the version currently in tosapp.json)
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

APPID="$(python3 -c "import json;print(json.load(open('tosapp.json'))['app_id'])")"
VER="${1:-$(python3 -c "import json;print(json.load(open('tosapp.json'))['version'])")}"
TOOL="$HERE/TOSAppSelfTestingTool"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== build ${APPID} ${VER} (aarch64)"
scripts/build.sh "$VER" aarch64
cp "out/${APPID}.tar.gz" "$TMP/${APPID}_aarch64.tar.gz"
( cd "$TMP" && sha256sum "${APPID}_aarch64.tar.gz" > "${APPID}_aarch64.tar.gz.sha256" )

echo "== build ${APPID} ${VER} (x86_64, canonical)"
scripts/build.sh "$VER" x86_64
cp "out/${APPID}.tar.gz" "out/${APPID}_x86_64.tar.gz"
( cd out && sha256sum "${APPID}_x86_64.tar.gz" > "${APPID}_x86_64.tar.gz.sha256" )
cp "$TMP/${APPID}_aarch64.tar.gz" "$TMP/${APPID}_aarch64.tar.gz.sha256" out/

echo "== official check (both architectures)"
for f in "out/${APPID}_x86_64.tar.gz" "out/${APPID}_aarch64.tar.gz"; do
    if [ -x "$TOOL" ]; then
        "$TOOL" -c "$f"
    else
        echo "WARN: $TOOL not executable; skipping official check for $f"
    fi
done

echo "== dual-arch assets"
ls -lh "out/${APPID}_x86_64.tar.gz" "out/${APPID}_x86_64.tar.gz.sha256" \
       "out/${APPID}_aarch64.tar.gz" "out/${APPID}_aarch64.tar.gz.sha256"
sha256sum "out/${APPID}_x86_64.tar.gz" "out/${APPID}_aarch64.tar.gz"
