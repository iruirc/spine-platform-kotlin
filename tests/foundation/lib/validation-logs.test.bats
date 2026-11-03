#!/usr/bin/env bats
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
# The logs Validation.md names are copied into the task folder, one subfolder per run.
@test "every validator keeps the logs Validation.md names in the task folder" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'validation-evidence/<timestamp>/' "$f" || { echo "$(basename "$f"): no evidence folder"; return 1; }
    ! grep -qF 'Logs stay on disk, in the file `long-run.sh`' "$f" || { echo "$(basename "$f"): still the temporary log"; return 1; }
  done
}
