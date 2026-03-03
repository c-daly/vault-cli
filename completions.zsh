#compdef vault

_vault() {
    local -a commands
    commands=(
        'add:Quick capture to daily file'
        'process:Review and categorize captures'
        'edit:Create note from template in editor'
        'daily:Create/open today'\''s daily note'
        'search:Search vault with fzf + ripgrep'
        'sync:Git commit + pull + push'
        'harvest:Import Claude Code sessions'
        'recent:Show recently modified notes'
        'recap:Auto-generate daily recap from activity'
        'weekly:Weekly rollup from daily recaps'
        'help:Show help'
    )

    if (( CURRENT == 2 )); then
        _describe 'command' commands
    fi
}

_vault "$@"
