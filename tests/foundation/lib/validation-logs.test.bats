#!/usr/bin/env bats
# changed: sweep agents
# A Codex validator read "Stuff the raw output into Validation.md" literally and wrote a
# Validation.md of 105 515 lines. The log stays in the file long-run.sh wrote; Validation.md names
# that file and carries the result line, the tail and every error line.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "no validator asks for the whole log in Validation.md" {
  for f in "$ROOT"/agents/*-validator.md; do
    for bad in 'Stuff the raw' 'Capture full stdout' 'Capture full output' 'Full stdout of' 'Full output of' 'Raw build/test logs are attached'; do
      ! grep -qF -- "$bad" "$f" || { echo "$(basename "$f"): $bad"; return 1; }
    done
  done
}

@test "every validator names the log file, the tail and the error lines, never the whole log" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'never the whole log' "$f" || { echo "$(basename "$f"): no rule"; return 1; }
    grep -qF 'the path of the log' "$f" || { echo "$(basename "$f"): no log path"; return 1; }
  done
}

# Milestone 7: a Codex validator read "If a tool errored out, the verdict is FAILED" as covering a
# call it had fixed and rerun — a wrong JDK, a wrong driver action — and wrote FAILED over a green
# build, green tests and a driven scenario. FAILED is a step that never produced its evidence.
@test "every validator fails a step that never produced its evidence, not an error a rerun fixed" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'a rerun that succeeded' "$f" || { echo "$(basename "$f"): no rerun rule"; return 1; }
  done
}

@test "a rerun excuses only an error in how a step was invoked, never a failing build or test" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'never a build or test failure' "$f" || { echo "$(basename "$f"): rerun rule too wide"; return 1; }
  done
}

# Open items after 2.29.0: Validation.md linked logs in the temporary folder long-run.sh writes to
# (/var/folders/…/long-run.*), gone after the session; one run kept its own validation-evidence/.
# The logs Validation.md names are kept in the task folder, one subfolder per run.
@test "every validator keeps the logs Validation.md names in the task folder" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'validation-evidence/<timestamp>/' "$f" || { echo "$(basename "$f"): no evidence folder"; return 1; }
    ! grep -qF 'Logs stay on disk, in the file `long-run.sh`' "$f" || { echo "$(basename "$f"): still the temporary log"; return 1; }
  done
}

# Final review: Validation.md moves with its task (ACTIVE to DONE) and into _archive/, so a path to
# the copy from the project root or from the file itself breaks; the template sections named the
# temporary log.
@test "every validator names the excerpt by its path relative to the task folder" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'relative to the task folder' "$f" || { echo "$(basename "$f"): no path form"; return 1; }
    n="$(grep -c 'the path of the log excerpt' "$f")"
    [ "$n" -ge 2 ] || { echo "$(basename "$f"): $n template lines name the log excerpt"; return 1; }
  done
}

# A validator copied every log into validation-evidence/ and redacted only what it wrote to
# Validation.md, so the copy went into history unscrubbed. spine-toolkit 2.51.0 ships
# scripts/evidence.sh: `keep` puts the raw log into a git-ignored raw/ and writes a scrubbed excerpt
# beside it; `keep-image` moves a viewed screenshot out of raw/. Only the UI validator takes screenshots.
@test "every validator keeps its logs through evidence.sh" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'evidence.sh keep ' "$f" || { echo "$(basename "$f"): no evidence.sh keep"; return 1; }
    grep -qF -- '--match' "$f" || { echo "$(basename "$f"): no --match"; return 1; }
    grep -qF 'JUnit XML:' "$f" || { echo "$(basename "$f"): no JUnit XML result line"; return 1; }
    grep -qF 'Validation.md` quotes only the excerpt, never `raw/`' "$f" || { echo "$(basename "$f"): no excerpt-only rule"; return 1; }
    grep -qF 'Logs kept through `evidence.sh keep`' "$f" || { echo "$(basename "$f"): no checklist line"; return 1; }
  done
}

@test "only the UI validator takes screenshots through evidence.sh raw and keep-image" {
  f="$ROOT/agents/kotlin-ui-validator.md"
  grep -qF 'keep-image' "$f" || { echo "ui: no keep-image"; return 1; }
  grep -qF 'viewed: no secrets on screen' "$f" || { echo "ui: no viewed line"; return 1; }
  grep -qF 'screenshots through `keep-image` after viewing' "$f" || { echo "ui: no checklist line"; return 1; }
  for n in server jvm; do
    ! grep -qF 'keep-image' "$ROOT/agents/kotlin-$n-validator.md" || { echo "$n: mentions keep-image"; return 1; }
  done
}

@test "a screenshot is saved into the raw/ that evidence.sh raw prints, never one made by hand" {
  f="$ROOT/agents/kotlin-ui-validator.md"
  grep -qF 'evidence.sh raw <task_path>/validation-evidence/<timestamp>/' "$f" || { echo "ui: no evidence.sh raw"; return 1; }
  ! grep -qF 'saved into `validation-evidence/<timestamp>/raw/`' "$f" || { echo "ui: a raw/ made by hand"; return 1; }
}

# evidence.sh needs a task folder (one with Task.md) above the evidence dir; a path relative to the
# working directory, the project root, has none, and the script exits 2. The commands take the
# absolute form built from the task_path the agent was passed; what Validation.md cites stays relative.
@test "every evidence.sh command takes the evidence dir as <task_path>/validation-evidence/<timestamp>/" {
  for f in "$ROOT"/agents/*-validator.md; do
    run grep -oE 'evidence\.sh (keep|raw|keep-image) [^`]*' "$f"
    [ -n "$output" ] || { echo "$(basename "$f"): no evidence.sh command"; return 1; }
    while IFS= read -r cmd; do
      # every command carries the absolute form and no argument is the relative one
      grep -qF '<task_path>/validation-evidence/<timestamp>/' <<<"$cmd" || { echo "$(basename "$f"): $cmd"; return 1; }
      ! grep -qE ' validation-evidence/' <<<"$cmd" || { echo "$(basename "$f"): relative: $cmd"; return 1; }
    done <<<"$output"
  done
}

@test "kotlin-server-validator keeps the response bodies and CLI streams it quotes" {
  f="$ROOT/agents/kotlin-server-validator.md"
  grep -qF -- '--name <endpoint>-response' "$f" || { echo "no <endpoint>-response"; return 1; }
  grep -qF -- '--name <invocation>-stdout' "$f" || { echo "no CLI stdout keep"; return 1; }
}

@test "no validator carries its own redaction regex" {
  for f in "$ROOT"/agents/*-validator.md; do
    ! grep -qF '(?i)(token|secret|password|api' "$f" || { echo "$(basename "$f"): its own redaction regex"; return 1; }
    ! grep -qF 'Redact before writing to disk' "$f" || { echo "$(basename "$f"): its own redaction rule"; return 1; }
  done
}

@test "no validator redacts only Validation.md" {
  for f in "$ROOT"/agents/*-validator.md; do
    ! grep -qF 'before writing to `Validation.md`' "$f" || { echo "$(basename "$f"): still redacts Validation.md only"; return 1; }
    ! grep -qF 'copy each log' "$f" || { echo "$(basename "$f"): still copies the raw log"; return 1; }
    ! grep -qF 'the path of the copied log' "$f" || { echo "$(basename "$f"): names the copied log"; return 1; }
  done
}

# A --match that is anchored, or that counts only "tests", keeps no line. Each regex rule 4 of a
# validator documents is applied to the result and failure lines test-frameworks and the validator's
# own "Reading Gradle Output" show, because Validation.md quotes only the excerpt: a failure line no
# regex selects can never be quoted.
@test "every --match of rule 4 keeps the result and failure lines the validators read" {
  T="$ROOT/skills/test-frameworks/SKILL.md"
  for n in ui server jvm; do
    run python3 -I - "$ROOT/agents/kotlin-$n-validator.md" "$T" <<'PY'
import re, sys
rule = next(l for l in open(sys.argv[1], encoding="utf-8") if l.startswith("4. **Full logs"))
skill = open(sys.argv[2], encoding="utf-8").read()
regexes = re.findall(r"--match '([^']+)'", rule)
# (line, form that test-frameworks or the validator names) — singular counts included.
samples = [
    "JUnit XML: 12 tests, 0 failures, 0 errors, 0 skipped in 3 files",
    "JUnit XML: 1 test, 1 failure, 0 errors, 0 skipped in 1 files",
    "[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0",
    "Tests run: 1, Failures: 1, Errors: 0, Skipped: 0, Time elapsed: 0.01 s <<< FAILURE! -- in CartTest",
    "com.example.CartTest > total sums the lines() FAILED",
    "> Task :app:testDebugUnitTest FAILED",
    "e: file:///src/Cart.kt:12:5 Unresolved reference: total",
    "/src/Cart.java:3: error: cannot find symbol",
    "BUILD FAILED in 4s",
    "[ERROR] COMPILATION ERROR :",
    "[INFO] BUILD FAILURE",
    "* What went wrong: Execution failed for task ':app:compileKotlin'.",
]
bad = []
for line in samples:
    if not any(re.search(r, line) for r in regexes):
        bad.append("no --match keeps: " + line)
for r in regexes:
    if not any(re.search(r, l) for l in samples):
        bad.append("--match keeps no sample: " + r)
for need in ("JUnit XML:", "Tests run:", "e: ", "error:", "BUILD FAIL", "Execution failed for task", "FAILED", "ERROR"):
    if not any(need in r for r in regexes):
        bad.append("no --match for " + need)
if any(r.startswith("^") for r in regexes):
    bad.append("an anchored --match")
# the forms the regexes name are the forms test-frameworks and the agent show
agent = open(sys.argv[1], encoding="utf-8").read()
if "JUnit XML: N tests, F failures" not in skill or "Tests run: N, Failures: F" not in skill:
    bad.append("test-frameworks no longer shows the result-line forms")
if "`e: `" not in agent or "`error:`" not in agent or "`BUILD FAILED`" not in agent:
    bad.append("the agent no longer names the failure forms the samples copy")
# a line that merely mentions the letter e must not be kept by the compiler-error regex
for line in ("type: String", "name: cart"):
    if re.search(r"\be: ", line):
        bad.append("\\be: keeps an ordinary line: " + line)
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ] || { echo "kotlin-$n-validator: $output"; return 1; }
  done
}

# A device or process log a validator quotes goes through keep as well: the excerpt, not the
# command's raw output, is what Validation.md holds. Each `keep` that names a log (--name logcat,
# boot, app-process) carries --match regexes, and they are applied to the lines such a log has.
@test "the device and process logs a validator quotes are kept, and their --match regexes select the failure lines" {
  run python3 -I - "$ROOT/agents" <<'PY'
import re, sys
agents = sys.argv[1]
logs = {  # agent -> {name: sample lines the log has}
    "kotlin-ui-validator.md": {
        "logcat": [
            "E/AndroidRuntime( 4321): FATAL EXCEPTION: main",
            "E/AndroidRuntime( 4321): Process: com.example.app, PID: 4321",
            "E/AndroidRuntime( 4321): \tat com.example.app.CartViewModel.load(CartViewModel.kt:42)",
            "E/AndroidRuntime( 4321): Caused by: java.lang.IllegalStateException: no cart",
        ],
        "app-process": [
            "Exception in thread \"main\" java.lang.IllegalStateException: no cart",
            "Caused by: java.io.IOException: closed",
            "ERROR com.example.app.Main - startup failed",
        ],
    },
    "kotlin-server-validator.md": {
        "boot": [
            "2026-11-27 ERROR 1 --- [main] o.s.boot.SpringApplication : Application run failed",
            "java.lang.IllegalStateException: Failed to load ApplicationContext",
            "Caused by: org.postgresql.util.PSQLException: connection refused",
            "APPLICATION FAILED TO START",
        ],
    },
}
bad = []
for agent, named in logs.items():
    text = open(agents + "/" + agent, encoding="utf-8").read()
    cmds = re.findall(r"`[^`]*evidence\.sh keep [^`]*`", text)
    for name, samples in named.items():
        cmd = [c for c in cmds if "--name " + name + " " in c or "--name " + name + "`" in c]
        if len(cmd) != 1:
            bad.append("%s: %d keep commands for --name %s" % (agent, len(cmd), name))
            continue
        regexes = re.findall(r"--match '([^']+)'", cmd[0])
        if "<task_path>/validation-evidence/<timestamp>/" not in cmd[0]:
            bad.append("%s: %s keep has no <task_path> dir" % (agent, name))
        for line in samples:
            if not any(re.search(r, line) for r in regexes):
                bad.append("%s: no --match keeps: %s" % (name, line))
        for r in regexes:
            if not any(re.search(r, l) for l in samples):
                bad.append("%s: --match keeps no sample: %s" % (name, r))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "no validator quotes a device or process log it did not keep" {
  ! grep -qE 'Logcat stays yours either way: `adb logcat -d -s AndroidRuntime:E` after the run' "$ROOT/agents/kotlin-ui-validator.md" \
    || { echo "ui: logcat quoted straight from the command"; return 1; }
  grep -qF -- '--name app-process' "$ROOT/agents/kotlin-ui-validator.md" || { echo "ui: no desktop process log keep"; return 1; }
  grep -qF -- '--name boot' "$ROOT/agents/kotlin-server-validator.md" || { echo "server: no boot log keep"; return 1; }
}

# evidence.sh refuses a --name with a "/" (exit 2, "not a name"): an endpoint such as GET /api/cart
# makes one unless the agent is told to write a slug.
@test "a --name built from an endpoint or an invocation is a slug with no slash" {
  f="$ROOT/agents/kotlin-server-validator.md"
  grep -qF 'is a slug of letters, digits, `-`, `_` and `.` with no `/` and no spaces' "$f" || { echo "no slug rule for the endpoint name"; return 1; }
  grep -qF 'get-api-cart-response' "$f" || { echo "no example slug"; return 1; }
  grep -qF 'the invocation in a name is a slug too, with no `/` and no spaces' "$f" || { echo "no slug rule for the invocation name"; return 1; }
}

@test "a quoted request shows the value of each secret header as ***" {
  f="$ROOT/agents/kotlin-server-validator.md"
  grep -qF 'each secret header (`Authorization`, `Cookie`, an API key)' "$f" || { echo "no secret header rule"; return 1; }
  grep -qF 'shown as `***`' "$f" || { echo "no *** rule"; return 1; }
}

# evidence.sh exits 2 on a ## Redact line that does not parse, on no project config and on an evidence
# dir with no task folder above it. Read as a usage error, that exit sent the validator to "A core
# script or flag that is not there" and the user to restart the session instead of fixing the config.
@test "rule 4 says an evidence.sh exit 2 about the config is a configuration error, not an older core" {
  for f in "$ROOT"/agents/*-validator.md; do
    r="$(grep '^4\. \*\*Full logs' "$f")"
    grep -qF 'An `evidence.sh` exit 2 whose message names `## Redact`, the project config or the task folder is a configuration error: the step fails with that message; it is not an older core, and "A core script or flag that is not there" does not apply.' <<<"$r" \
      || { echo "$(basename "$f"): no configuration-error rule"; return 1; }
  done
}

# A bare `evidence.sh raw`, `keep-image` or `keep <…>` runs from the project root, where there is none.
@test "every evidence.sh command is written from the core root" {
  local bare
  for f in "$ROOT"/agents/*-validator.md; do
    bare="$(grep -oE '`[^`]*evidence\.sh (raw|keep-image|keep [^`]+)[^`]*`' "$f" | grep -vF '`<core root>/scripts/evidence.sh ' || true)"
    [ -z "$bare" ] || { echo "$(basename "$f"): $bare"; return 1; }
  done
}

# gradle-toolchain: a command with a shell redirect is matched by no Codex rule and stops to ask, and a
# file "in a temp file" or "into a file" has no stated location. A process log comes from long-run.sh,
# which writes it in $TMPDIR; logcat is written on the device under the run's timestamp, so two runs on
# one device do not overwrite each other, pulled, and removed from the device.
@test "the app, server and logcat logs come with no shell redirect" {
  local ui="$ROOT/agents/kotlin-ui-validator.md" srv="$ROOT/agents/kotlin-server-validator.md"
  for f in "$ui" "$srv"; do
    ! grep -nE '> <file>|2>&1 &|into a temp file|log into a file' "$f" || { echo "$(basename "$f"): a redirect or an unplaced file"; return 1; }
  done
  grep -qF '`<core root>/scripts/long-run.sh start --parallel -- ./gradlew :<app>:run`' "$ui" || { echo "ui: desktop app not started through long-run.sh"; return 1; }
  grep -qF '`<core root>/scripts/long-run.sh stop <log>`' "$ui" || { echo "ui: desktop app not stopped through long-run.sh"; return 1; }
  grep -qF '`adb -s <serial> logcat -d -f /data/local/tmp/spine-logcat-<timestamp>.txt -s AndroidRuntime:E`' "$ui" || { echo "ui: logcat not written on the device under the run's timestamp"; return 1; }
  grep -qF '`adb -s <serial> pull /data/local/tmp/spine-logcat-<timestamp>.txt <dir>/logcat.txt`' "$ui" || { echo "ui: logcat not pulled"; return 1; }
  grep -qF '`adb -s <serial> shell rm -f /data/local/tmp/spine-logcat-<timestamp>.txt`' "$ui" || { echo "ui: logcat file left on the device"; return 1; }
  ! grep -qF '/sdcard/spine-logcat.txt' "$ui" || { echo "ui: a fixed device path two runs would share"; return 1; }
  grep -qF '`<core root>/scripts/evidence.sh keep <dir>/logcat.txt <task_path>/validation-evidence/<timestamp>/ --name logcat' "$ui" || { echo "ui: pulled logcat not kept"; return 1; }
  grep -qF '`<core root>/scripts/long-run.sh start --parallel -- <command>`' "$srv" || { echo "server: not booted through long-run.sh"; return 1; }
  grep -qF '`<core root>/scripts/long-run.sh stop <log>`' "$srv" || { echo "server: not stopped through long-run.sh"; return 1; }
  grep -qF '`<core root>/scripts/evidence.sh keep <log> <task_path>/validation-evidence/<timestamp>/ --name boot' "$srv" || { echo "server: boot log not kept"; return 1; }
}
