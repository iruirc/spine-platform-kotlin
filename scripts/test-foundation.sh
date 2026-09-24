#!/usr/bin/env bash
# Adapted from spine-toolkit scripts/test-foundation.sh sha256:11626b8b730021a82aa492e67cfe1b44d67d997726e9ddd27c4b507c820c8493
# Adapted from spine-toolkit's test runner. Plugins share no code; update both or neither.
# Run Foundation bats tests.
# Usage: scripts/test-foundation.sh [unit|all|snippets]
set -euo pipefail

target="${1:-all}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "error: bats-core not on PATH. install: brew install bats-core" >&2
  exit 3
fi

# `all` differs from `unit` only when an integration suite exists; core has none
# today, and an `all` hard-coded to lib/ would silently not run one that appears.
suites=("$root/tests/foundation/lib")
[ -d "$root/tests/foundation/integration" ] && suites+=("$root/tests/foundation/integration")

case "$target" in
  unit) bats "$root/tests/foundation/lib" ;;
  all)  bats "${suites[@]}" ;;
  # Minutes of Gradle, so `all` leaves it out; `snippets` is run on its own and in CI.
  snippets) bats "$root/tests/foundation/snippets" ;;
  *)    echo "usage: $0 [unit|all|snippets]" >&2; exit 2 ;;
esac
