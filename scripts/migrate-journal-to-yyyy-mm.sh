#!/usr/bin/env zsh
# One-shot migration: journal/*.md → journal/YYYY/MM/*.md
#
# Daily notes (`YYYY-MM-DD.md`) → journal/YYYY/MM/YYYY-MM-DD.md
# Weekly rollups (`week-YYYY-WW.md`) → journal/YYYY/MM/week-YYYY-WW.md
#   where MM is the month the ISO week's Sunday falls in.
#
# Uses `git mv` to preserve history. Idempotent — files already in
# subdirs are skipped. Set DRY=1 to preview without moving.
#
# Required after vault-cli's layout change (commit landed 2026-05-17).
# Vaults set up before that change have a flat journal/ tree; run this
# once per vault clone to move existing files into the new shape.

set -euo pipefail

VAULT_DIR="${VAULT_DIR:-$HOME/projects/vault}"
DRY="${DRY:-0}"

cd "$VAULT_DIR" || { echo "vault not found at $VAULT_DIR" >&2; exit 1; }

local moved=0 skipped=0 errors=0 unknown=0
local -a unknowns=()

for f in journal/*.md(N); do
    local fname="${f##*/}"

    local target=""
    case "$fname" in
        20[0-9][0-9]-[0-9][0-9]-[0-9][0-9].md)
            local year="${fname:0:4}"
            local month="${fname:5:2}"
            target="journal/$year/$month/$fname"
            ;;
        week-20[0-9][0-9]-[0-9][0-9].md)
            local year="${fname:5:4}"
            local week="${fname:10:2}"
            # GNU `date` won't parse ISO-week format directly; use Python.
            # `%G` ISO year, `%V` ISO week, `%u` weekday 1-7 (7 = Sunday).
            local end_date
            end_date=$(python3 -c "from datetime import datetime; print(datetime.strptime('${year}-W${week}-7', '%G-W%V-%u').date())" 2>/dev/null) || {
                echo "ERROR end_date compute failed: $fname" >&2
                errors=$((errors+1))
                continue
            }
            local target_year="${end_date:0:4}"
            local target_month="${end_date:5:2}"
            target="journal/$target_year/$target_month/$fname"
            ;;
        *)
            unknowns+=("$fname")
            unknown=$((unknown+1))
            continue
            ;;
    esac

    # Idempotent skip: already at target.
    if [[ "$f" == "$target" ]]; then
        skipped=$((skipped+1))
        continue
    fi

    if [[ "$DRY" == "1" ]]; then
        echo "$f → $target"
    else
        mkdir -p "$(dirname "$target")"
        git mv "$f" "$target"
    fi
    moved=$((moved+1))
done

echo ""
echo "Summary:"
echo "  Moved:    $moved"
echo "  Skipped:  $skipped  (already at target)"
echo "  Unknown:  $unknown   (pattern not recognized)"
echo "  Errors:   $errors"
if (( unknown > 0 )); then
    echo ""
    echo "Files with unknown patterns:"
    for u in "${unknowns[@]}"; do
        echo "  - $u"
    done
fi

if [[ "$DRY" != "1" ]] && (( moved > 0 )); then
    echo ""
    echo "Done. Run \`vault sync\` to commit + push the moves."
fi
