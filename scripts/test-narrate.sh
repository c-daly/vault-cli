#!/usr/bin/env zsh
# test-narrate.sh — memorialized regression test for the `vault` narrate MVP.
#
# Tests the DETERMINISTIC contract of the daily-narrative feature, NOT LLM
# faithfulness. It is fully self-contained and hermetic: it builds its own
# temp $HOME (so CLAUDE_PROJECTS_DIR + harvest's claude dir both redirect),
# a temp VAULT_DIR, a temp repos dir, an empty shell-history file, and a
# STUB `claude` (+ stub `gh`) on PATH. It never touches the real vault or
# the user's real Claude sessions.
#
# Contract under test:
#   1. The `vault` script parses clean (`zsh -n`).
#   2. With NARRATE=1, a recap of the fixture date produces a `## Summary`
#      section AND a Claude-session line whose preview is the LLM output.
#   3. With NARRATE=0, the recap has NO `## Summary` and the session line
#      falls back to the fixture's first user prompt (not the LLM output).
#   4. Recap is non-destructive / idempotent: running it twice leaves
#      exactly one `## Auto-Recap (<host>)` block, and user-authored text
#      appended below the recap survives the second run.
#
# Run:  zsh scripts/test-narrate.sh
# Exit: 0 if every check PASSes, non-zero on the first FAIL.

set -uo pipefail

# --- Locate the vault script (repo root is this script's parent's parent) ---
SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
VAULT_BIN="$REPO_ROOT/vault"

if [[ ! -f "$VAULT_BIN" ]]; then
    echo "FAIL: cannot find vault script at $VAULT_BIN" >&2
    exit 1
fi

# A fixed target date so the fixture is deterministic. Midday UTC so the
# session buckets to the SAME local calendar date in any plausible local
# timezone (UTC-12 .. UTC+12) — the recap filters sessions by LOCAL date.
TARGET_DATE="2026-06-08"
SESSION_TS="2026-06-08T12:00:00.000Z"
STUB_MARKER="STUB-SUMMARY-MARKER"
FIRST_PROMPT="FIXTURE-FIRST-PROMPT refactor the cognition planner loop"
MANUAL_LINE="MANUAL-USER-NOTE-DO-NOT-DELETE this line is hand-authored"

# --- Hermetic sandbox -------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/vault-narrate-test.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT INT TERM

FAKE_HOME="$SANDBOX/home"
VAULT_DIR_T="$SANDBOX/vault"
REPOS_DIR_T="$SANDBOX/repos"
BIN_DIR="$SANDBOX/bin"
HIST_FILE_T="$SANDBOX/empty-history"   # intentionally absent
PROJECTS_DIR="$FAKE_HOME/.claude/projects"
PROJECT_NAME="-home-fearsidhe-projects-logos-workspace"

mkdir -p "$FAKE_HOME" "$VAULT_DIR_T" "$REPOS_DIR_T" "$BIN_DIR" \
         "$PROJECTS_DIR/$PROJECT_NAME"

# --- STUB `claude`: ignore args, print a fixed marker line ------------------
cat > "$BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
# Deterministic stub: ignore all args/flags/stdin, emit one fixed line.
cat >/dev/null 2>&1 || true
echo "STUB-SUMMARY-MARKER"
STUB
chmod +x "$BIN_DIR/claude"

# --- STUB `gh`: make the github collector bail out fast (no network) --------
cat > "$BIN_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Any auth check fails -> _collect_github_activity returns empty immediately.
exit 1
STUB
chmod +x "$BIN_DIR/gh"

# --- Fixture session .jsonl -------------------------------------------------
# Mirrors how `_collect_claude_sessions` parses a session:
#   * a leading metadata record WITHOUT a timestamp (CC 2.1.x shape),
#   * the first record carrying .timestamp + .gitBranch (start meta),
#   * .type=="user" records whose .message.content is a string prompt.
# Deliberately NO `ai-title` record, so the NARRATE=0 fallback lands on the
# first user prompt rather than an AI title.
SESSION_FILE="$PROJECTS_DIR/$PROJECT_NAME/fixture-session.jsonl"
{
    printf '%s\n' '{"type":"permission-mode","mode":"default"}'
    printf '{"timestamp":"%s","gitBranch":"main","type":"system"}\n' "$SESSION_TS"
    printf '{"timestamp":"%s","type":"user","message":{"role":"user","content":%s}}\n' \
        "$SESSION_TS" "$(printf '%s' "$FIRST_PROMPT" | jq -Rs .)"
    printf '{"timestamp":"%s","type":"user","message":{"role":"user","content":%s}}\n' \
        "$SESSION_TS" "$(printf '%s' "then wire the tooling and memory subsystems together" | jq -Rs .)"
    printf '{"timestamp":"%s","type":"user","message":{"role":"user","content":%s}}\n' \
        "$SESSION_TS" "$(printf '%s' "finally generate the diary narrative summary" | jq -Rs .)"
} > "$SESSION_FILE"

