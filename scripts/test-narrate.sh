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

# Narrator cwd, inside the sandbox so the assertion below can pin it exactly.
NARRATE_CWD_T="$SANDBOX/narrate"

mkdir -p "$FAKE_HOME" "$VAULT_DIR_T" "$REPOS_DIR_T" "$BIN_DIR" \
         "$NARRATE_CWD_T" "$PROJECTS_DIR/$PROJECT_NAME"

# --- STUB `claude`: record the invocation, print a fixed marker line --------
# It records argv and cwd rather than ignoring them. Both `--tools ""` and the
# dedicated narrate cwd are load-bearing and silently reversible: without this,
# deleting either leaves every check in this file passing, while the summarizer
# regains the ability to act on the transcript it was asked to summarize (which
# is how it once recursed into `vault backfill` and pushed the vault unasked).
CLAUDE_STUB_LOG="$SANDBOX/claude-invocations.log"
cat > "$BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${CLAUDE_STUB_LOG:-}" ]]; then
    {
        printf 'CWD=%s\n' "$PWD"
        for a in "$@"; do printf 'ARG=%s\n' "$a"; done
        printf 'END\n'
    } >> "$CLAUDE_STUB_LOG"
fi
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
        CLAUDE_STUB_LOG="$CLAUDE_STUB_LOG" \
        VAULT_NARRATE_CWD="$NARRATE_CWD_T" \
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

# === CHECK 5: a pre-sentinel block containing a bare `---` is not truncated =
# The boundary ambiguity this whole sentinel exists for. Inbox captures are
# spliced in verbatim and can carry a bare `---`; scanning for one would end the
# block early and leave the tail of the stale recap beside the replacement.
HOST_NAME="$(hostname -s 2>/dev/null || hostname)"
STUB_END="<!-- /auto-recap -->"
rm -f "$RECAP_FILE" "${RECAP_FILE}.pre-recap.bak"
cat > "$RECAP_FILE" <<LEGACY
---
created: $TARGET_DATE
type: daily-recap
---

# legacy fixture

## Auto-Recap ($HOST_NAME)
_Generated: long ago_

## Inbox
a captured note
---
the capture continues past that separator

## Git & GitHub
STALE-GIT-SECTION

---

LEGACY-USER-TAIL
LEGACY

run_recap 1 >/dev/null 2>&1

if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 5: recap file vanished on the legacy migration"
else
    if grep -qF "LEGACY-USER-TAIL" "$RECAP_FILE"; then
        pass "check 5a: user text below a legacy block survived"
    else
        fail "check 5a: user text below a legacy block was destroyed"
    fi
    # The real defect is not truncation — the old code preserved these lines,
    # but left them sitting BESIDE the new block as if current, producing
    # duplicated and contradictory sections. Assert containment by ordering:
    # new block, then its sentinel, then the marker, and only then the stale
    # content. Anything stale appearing above the marker is loose.
    ln_end=$(grep -nF -m1 "$STUB_END" "$RECAP_FILE" | cut -d: -f1)
    ln_mark=$(grep -nF -m1 "superseded pre-sentinel recap" "$RECAP_FILE" | cut -d: -f1)
    ln_stale=$(grep -nF -m1 "STALE-GIT-SECTION" "$RECAP_FILE" | cut -d: -f1)
    if [[ -n "$ln_end" && -n "$ln_mark" && -n "$ln_stale" ]] \
       && (( ln_end < ln_mark && ln_mark < ln_stale )); then
        pass "check 5b: stale sections are confined below the marker, not beside the new block"
    else
        fail "check 5b: stale content is not contained (sentinel=$ln_end marker=$ln_mark stale=$ln_stale)"
    fi
    if grep -qF "superseded pre-sentinel recap" "$RECAP_FILE"; then
        pass "check 5c: the preserved legacy region is explicitly marked"
    else
        fail "check 5c: legacy region preserved without a marker"
    fi
    # Neutralized so a later run does not treat it as a live recap block.
    if grep -qF "## (superseded) Auto-Recap ($HOST_NAME)" "$RECAP_FILE"; then
        pass "check 5d: the old header was neutralized"
    else
        fail "check 5d: the old header is still a live '## Auto-Recap' block"
    fi
    if [[ -f "${RECAP_FILE}.pre-recap.bak" ]]; then
        pass "check 5e: a backup was taken before migrating"
    else
        fail "check 5e: no backup taken before migrating a legacy block"
    fi
    # Second run must now be an ordinary sentinel splice and stay stable.
    run_recap 1 >/dev/null 2>&1
    live_blocks=$(grep -c '^## Auto-Recap (' "$RECAP_FILE")
    if [[ "$live_blocks" -eq 1 ]]; then
        pass "check 5f: converges to exactly one live block on the next run"
    else
        fail "check 5f: expected 1 live block after migration, found $live_blocks"
    fi
    if grep -qF "LEGACY-USER-TAIL" "$RECAP_FILE"; then
        pass "check 5g: user text still present after the second run"
    else
        fail "check 5g: second run destroyed the user text"
    fi
