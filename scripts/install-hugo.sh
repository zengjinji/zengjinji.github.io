#!/usr/bin/env bash
set -euo pipefail
BLOG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUGO_VERSION="$(tr -d '[:space:]' < "$BLOG_ROOT/.hugo-version")"
HUGO_BIN="$BLOG_ROOT/.tools/hugo"
if [[ -x "$HUGO_BIN" ]] && "$HUGO_BIN" version | grep -Fq "v${HUGO_VERSION}-"; then
  exit 0
fi
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) HUGO_PLATFORM=linux-amd64 ;;
  Linux/aarch64) HUGO_PLATFORM=linux-arm64 ;;
  Darwin/x86_64) HUGO_PLATFORM=darwin-universal ;;
  Darwin/arm64) HUGO_PLATFORM=darwin-universal ;;
  *) echo 'Unsupported platform; install the version in .hugo-version manually.' >&2; exit 1 ;;
esac
HUGO_ARCHIVE="hugo_${HUGO_VERSION}_${HUGO_PLATFORM}.tar.gz"
HUGO_DOWNLOAD="https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}"
BLOG_PROXY="${BLOG_PROXY-http://172.20.10.1:1082}"
CURL_OPTIONS=(--fail --location --retry 2 --connect-timeout 15 --max-time 180)
if [[ -n "$BLOG_PROXY" ]]; then CURL_OPTIONS+=(--proxy "$BLOG_PROXY"); fi
HUGO_TEMP="$(mktemp -d)"
trap 'rm -rf "$HUGO_TEMP"' EXIT
curl "${CURL_OPTIONS[@]}" "$HUGO_DOWNLOAD/$HUGO_ARCHIVE" -o "$HUGO_TEMP/$HUGO_ARCHIVE"
curl "${CURL_OPTIONS[@]}" "$HUGO_DOWNLOAD/hugo_${HUGO_VERSION}_checksums.txt" -o "$HUGO_TEMP/checksums.txt"
awk -v archive="$HUGO_ARCHIVE" '$2 == archive { print; found=1 } END { if (!found) exit 1 }' "$HUGO_TEMP/checksums.txt" > "$HUGO_TEMP/selected-checksum.txt"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$HUGO_TEMP" && sha256sum --check selected-checksum.txt)
else
  (cd "$HUGO_TEMP" && shasum -a 256 --check selected-checksum.txt)
fi
mkdir -p "$BLOG_ROOT/.tools"
tar -xzf "$HUGO_TEMP/$HUGO_ARCHIVE" -C "$HUGO_TEMP" hugo
install -m 755 "$HUGO_TEMP/hugo" "$HUGO_BIN"
"$HUGO_BIN" version
