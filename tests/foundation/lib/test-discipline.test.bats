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

@test "the Spring row names @MockitoBean and leaves the Boot 3 annotations to di-spring" {
  f="$AGENTS/kotlin-server-tester.md"
  spring="$(awk '$0=="### Spring Boot"{f=1;next} f&&/^#{2,3} /{exit} f' "$f")"
  [ -n "$spring" ] || { echo "no ### Spring Boot section"; return 1; }
  grep -qF '@MockitoBean' <<<"$spring" || { echo "the Spring row does not name @MockitoBean"; return 1; }
  # Boot 4 removed @MockBean; what replaced it is di-spring's to say, so the row names it nowhere.
  if grep -qF '@MockBean' <<<"$spring"; then
    echo "the Spring row names @MockBean:"; grep -F '@MockBean' <<<"$spring"; return 1
  fi
  grep -qF '`di-spring` → "Testing"' <<<"$spring" \
    || { echo "the Spring row does not link di-spring → Testing"; return 1; }
  # Micronaut's @MockBean is a different annotation of a different framework: it is
  # correct, and a blanket rename across the file is what this half catches.
  micronaut="$(awk '$0=="### Micronaut / Quarkus / http4k"{f=1;next} f&&/^#{2,3} /{exit} f' "$f")"
  grep -qF '@MockBean' <<<"$micronaut" \
    || { echo "Micronaut's own @MockBean was renamed with Spring's"; return 1; }
}

@test "the reviewer judges tests by the core section, not by a list of its own" {
  r="$AGENTS/kotlin-reviewer.md"
  grep -qF '`## Review`' "$r" || { echo "the reviewer does not name the core section"; return 1; }
  grep -qF 'spine-toolkit:test-authoring' "$r" || { echo "the reviewer never names the skill"; return 1; }
  # The heading stays — it is the reviewer's own checklist structure — but the four
  # bullets under it were the copy, and "Mock abuse" is the one that cannot be
  # rewritten without saying what a double is for, which is core's sentence now.
  if grep -qF '**Mock abuse**' "$r"; then
    echo "the reviewer still carries its own test criteria"
    return 1
  fi
}

@test "core at the declared floor has the sections the agents point at" {
  # lint-core-refs.sh resolves skill names, not sections, and test-authoring existed
  # a minor before these sections did. Without this test the floor is a claim.
  [ -d "$CORE/.git" ] || skip "no spine-toolkit checkout beside this one"
  floor="$(python3 -c 'import json,sys,re; d=json.load(open(sys.argv[1]))["dependencies"]; v=[x["version"] for x in d if x["name"]=="spine-toolkit"][0]; print(re.search(r">=\s*(\d+\.\d+\.\d+)", v).group(1))' "$ROOT/.claude-plugin/plugin.json")"
  git -C "$CORE" rev-parse -q --verify "$floor^{commit}" >/dev/null || skip "core has no tag $floor"
  skill="$(git -C "$CORE" show "$floor:skills/test-authoring/SKILL.md")"
  for h in '## What a good test is' '## Test doubles' '## Before you deliver' '## Review' '## When the task owes no test'; do
    grep -qF "$h" <<<"$skill" || { echo "core $floor has no $h — the floor is too low"; return 1; }
  done
}

@test "the regression test is owed only when the task owes one" {
  for a in kotlin-diagnostics kotlin-compose-developer kotlin-server-developer kotlin-kmp-developer; do
    grep -qF '`## When the task owes no test`' "$AGENTS/$a.md" \
      || { echo "$a writes a regression test whatever need_test says"; return 1; }
  done
  # "Write tests when NEED_TEST=false — <tester> does" read as: under false, the tester writes them.
  if grep -lF 'Write tests when NEED_TEST=false' "$AGENTS"/*.md; then
    echo "a developer still hands the test to the tester under need_test=false"; return 1
  fi
  # The Related Agents roster is prose beside the already-conditional `## Regression Test`
  # bullet; a mention of "regression test" there without the qualifier promises one anyway.
  roster="$(awk '$0=="## Related Agents (spine-platform-kotlin)"{f=1;next} f&&/^#{2,3} /{exit} f' \
    "$AGENTS/kotlin-diagnostics.md")"
  [ -n "$roster" ] \
    || { echo "kotlin-diagnostics has no ## Related Agents (spine-platform-kotlin) section to check"; return 1; }
  if grep -qi 'regression test' <<<"$roster" && ! grep -qF '`## When the task owes no test`' <<<"$roster"; then
    echo "kotlin-diagnostics' roster still promises the regression test unconditionally"; return 1
  fi
}
