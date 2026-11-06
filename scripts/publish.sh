#!/usr/bin/env bash
set -euo pipefail
BLOG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BLOG_ROOT"
if [[ "$(git branch --show-current)" != main ]]; then
  echo 'Please switch to main before publishing.' >&2
  exit 1
fi
./scripts/hugo.sh --gc --minify --panicOnWarning
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit your changes before publishing:' >&2
  echo '  git add <files>' >&2
  echo '  git commit -m "Update blog"' >&2
  exit 1
fi
BLOG_PROXY="${BLOG_PROXY-http://172.20.10.1:1082}"
if [[ -n "$BLOG_PROXY" ]]; then
  git -c "http.proxy=$BLOG_PROXY" -c "https.proxy=$BLOG_PROXY" push origin main
else
  git push origin main
fi
