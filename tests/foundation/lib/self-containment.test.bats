#!/usr/bin/env bats
# A platform plugin ships alone: the only thing it may name across the plugin
# boundary is a namespaced skill or agent (`spine-toolkit:setup`). A bare relative
# path resolves under THIS plugin's root, so one that belongs to core finds nothing
# and carries no prefix for the cross-plugin grep to catch.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "every bare relative path kotlin-platform names resolves under its own root" {
  missing=""
  for p in $(grep -rhoE '`[A-Za-z_][A-Za-z0-9_.-]*/[^` ]*`' "$ROOT" \
               --include='*.md' --include='*.sh' --include='*.bats' --include='*.yml' \
               --exclude-dir=.git \
             | tr -d '`' | sort -u); do
    case "$p" in
      skills/*|agents/*|commands/*|conventions/*|templates/*|scripts/*|tests/*) ;;
      *) continue ;;
    esac
    q="$(printf '%s' "$p" | sed 's/<[^>]*>/*/g')"
    compgen -G "$ROOT/${q%/}" >/dev/null || missing="$missing $p"
  done
  [ -z "$missing" ] || { echo "path(s) that do not resolve under kotlin-platform:$missing"; return 1; }
}

@test "no file names the retired plugin's namespace" {
  # Agent bodies were ported from kotlin-toolkit; a `kotlin-toolkit:<agent>` left in a
  # subagent_type dispatches to nothing. The two files that spell the string as a guard —
  # this one and the shape helper — are the only legitimate mentions.
  offenders="$(grep -rn --exclude-dir=.git 'kotlin-toolkit' "$ROOT" \
    | grep -vF -e 'self-containment.test.bats' -e 'helpers/shape.bash' || true)"
  [ -z "$offenders" ] || { echo "$offenders"; return 1; }
}

@test "no file in kotlin-platform names the core tree by a filesystem path" {
  pat='(\.\./(core|spine-toolkit|swift-platform|kotlin-platform)([^A-Za-z0-9_-]|$)'
  pat="$pat"'|(^|[^A-Za-z0-9_.$-])core/'
  pat="$pat"'|(^|[^A-Za-z0-9_-])(spine-toolkit|swift-platform|kotlin-platform)/)'
  # Three files are excluded by name: the two suites that look for a sibling checkout
  # of core (they skip rather than dangle when it is absent) and this one, which
  # spells the patterns out. The cost is a blind spot inside those three files.
  hits="$(grep -rnE --exclude-dir=.git \
            --exclude=self-containment.test.bats --exclude=core-refs.test.bats --exclude=forks.test.bats \
            "$pat" "$ROOT" | grep -vE '/\.claude/plugins/(cache|marketplaces)/' || true)"
  [ -z "$hits" ] || { echo "kotlin-platform reference(s) to the core tree:"; echo "$hits"; return 1; }
}