fi

# === CHECK 6: NARRATE=0 ignores an ai-title and uses the first prompt =======
# The fixture used above deliberately has no ai-title, so this path was
# uncovered: with narration off, a session carrying an ai-title must still fall
# back to the first user prompt rather than showing the title.
AI_SESSION="$PROJECTS_DIR/$PROJECT_NAME/ai-title-session.jsonl"
{
    print -r -- '{"type":"summary"}'
    print -r -- "{\"timestamp\":\"${TARGET_DATE}T10:00:00.000Z\",\"gitBranch\":\"main\",\"cwd\":\"$REPOS_DIR_T\"}"
    print -r -- '{"type":"ai-title","aiTitle":"AI-GENERATED-TITLE-MARKER"}'
    print -r -- "{\"type\":\"user\",\"timestamp\":\"${TARGET_DATE}T10:01:00.000Z\",\"message\":{\"content\":\"AITITLE-FIRST-PROMPT\"}}"
} > "$AI_SESSION"

rm -f "$RECAP_FILE"
run_recap 0 >/dev/null 2>&1

if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 6: recap file was not created"
else
    if grep -qF "AI-GENERATED-TITLE-MARKER" "$RECAP_FILE"; then
        fail "check 6a: NARRATE=0 used the ai-title instead of the first prompt"
    else
        pass "check 6a: NARRATE=0 did not fall back to the ai-title"
    fi
    if grep -qF "AITITLE-FIRST-PROMPT" "$RECAP_FILE"; then
        pass "check 6b: NARRATE=0 fell back to the first user prompt"
    else
        fail "check 6b: first user prompt missing for the ai-title session"
    fi
fi
rm -f "$AI_SESSION"
# === CHECK 8: the narrator is invoked with no tools, from the narrate cwd ===
# Regression cover for two containment guarantees that are otherwise invisible
# to this suite. `--tools ""` is what stops the summarizer acting on the
# transcript it summarizes; running from NARRATE_CWD is what keeps its own
# `claude -p` transcripts out of the harvest. Deleting either used to leave
# every check green.
rm -f "$RECAP_FILE" "$CLAUDE_STUB_LOG"
run_recap 1 >/dev/null 2>&1

if [[ ! -s "$CLAUDE_STUB_LOG" ]]; then
    fail "check 8: the narrator was never invoked, so containment is untested"
