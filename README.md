# vault-cli

A terminal-native CLI for [Obsidian](https://obsidian.md) vaults. Capture notes, search your vault, and harvest Claude Code session data — all without leaving the terminal.

Built for people who live in the terminal but want a second brain.

## Why

Obsidian is great for linking and visualizing notes, but opening a GUI app to jot something down is too much friction. `vault-cli` gives you a fast capture-and-retrieve workflow from the terminal, while keeping everything as plain markdown that Obsidian can read.

## Commands

| Command | Description |
|---------|-------------|
| `vault add "thought"` | Quick capture to today's daily file |
| `vault add "idea" -t project` | Capture with category tag (`fleeting`, `project`, `learning`) |
| `vault process` | Open today's captures in your editor to review and tag |
| `vault process --commit` | Split tagged entries into individual notes in the right folders |
| `vault edit [-t type]` | Create a new note from template and open in editor |
| `vault daily` | Create or open today's daily note |
| `vault search [query]` | Search vault with ripgrep + fzf (content and filenames) |
| `vault recent [N]` | Show N most recently modified notes (default: 10) |
| `vault harvest` | Import Claude Code session metadata as vault notes |
| `vault sync` | Git add, commit, pull --rebase, push |
| `vault help` | Show usage |

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
vault harvest                    # new sessions since last run
vault harvest --all              # re-harvest everything
vault harvest --project LOGOS    # filter by project name
vault harvest --sync             # harvest + sync in one
```

Reads `~/.claude/projects/*/sessions-index.json` and creates a markdown note per session with summary, first prompt, duration, and a link to the full JSONL transcript.

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
└── _templates/        # Note templates (daily.md, project.md, fleeting.md, learning.md)
```

Templates use Obsidian's `{{date}}` and `{{title}}` syntax. If a template doesn't exist, a sensible default is used.

## Configuration

Config file: `~/.config/vault-cli/config`

```bash
# Required: path to your Obsidian vault
VAULT_DIR="/path/to/vault"

# Optional: override editor (defaults to $EDITOR, then nvim)
VAULT_EDITOR="nvim"
```

## Multi-machine setup

Since `vault-cli` works with a git-backed vault:

1. Clone the vault repo on each machine
2. Install `vault-cli` on each machine (or keep it in the vault at `.vault-cli/`)
3. Set `VAULT_DIR` in each machine's config
4. Use `vault sync` to keep everything in sync

Harvested Claude Code sessions are tagged with the machine's hostname so you know which machine each session came from.

## License

MIT
