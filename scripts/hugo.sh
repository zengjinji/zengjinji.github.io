#!/usr/bin/env bash
set -euo pipefail
BLOG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$BLOG_ROOT/scripts/install-hugo.sh"
cd "$BLOG_ROOT"
exec "$BLOG_ROOT/.tools/hugo" "$@"