else
    if grep -qxF 'ARG=--tools' "$CLAUDE_STUB_LOG"; then
        pass "check 8a: narrator invoked with --tools"
    else
        fail "check 8a: narrator invoked WITHOUT --tools (tool restriction lost)"
    fi

    # The value must be the empty string: `--tools` followed by anything else
    # would re-enable that toolset.
    if awk '/^ARG=--tools$/ { getline nxt; if (nxt == "ARG=") ok = 1 } END { exit ok ? 0 : 1 }' \
           "$CLAUDE_STUB_LOG"; then
        pass "check 8b: --tools value is empty (all tools disabled)"
    else
        fail "check 8b: --tools was not followed by an empty value"
    fi

    if grep -qxF "CWD=$NARRATE_CWD_T" "$CLAUDE_STUB_LOG"; then
        pass "check 8c: narrator ran from VAULT_NARRATE_CWD"
    else
        fail "check 8c: narrator did not run from VAULT_NARRATE_CWD"
        grep -m1 '^CWD=' "$CLAUDE_STUB_LOG"
    fi
fi

# === CHECK 7: source text equal to the sentinel cannot terminate the block ==
# Generated sources are spliced in verbatim, so a source line equal to the
# terminator would end the block early on the next replace. Exercised by making
# the narrator emit the sentinel, which lands in `## Summary` unmodified.
cat > "$BIN_DIR/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
echo "before-sentinel"
echo "$STUB_END"
echo "after-sentinel"
STUB
chmod +x "$BIN_DIR/claude"

rm -f "$RECAP_FILE"
run_recap 1 >/dev/null 2>&1          # fresh
run_recap 1 >/dev/null 2>&1          # replace — where an early terminator would bite

if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 7: recap file was not created"
else
    real_ends=$(grep -cxF "$STUB_END" "$RECAP_FILE")
    if [[ "$real_ends" -eq 1 ]]; then
        pass "check 7a: exactly one live sentinel in the file"
    else
        fail "check 7a: expected 1 live sentinel, found $real_ends"
    fi
    if grep -qF "escaped: appeared in source text" "$RECAP_FILE"; then
        pass "check 7b: the sentinel occurring in source text was defused"
    else
        fail "check 7b: source sentinel was left live in the block"
    fi
    if grep -qF "after-sentinel" "$RECAP_FILE"; then
        pass "check 7c: block content past the embedded sentinel survived"
    else
        fail "check 7c: block was truncated at the embedded sentinel"
    fi
    blocks=$(grep -c '^## Auto-Recap (' "$RECAP_FILE")
    if [[ "$blocks" -eq 1 ]]; then
        pass "check 7d: still exactly one block after the replace"
    else
        fail "check 7d: expected 1 block, found $blocks"
    fi
fi

# === CHECK 9: a later block's sentinel is not this block's boundary =========
# An unterminated legacy block followed by a sentinel-terminated block from
# another machine. Accepting the later sentinel as the first block's end would
# make the splice discard everything between them — the other machine's recap
# and any user notes with it.
rm -f "$RECAP_FILE" "${RECAP_FILE}.pre-recap.bak"
cat > "$RECAP_FILE" <<TWOHOST
---
created: $TARGET_DATE
type: daily-recap
---

# two-host fixture

## Auto-Recap ($HOST_NAME)
_Generated: long ago, never terminated_
OLD-UNTERMINATED-BODY

## Auto-Recap (otherbox)
_Generated: elsewhere_
OTHER-MACHINE-RECAP
$STUB_END

BETWEEN-HOSTS-USER-NOTE
TWOHOST

run_recap 1 >/dev/null 2>&1

if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 9: recap file vanished"
else
    if grep -qF "OTHER-MACHINE-RECAP" "$RECAP_FILE"; then
        pass "check 9a: another machine's recap survived"
    else
        fail "check 9a: another machine's recap was deleted"
    fi
    if grep -qF "BETWEEN-HOSTS-USER-NOTE" "$RECAP_FILE"; then
        pass "check 9b: user note after the other block survived"
    else
        fail "check 9b: user note was deleted"
    fi
    if grep -qF "## Auto-Recap (otherbox)" "$RECAP_FILE"; then
        pass "check 9c: the other host's block header is intact"
    else
        fail "check 9c: the other host's block header was removed"
    fi
fi

