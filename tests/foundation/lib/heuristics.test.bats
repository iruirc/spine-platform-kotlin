#!/usr/bin/env bats
# A pinning row that names a value the axis does not list resolves that axis to
# nothing, on every project, with no symptom. And `ecosystem` is excluded from
# detection by the contract, so a row pinning it can never match.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  M="$ROOT/skills/manifest/SKILL.md"
  AXES="$(sed -n '/^## Axes/,/^## Heuristics/p' "$M" | grep -E '^[a-z][a-z-]*[[:space:]]*=')"
  PINS="$(sed -n '/^## Heuristics/,/^## Topics/p' "$M" | grep -oE '→[[:space:]]*[a-z][a-z-]*=[^(]+$' \
            | sed 's/^→[[:space:]]*//; s/[[:space:]]*$//')"
}

@test "the heuristics table pins at least twenty values" {
  n="$(printf '%s\n' "$PINS" | grep -c . || true)"
  [ "$n" -ge 20 ] || { echo "found $n pinning rows; the scan went vacuous"; return 1; }
}

@test "every pinned value is one its axis lists" {
  bad=""
  while IFS= read -r pin; do
    [ -n "$pin" ] || continue
    axis="${pin%%=*}"; value="${pin#*=}"
    allowed="$(grep -E "^${axis}[[:space:]]*=" <<<"$AXES" | sed 's/^[^=]*=//')"
    [ -n "$allowed" ] || { bad="$bad [no axis: $pin]"; continue; }
    # Exact compare, not a regex: `API 26+` and `kotlinx.coroutines` carry metacharacters.
    found=0
    IFS=',' read -ra vals <<<"$allowed"
    for v in "${vals[@]}"; do
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      [ "$v" = "$value" ] && found=1
    done
    [ "$found" -eq 1 ] || bad="$bad [$pin]"
  done <<<"$PINS"
  [ -z "$bad" ] || { echo "pinned values the catalog does not list:$bad"; return 1; }
}

@test "no heuristic pins ecosystem" {
  ! grep -qE '→[[:space:]]*ecosystem=' "$M"
}