# --- Run the vault script under the sandbox env -----------------------------
# HOME redirect captures CLAUDE_PROJECTS_DIR (hardcoded to $HOME/.claude/...)
# and harvest's claude dir. XDG_CONFIG_HOME redirect prevents sourcing the
# real ~/.config/vault-cli/config. No .git in VAULT_DIR -> no `git pull`.
run_recap() {
    local narrate="$1"
    env -i \
        HOME="$FAKE_HOME" \
        PATH="$BIN_DIR:/usr/local/bin:/usr/bin:/bin" \
        XDG_CONFIG_HOME="$SANDBOX/config" \
        VAULT_DIR="$VAULT_DIR_T" \
        VAULT_REPOS_DIR="$REPOS_DIR_T" \
        HISTFILE="$HIST_FILE_T" \
        VAULT_GCAL_ENABLED="false" \
        NARRATE="$narrate" \
        NARRATE_MODEL="haiku" \
        NARRATE_TIMEOUT="30" \
        TERM="dumb" \
        zsh "$VAULT_BIN" recap "$TARGET_DATE" </dev/null
}

RECAP_FILE="$VAULT_DIR_T/journal/2026/06/$TARGET_DATE.md"

# --- Assertion harness ------------------------------------------------------
fails=0
pass() { print -r -- "PASS: $1"; }
fail() { print -r -- "FAIL: $1"; fails=$((fails + 1)); }

# === CHECK 1: zsh -n parses clean ===========================================
if zsh -n "$VAULT_BIN" 2>/dev/null; then
    pass "check 1: 'zsh -n vault' parses clean"
else
    fail "check 1: 'zsh -n vault' reported a syntax error"
fi

# === CHECK 2: NARRATE=1 -> ## Summary + stub marker in session line =========
rm -f "$RECAP_FILE"
out1="$(run_recap 1 2>&1)"
if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 2: recap file was not created ($RECAP_FILE)"
    print -r -- "---- recap stdout/stderr ----"
    print -r -- "$out1"
else
    if grep -qF "## Summary" "$RECAP_FILE"; then
        pass "check 2a: recap contains '## Summary'"
    else
        fail "check 2a: recap is missing '## Summary'"
    fi
    # The Claude-session preview line starts with '- ' and (NARRATE=1) ends
    # with the stub marker inside quotes.
    if grep -E '^- .*'"$STUB_MARKER" "$RECAP_FILE" >/dev/null; then
        pass "check 2b: a Claude-session line carries the stub LLM summary"
    else
        fail "check 2b: no Claude-session line carries '$STUB_MARKER'"
    fi
fi

# === CHECK 3: NARRATE=0 -> no ## Summary, fallback to first prompt ==========
rm -f "$RECAP_FILE"
out0="$(run_recap 0 2>&1)"
if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 3: recap file was not created with NARRATE=0"
    print -r -- "$out0"
else
    if grep -qF "## Summary" "$RECAP_FILE"; then
        fail "check 3a: NARRATE=0 recap unexpectedly contains '## Summary'"
    else
        pass "check 3a: NARRATE=0 recap has no '## Summary'"
    fi
    if grep -F "$STUB_MARKER" "$RECAP_FILE" >/dev/null; then
        fail "check 3b: NARRATE=0 recap leaked the stub LLM marker"
    else
        pass "check 3b: NARRATE=0 recap did not call the LLM"
    fi
    # Fallback preview is the first user prompt truncated to ~100 chars; the
    # fixture's first prompt is short, so it appears verbatim on a '- ' line.
    if grep -E '^- .*FIXTURE-FIRST-PROMPT' "$RECAP_FILE" >/dev/null; then
        pass "check 3c: session line falls back to the first user prompt"
    else
        fail "check 3c: session line did not fall back to the first user prompt"
    fi
fi

# === CHECK 4: non-destructive / idempotent ==================================
# Fresh run, then append a hand-authored line at EOF, then a second run.
# Expect: exactly one '## Auto-Recap (<host>)' block, and the manual line
# survives the second run.
rm -f "$RECAP_FILE"
run_recap 1 >/dev/null 2>&1   # fresh

if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 4: recap file missing before idempotency run"
else
    print -r -- "" >> "$RECAP_FILE"
    print -r -- "$MANUAL_LINE" >> "$RECAP_FILE"

    run_recap 1 >/dev/null 2>&1   # replace (idempotent)

    host_blocks=$(grep -c '^## Auto-Recap (' "$RECAP_FILE")
    if [[ "$host_blocks" -eq 1 ]]; then
        pass "check 4a: exactly one '## Auto-Recap' block after two runs"
    else
        fail "check 4a: expected 1 '## Auto-Recap' block, found $host_blocks"
    fi

    if grep -qF "$MANUAL_LINE" "$RECAP_FILE"; then
        pass "check 4b: hand-authored line survived the second run"
    else
        fail "check 4b: hand-authored line was destroyed by the second run"
    fi
fi

# --- Verdict ----------------------------------------------------------------
print -r -- ""
if [[ "$fails" -eq 0 ]]; then
    print -r -- "ALL CHECKS PASSED"
    exit 0
else
    print -r -- "$fails CHECK(S) FAILED"
    exit 1
fi
