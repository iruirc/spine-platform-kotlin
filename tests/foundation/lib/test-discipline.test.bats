#!/usr/bin/env bats
# What a good test is does not depend on the language, so it lives in core and this
# plugin says only what core cannot: which boundaries a Kotlin project has, what
# resets state, and which library makes the double. These tests are what keeps the
# neutral half from growing back one helpful sentence at a time — in four files at
# once, because the block they share is copied, not included.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  AGENTS="$ROOT/agents"
  SKILLS="$ROOT/skills"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
}

TESTERS="kotlin-jvm-tester kotlin-server-tester kotlin-ui-tester kotlin-kmp-tester"

@test "no agent or skill restates the neutral discipline" {
  # Each pattern is the rule as it was written here before core carried it. They are
  # chosen to sit on one line whatever the wrapping, so a re-wrap cannot hide a copy.
  offenders=""
  for pat in 'Arrange → Act → Assert' 'methodName_condition_expectedResult' \
             'Never mock these' 'Every test must be idempotent' 'Tests are idempotent'; do
    hits="$(grep -rlF "$pat" "$AGENTS" "$SKILLS" || true)"
    [ -z "$hits" ] || offenders="$offenders$pat: $(echo "$hits" | xargs -n1 basename | tr '\n' ' ')"$'\n'
  done
  [ -z "$offenders" ] || { echo "the neutral discipline is back:"; echo "$offenders"; return 1; }
}

@test "every tester points at core for the discipline and keeps its Kotlin half" {
  bad=""
  for a in $TESTERS; do
    t="$AGENTS/$a.md"
    grep -qF '`## Test doubles`' "$t" || bad="$bad $a(doubles)"
    grep -qF '`## Before you deliver`' "$t" || bad="$bad $a(gate)"
    # The half that stays is the half core cannot know. Losing it would leave a tester
    # that is correct and useless: it would name no Kotlin boundary at all.
    for kotlin in '@TempDir' 'SharedPreferences' 'MockK'; do
      grep -qF "$kotlin" "$t" || bad="$bad $a($kotlin)"
    done
  done
  [ -z "$bad" ] || { echo "tester(s) that lost a side of the split:$bad"; return 1; }
}

@test "the Spring row names the annotation Spring Boot 3.4 left in place" {
  f="$AGENTS/kotlin-server-tester.md"
  spring="$(awk '$0=="### Spring Boot"{f=1;next} f&&/^#{2,3} /{exit} f' "$f")"
  [ -n "$spring" ] || { echo "no ### Spring Boot section"; return 1; }
  grep -qF '@MockitoBean' <<<"$spring" || { echo "the Spring row does not name @MockitoBean"; return 1; }
  # @MockBean may still be named here, and should be: it is what the reader remembers.
  # What it may not be is prescribed, so every line carrying it has to say it is gone.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF 'deprecated' <<<"$line" \
      || { echo "the Spring row still prescribes @MockBean:$line"; return 1; }
  done < <(grep -F '@MockBean' <<<"$spring" || true)
  # Micronaut's @MockBean is a different annotation of a different framework: it is
  # correct, and a blanket rename across the file is what this half catches.
  micronaut="$(awk '$0=="### Micronaut / Quarkus / http4k"{f=1;next} f&&/^#{2,3} /{exit} f' "$f")"
  grep -qF '@MockBean' <<<"$micronaut" \
    || { echo "Micronaut's own @MockBean was renamed with Spring's"; return 1; }
}
