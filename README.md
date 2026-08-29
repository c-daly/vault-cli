# vault-cli

A terminal-native CLI for [Obsidian](https://obsidian.md) vaults. Capture notes, search your vault, and harvest Claude Code session data — all without leaving the terminal.

Built for people who live in the terminal but want a second brain.

## Why

Obsidian is great for linking and visualizing notes, but opening a GUI app to jot something down is too much friction. `vault-cli` gives you a fast capture-and-retrieve workflow from the terminal, while keeping everything as plain markdown that Obsidian can read.

## Commands

| Command | Description |
|---------|-------------|
| `vault add "thought"` | Quick capture to today's captures file (`00-inbox/<date>.md`) |
| `vault add "idea" -t project` | Capture with category tag (`fleeting`, `project`, `learning`) |
| `vault process` | Open today's captures in your editor to review and tag |
| `vault process --commit` | Split tagged entries into individual notes in the right folders |
| `vault edit [-t type]` | Create a new note from template and open in editor |
| `vault daily` | Create or open today's daily note (`journal/<date>.md`) |
| `vault search [query]` | Search vault with ripgrep + fzf (content and filenames) |
| `vault recent [N]` | Show N most recently modified notes (default: 10) |
| `vault harvest [--all] [--project N] [--sync] [--keep-stubs] [--memory\|--no-memory]` | Import Claude Code session metadata as vault notes (skips stub sessions — `/exit`-only or opened-and-quit — unless `--keep-stubs`), then mirror built-in auto-memory. `--memory` mirrors only (seconds, no session scan); `--no-memory` skips the mirror |
| `vault recap [today\|yesterday\|DATE]` | Generate daily recap from activity (writes only — run `sync` after) |
| `vault weekly [end-date]` | Weekly rollup from daily recaps (writes only — run `sync` after) |
| `vault backfill` | Generate recaps for all past dates with activity (writes only — run `sync` after) |
| `vault sync` | `git add -A` + commit + `pull --rebase` + push |
| `vault help` | Show usage |

### What `recap` actually bundles

`vault recap` is a composite command, not a single action. A single invocation runs:

1. `git pull --rebase --quiet` on the vault, so the recap reflects the latest synced state.
2. `vault harvest` (no flags), which scans `$VAULT_CLAUDE_DIRS/*/*.jsonl` and writes/updates session-metadata notes under `30-resources/claude-sessions/`, then mirrors built-in per-project auto-memory (`<root>/<project>/memory/*.md`) into `30-resources/claude-memory/`. Both halves are idempotent — re-runs leave unchanged files alone.

   The auto-memory mirror is verbatim and read-only. Claude's built-in store is keyed by working directory and has no `subject` field, so an entry can be *about the user* yet live under whichever project it was learned in. The mirror preserves that rather than guessing a subject; curating across projects belongs to the continuity plugin.
3. Activity collection: shell history (`$HISTFILE`), git commit log across `$VAULT_REPOS_DIR` (default `~/projects`), GitHub PRs/issues via `gh`, today's captures from `00-inbox/`, Claude session summaries (local-day bucketing), and calendar entries if `gcalcli` is installed.
4. Writes the recap markdown to `journal/<date>.md`. First run for a date writes in *fresh* mode (unwrapped); subsequent runs splice an `## Auto-Recap (<host>)` wrapped block in *replace* or *append* mode.
5. Appends the same activity to the [event log](#event-log).

#### Why the block has an explicit terminator

An `## Auto-Recap (<host>)` block ends at `<!-- /auto-recap -->`, and replace mode splices only up to that marker. It exists because the block's own sources are embedded verbatim — inbox captures, commit subjects, calendar titles, mail headers — so any in-band delimiter can occur inside the content it is supposed to bound. A bare `---` was the original terminator and a capture containing one truncated the block.

Two consequences worth knowing:

- **Both markers are escaped in generated content.** A source line equal to the terminator, or one opening `## Auto-Recap (`, is rewritten to a visibly escaped form, so the markers only ever appear where the tool emits them. Escaping is visible in the note rather than silent.
- **Pre-sentinel blocks are migrated, not guessed at.** A block written before the terminator existed has no unambiguous end. It is not spliced: the new block is written, the old region is preserved verbatim beneath a marker with its header neutralized to `## (superseded) Auto-Recap (<host>)`, and a `.pre-recap.bak` is kept. Nothing is deleted; the duplication is explicit, one-time, and converges on the next run once you delete the marked region.

The recap **does not commit or push.** Run `vault sync` when you want the changes published. Same for `weekly` and `backfill`.

`vault harvest --sync` is the only harvest command that also calls `vault sync` after — useful from cron/hooks where there's no human to invoke sync separately.

## Install

```bash
git clone https://github.com/c-daly/vault-cli.git
cd vault-cli
./setup.sh
```

Setup will:
- Symlink `vault` into `~/.local/bin/`
- Create a config file at `~/.config/vault-cli/config`
- Install zsh completions

You'll need to set `VAULT_DIR` in the config to point to your Obsidian vault:

```bash
# ~/.config/vault-cli/config
VAULT_DIR="/path/to/your/obsidian/vault"
```

### Dependencies

- **zsh** — shell (the script uses zsh features)
- **git** — for sync and recent
- **ripgrep** (`rg`) — for search
- **fzf** — for fuzzy selection in search
- **nvim** (or any `$EDITOR`) — for editing notes
- **jq** — for harvest (Claude Code session parsing)
- **gcalcli** (optional) — for Google Calendar in recaps (`pip install gcalcli`)

All common tools, likely already installed. On Ubuntu/Debian:

```bash
sudo apt install ripgrep fzf jq
```

## Workflow

### Quick capture

```bash
vault add "idea about graph architectures"
vault add "look into OTEL exporters" -t learning
vault add "refactor the API layer" -t project
```

Everything goes into a daily file at `00-inbox/YYYY-MM-DD.md` with timestamps.

### Review and promote

```bash
vault process          # opens daily file in editor — delete junk, confirm tags
vault process --commit # splits remaining entries into individual note files
```

Entries tagged `> project` go to `10-projects/`, `> learning` to `30-resources/`, untagged to `00-inbox/`. Entries with `> ?category` (question mark prefix) are skipped as unconfirmed.

### Search and browse

```bash
vault search "LOGOS"   # content search with preview
vault search           # browse all files
vault recent 5         # last 5 modified notes
```

### Sync across machines

```bash
vault sync
```

Commits with hostname and timestamp, pulls with rebase, pushes. Run on each machine to stay in sync.

### Harvest Claude Code sessions

```bash
vault harvest                    # new sessions since last run, then mirror auto-memory
vault harvest --all              # re-harvest everything
vault harvest --memory           # mirror auto-memory only (seconds)
vault harvest --project LOGOS    # filter by project name
vault harvest --sync             # harvest + sync in one
```

Walks the session transcripts under every root in `VAULT_CLAUDE_DIRS` (default `~/.claude/projects`) and creates a markdown note per session with summary, first prompt, duration, and a link to the full JSONL transcript. It does not depend on `sessions-index.json`, which Claude Code 2.x no longer writes.

Three kinds of transcript are skipped and reported in the summary line:

- **stubs** — sessions with no genuine typed input;
- **narrator** runs — the `claude -p` calls the daily narrative makes, which would otherwise be ingested as if they were your own sessions;
- **subagents** — they get [events](#event-log), carrying `is_subagent` and `parent_session`, but no note of their own. They had grown to 55% of every session note in the vault (89% in some months) and each was *larger* than a real session note, so the browsable record was mostly agent-internal work. The parent note still lists which subagents ran.

Notes written for subagents by earlier versions are left alone rather than deleted — for sessions old enough that Claude has pruned the transcript, that note is the only surviving copy. Relocating them under `claude-sessions/subagents/` is a separate, reversible step.

## Event log

Alongside the markdown, `harvest` and `recap` append a machine-readable record:

```
$VAULT_DIR/events/<host>/YYYY-MM.jsonl
```

Notes are a rendered view; this is the thing they are a view *of*. Nothing here parses a note — events come from the session transcripts and from git directly — so the note format stays free to change without breaking a query.

One JSON object per line, with a deliberately narrow envelope and an opaque source-specific `payload`:

```json
{"id":"session:5c66eace…:2026-06-30T21:48:32Z","ts":"…","local_date":"2026-06-30",
 "host":"PROMETHEUS","source":"claude-session","tier":"observed","payload":{…}}
```

| id | what it records |
|---|---|
| `session:<sid>:<last_ts>` | a work session — duration, turns, title |
| `segment:<sid>:<start>:<end>` | a `(cwd, branch)` interval within it |
| `artifact:<sid>:<path>` | a file written, stamped at the write |
| `commit:<sha>` | a commit, from the git scan |

Four properties worth knowing:

- **Per-host directories.** Two machines appending on the same day touch different files, so `vault sync`'s `pull --rebase` stays a fast-forward and no host's writes are lost.
- **Content-derived ids, per-event dedup.** `backfill` re-derives every date on every run; dedup is what makes that converge instead of doubling history. Ids carry end state, so a session harvested while still running can supersede its own earlier observation — read the log by taking the newest event per `payload.session_id`.
- **Machine-independent thread keys.** `payload.thread` is the repo's identity derived from its origin remote (`github.com/owner/repo`), not a path, so the same repo joins across clones and machines. A directory with no remote falls back to a deliberately host-scoped key. The raw `cwd`/`path` is always kept alongside.
- **Derivations are versioned, not migrated.** If the derivation changes, regenerate rather than rewriting: filter each partition to `select(.source=="git")` and re-run `harvest` (which does not narrate), then `backfill` for commits.

Set `VAULT_NO_EVENTS=1` to write notes without touching the log, or `VAULT_EVENTS_DIR` to keep it outside the vault.

## Vault structure

`vault-cli` expects (and works with) a PARA-style vault layout:

```
vault/
├── 00-inbox/          # Quick captures and fleeting notes
├── 10-projects/       # Active projects
├── 20-areas/          # Areas of responsibility
├── 30-resources/      # Reference materials
├── 40-archive/        # Archived content
├── journal/           # Daily notes
├── events/            # Append-only event log, per host (see above)
└── _templates/        # Note templates (daily.md, project.md, fleeting.md, learning.md)
```

`harvest` also writes session notes to `30-resources/claude-sessions/YYYY-MM/` and mirrors Claude's built-in auto-memory to `30-resources/claude-memory/`.

Templates use Obsidian's `{{date}}` and `{{title}}` syntax. If a template doesn't exist, a sensible default is used.

## Multi-machine setup

Since `vault-cli` works with a git-backed vault:

1. Clone the vault repo on each machine
2. Install `vault-cli` on each machine (or keep it in the vault at `.vault-cli/`)
3. Set `VAULT_DIR` in each machine's config
4. Use `vault sync` to keep everything in sync

Harvested Claude Code sessions are tagged with the machine's hostname so you know which machine each session came from.

### Automated daily recaps

```bash
vault recap              # generate today's recap
vault recap yesterday    # backfill yesterday
vault recap 2026-02-20   # specific date
```

Collects git commits (across all repos in `VAULT_REPOS_DIR`), Claude Code sessions, shell history highlights, Google Calendar events, and `vault add` captures into a daily note at `journal/YYYY-MM-DD.md`. Pulls the vault before writing and pushes after, so all machines contribute.

If a daily note already exists (e.g., from `vault daily` or another machine), the recap appends under a separator rather than overwriting.

### Weekly rollups

```bash
vault weekly             # this week
vault weekly 2026-02-23  # week ending on a specific date
```

Reads the past 7 days of daily recaps and produces `journal/week-YYYY-WW.md` with stats, per-repo/project breakdowns, links to daily notes, and reflection prompts.

### Scheduling

Run `setup-automation.sh` on each machine to schedule recaps automatically:

```bash
./setup-automation.sh              # install (cron on Linux/WSL, launchd on macOS)
./setup-automation.sh --uninstall  # remove
```

Default: daily recap at 11 PM, weekly rollup at 11:30 PM Sundays. Logs to `~/.local/log/`.

## Configuration

Config file: `~/.config/vault-cli/config`

```bash
# Required: path to your Obsidian vault
VAULT_DIR="/path/to/vault"

# Optional: override editor (defaults to $EDITOR, then nvim)
VAULT_EDITOR="nvim"

# Recap: where to scan for git repos (colon-separated for multiple dirs)
VAULT_REPOS_DIR="$HOME/projects"

# Recap: enable Google Calendar (requires gcalcli)
VAULT_GCAL_ENABLED="true"

# Recap/harvest source roots. Colon-separated, non-existent roots skipped, so
# one config works across machines. Needed on WSL to see Windows-side repos and
# sessions started from PowerShell — the defaults only look at $HOME.
VAULT_REPOS_DIR="$HOME/projects:/mnt/c/Users/<user>"
VAULT_CLAUDE_DIRS="$HOME/.claude/projects:/mnt/c/Users/<user>/.claude/projects"

# Daily narrative (LLM diary summary)
NARRATE=1                 # 0 disables
NARRATE_MODEL="haiku"
NARRATE_TIMEOUT=60
VAULT_NARRATE_CWD="${TMPDIR:-/tmp}/vault-cli-narrate"   # narrator transcripts land here, and harvest skips them

# Gmail diary source (app-password IMAP; empty disables)
VAULT_GMAIL_USER=""
VAULT_GMAIL_APP_PASSWORD=""
GMAIL_TIMEOUT=20          # socket timeout, else a stalled server hangs the recap

# Event log
VAULT_EVENTS_DIR="$VAULT_DIR/events"
VAULT_NO_EVENTS=1         # write notes without touching the log
```

See `config.example` for the same set with commentary.

## License

MIT
