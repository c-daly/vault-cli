# GitHub Activity in Daily Recaps

## Problem

Daily recaps only capture local git commits, missing higher-level GitHub activity: PRs opened/merged/closed, issues, code reviews, and new repos. This is especially useful since the user works across multiple machines and repos.

## Design

### New function: `_collect_github_activity`

Collects GitHub events for a target date using `gh api /users/{user}/events`.

**Data sources:**
- `PullRequestEvent` — opened, merged, closed PRs
- `CreateEvent` — new repos (filter `ref_type=repository`)
- `IssuesEvent` — opened, closed issues
- `PullRequestReviewEvent` — code reviews given
- `IssueCommentEvent` — PR/issue comments (count only, not individual)

**Output format (markdown):**
```
**Pull Requests**
- Merged c-daly/agent-swarm#4 `feature/phase-agent-overhaul` (17 comments)
- Opened c-daly/agent-swarm#5 `feature/iterate-refactor`

**Issues**
- Closed c-daly/logos#12 "Testing Sanity"

**New Repos**
- Created c-daly/chiron

**Reviews**
- Reviewed c-daly/logos#479
```

### Integration

- Rename "Git Activity" section to "Git & GitHub" in recap output
- Local commits listed first (existing behavior)
- GitHub events appended below
- PushEvents excluded (already covered by local commits)

### Deduplication

- GitHub events are global (not machine-specific)
- Write a `<!-- github-events -->` HTML comment marker when GitHub section is written
- If marker already present in recap file, skip GitHub collection
- This prevents duplicate GitHub sections when multiple machines run recap

### Dependencies

- `gh` CLI — optional. If not installed or not authenticated, skip with message "*Install gh CLI for GitHub activity*"
- No new config variables needed; GitHub username derived from `gh api user --jq .login`

### Backfill

- GitHub events API returns last 90 days (max 300 events)
- `cmd_backfill` will automatically pick this up for dates within range
- Older dates will simply have no GitHub section

### Error handling

- `gh` not installed → skip gracefully
- `gh` not authenticated → skip gracefully
- API rate limit → skip gracefully with warning
- No events for date → omit section (don't show empty "Pull Requests" etc.)