# === CHECK 10: a recap heading in source text must not force re-migration ===
# A source line opening `## Auto-Recap (` would make a valid sentinel-terminated
# block read as unterminated, so every refresh would file another superseded
# copy and the file would never converge to one live block.
cat > "$BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
echo "quoting a recap header from another machine:"
echo "## Auto-Recap (somebox)"
echo "tail-after-heading"
STUB
chmod +x "$BIN_DIR/claude"

rm -f "$RECAP_FILE" "${RECAP_FILE}.pre-recap.bak"
run_recap 1 >/dev/null 2>&1
run_recap 1 >/dev/null 2>&1
run_recap 1 >/dev/null 2>&1

if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 10: recap file was not created"
else
    live=$(grep -c '^## Auto-Recap (' "$RECAP_FILE")
    if [[ "$live" -eq 1 ]]; then
        pass "check 10a: converges to one live block across three runs"
    else
        fail "check 10a: expected 1 live block, found $live"
    fi
    sup=$(grep -c 'superseded pre-sentinel recap' "$RECAP_FILE")
    if [[ "$sup" -eq 0 ]]; then
        pass "check 10b: no spurious legacy migration was triggered"
    else
        fail "check 10b: $sup superseded copies filed by re-migration"
    fi
    if grep -qF "escaped: recap heading in source text" "$RECAP_FILE"; then
        pass "check 10c: the heading in source text was escaped"
    else
        fail "check 10c: heading in source text left as a live block header"
    fi
    if grep -qF "tail-after-heading" "$RECAP_FILE"; then
        pass "check 10d: content after the embedded heading survived"
    else
        fail "check 10d: content after the embedded heading was lost"
    fi
fi

# === CHECK 11: the recap and the harvest agree on what a session is =========
# A session holding only machine text is a stub to harvest and gets no note.
# The recap collector used its own, narrower filter, so it listed such sessions
# as activity with nothing to click through to — and paid for an LLM call to
# summarize machinery. The two must stay in agreement.
MACHINE_SESSION="$PROJECTS_DIR/$PROJECT_NAME/machine-only-session.jsonl"
{
    print -r -- '{"type":"summary"}'
    print -r -- "{\"timestamp\":\"${TARGET_DATE}T09:00:00.000Z\",\"gitBranch\":\"main\",\"cwd\":\"$REPOS_DIR_T\"}"
    print -r -- "{\"type\":\"user\",\"timestamp\":\"${TARGET_DATE}T09:01:00.000Z\",\"message\":{\"content\":\"<task-notification>MACHINE-ONLY-MARKER</task-notification>\"}}"
    print -r -- "{\"type\":\"user\",\"timestamp\":\"${TARGET_DATE}T09:02:00.000Z\",\"message\":{\"content\":\"[Request interrupted by user]\"}}"
} > "$MACHINE_SESSION"

rm -f "$RECAP_FILE"
run_recap 1 >/dev/null 2>&1

if [[ ! -f "$RECAP_FILE" ]]; then
    fail "check 11: recap file was not created"
else
    if grep -qF "MACHINE-ONLY-MARKER" "$RECAP_FILE"; then
        fail "check 11a: recap surfaced a machine-only session as activity"
    else
        pass "check 11a: machine-only session kept out of the recap"
    fi
    # It must not be counted either — a "0 prompts" line is the symptom.
    if grep -qE '^- [0-9]{2}:[0-9]{2} — 0 prompts' "$RECAP_FILE"; then
        fail "check 11b: recap listed a session with zero genuine prompts"
    else
        pass "check 11b: no zero-prompt session listed"
    fi
fi
rm -f "$MACHINE_SESSION"

# --- Verdict ----------------------------------------------------------------
print -r -- ""
if [[ "$fails" -eq 0 ]]; then
    print -r -- "ALL CHECKS PASSED"
    exit 0
else
    print -r -- "$fails CHECK(S) FAILED"
    exit 1
fi
