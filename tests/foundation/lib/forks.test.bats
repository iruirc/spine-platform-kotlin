#!/usr/bin/env bats
# The six adapted forks each record the core file they came from and that file's
# sha256. Equality with core is the wrong test — some forks differ on purpose — so
# what is checked is that core's original has not moved since the fork was taken.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
}

@test "exactly six files carry an adapted-fork header" {
  n="$(grep -lE '^[#>] Adapted from spine-toolkit .* sha256:[0-9a-f]{64}$' \
         "$ROOT"/scripts/*.sh "$ROOT"/conventions/*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -eq 6 ] || { echo "expected 6 adapted forks, found $n"; return 1; }
}

@test "core's originals have not moved under the adapted forks" {
  [ -d "$CORE/scripts" ] || skip "no spine-toolkit checkout beside this one"
  for f in "$ROOT"/scripts/*.sh "$ROOT"/conventions/*.md; do
    line="$(sed -n 's/^[#>] Adapted from spine-toolkit \(.*\) sha256:\([0-9a-f]*\)$/\1 \2/p' "$f" | head -1)"
    [ -n "$line" ] || continue
    rel="${line% *}"; want="${line#* }"
    [ -f "$CORE/$rel" ] || { echo "core no longer has $rel"; return 1; }
    have="$(shasum -a 256 "$CORE/$rel" | cut -d' ' -f1)"
    [ "$want" = "$have" ] || { echo "core's $rel moved since $f was adapted ($want -> $have)"; return 1; }
  done
}
