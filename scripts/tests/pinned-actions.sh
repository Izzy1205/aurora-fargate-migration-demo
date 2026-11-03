#!/usr/bin/env bash
# Fails on any uses: in .github that isn't a local ./ path or pinned to a
# full commit SHA with a "# vX.Y.Z" comment after it. Dependabot needs the
# comment to bump the version along with the SHA.
#
#   bash scripts/tests/pinned-actions.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."

pinned='@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$'
fail=0
while IFS= read -r line; do
  ref=$(printf '%s\n' "$line" | sed -E 's/^[^:]+:[0-9]+:[[:space:]]*(- )?uses:[[:space:]]*//; s/["'\'']//g')
  case "$ref" in
    ./*) continue ;;
  esac
  if ! printf '%s\n' "$ref" | grep -Eq "$pinned"; then
    printf 'FAIL not pinned: %s\n' "$line"
    fail=1
  fi
done < <(grep -rnE '^[[:space:]]*(- )?uses:' .github/workflows .github/actions || true)

if [ "$fail" -eq 0 ]; then
  echo "ok   every uses: is a local path or pinned to a SHA"
fi
exit "$fail"
