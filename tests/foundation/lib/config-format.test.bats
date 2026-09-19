#!/usr/bin/env bats
# The config's settings live in [FIELD] = [value] lines. A surface still telling a reader to find
# a `## <Block>` section of that file is a surface that will send them looking for something the
# file no longer has.

setup() { ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"; }

# Core's helper (tests/foundation/lib/config-format.test.bats there), plus one exemption core has
# no occasion for: every mention of the config's `## <block>` in $2, minus the headings of $2 that
# merely begin with that word, and minus the two contract sections quoted in prose that are not the
# config's — `## Language Resolution`, which every localized skill carries, and `## Validation
# Report`, a section of a tester agent's own reply.
mentions() {
  command grep -nE "(^|[^#])## $1([^A-Za-z]|\$)" "$2" \
    | command grep -vE "## Language Resolution|## Validation Report|^[0-9]+:#+ $1 [A-Za-z]"
}

@test "no surface of this platform names a moved block of the project config" {
  n=0
  while IFS= read -r f; do
    n=$((n + 1))
    for block in Language Mode Progress Scale Reporting Validation Docs Budgets Models Effort; do
      [ -z "$(mentions "$block" "$f")" ] || { echo "$f still names ## $block"; return 1; }
    done
  done < <(find "$ROOT/skills" "$ROOT/agents" "$ROOT/conventions" "$ROOT/tests" -name '*.md' -o -name '*.bash')
  [ "$n" -ge 30 ] || { echo "scanned $n file(s), expected at least 30"; return 1; }
}
