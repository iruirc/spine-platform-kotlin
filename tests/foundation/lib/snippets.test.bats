#!/usr/bin/env bats
# What scripts/compile-snippets.sh does before Gradle: markers, units, preludes, the catalog, the toolchain.
# The Gradle build itself runs in tests/foundation/snippets, through `scripts/test-foundation.sh snippets`.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SNIP="$ROOT/scripts/compile-snippets.sh"
  FX="$ROOT/tests/foundation/fixtures/snippets"
  SANDBOX="$ROOT/tests/snippets"
  OUT="$BATS_TEST_TMPDIR/units"
}

@test "the version catalog pins the majors the skills teach" {
  c="$SANDBOX/gradle/libs.versions.toml"
  for want in 'kotlin = "2\.4\.' 'agp = "9\.' 'spring-boot = "4\.' 'exposed = "1\.' 'testcontainers = "2\.' \
              'koin = "4\.2\.' 'orbit = "12\.' 'room = "2\.' 'junit-jupiter = "5\.' 'navigation3 = "1\.'; do
    grep -qE "^$want" "$c" || { echo "the catalog does not pin $want"; return 1; }
  done
  ! grep -qE '^room3' "$c" || { echo "Room 3 is a variant, not the pinned major"; return 1; }
}
