#!/usr/bin/env bash
# setup-automation.sh — Schedule vault recap and vault weekly via cron or launchd
# Run this on each machine after integrating the recap/weekly commands into vault-cli.
#
# Usage:
#   ./setup-automation.sh              # Install scheduling
#   ./setup-automation.sh --uninstall  # Remove scheduling

set -euo pipefail

VAULT_BIN="$HOME/.local/bin/vault"
LOG_DIR="$HOME/.local/log"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"

if [[ ! -x "$VAULT_BIN" ]]; then
    echo "Error: vault not found at $VAULT_BIN" >&2
    echo "Run setup.sh first to install vault-cli." >&2
    exit 1
fi

# ─── macOS: launchd ────────────────────────────────────────────────────────

install_launchd() {
    mkdir -p "$LAUNCHD_DIR" "$LOG_DIR"

    # Daily recap at 11:00 PM
    cat > "$LAUNCHD_DIR/com.vault-cli.recap.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.vault-cli.recap</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VAULT_BIN</string>
        <string>recap</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>23</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/vault-recap.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/vault-recap.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
    </dict>
</dict>
</plist>
PLIST

    # Weekly rollup on Sunday at 11:30 PM
    cat > "$LAUNCHD_DIR/com.vault-cli.weekly.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.vault-cli.weekly</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VAULT_BIN</string>
        <string>weekly</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>23</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/vault-weekly.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/vault-weekly.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
    </dict>
</dict>
</plist>
PLIST

    launchctl load "$LAUNCHD_DIR/com.vault-cli.recap.plist" 2>/dev/null || true
    launchctl load "$LAUNCHD_DIR/com.vault-cli.weekly.plist" 2>/dev/null || true

    echo "Launchd agents installed:"
    echo "  Daily recap:   11:00 PM every day"
    echo "  Weekly rollup: 11:30 PM every Sunday"
}

uninstall_launchd() {
    launchctl unload "$LAUNCHD_DIR/com.vault-cli.recap.plist" 2>/dev/null || true
    launchctl unload "$LAUNCHD_DIR/com.vault-cli.weekly.plist" 2>/dev/null || true
    rm -f "$LAUNCHD_DIR"/com.vault-cli.*.plist
    echo "Launchd agents removed."
}

# ─── Linux/WSL: cron ───────────────────────────────────────────────────────

install_cron() {
    mkdir -p "$LOG_DIR"

    # Remove existing vault-cli cron entries
    crontab -l 2>/dev/null | grep -v 'vault recap\|vault weekly' | crontab - 2>/dev/null || true

    (crontab -l 2>/dev/null; cat <<CRON

# vault-cli: daily recap at 11:00 PM
0 23 * * * /home/cddal/.local/bin/vault recap >> /home/cddal/.local/log/vault-recap.log 2>&1

# vault-cli: weekly rollup at 11:30 PM on Sundays
30 23 * * 0 /home/cddal/.local/bin/vault weekly >> /home/cddal/.local/log/vault-weekly.log 2>&1
CRON
    ) | crontab -

    echo "Cron jobs installed:"
    echo "  Daily recap:   0 23 * * *   /home/cddal/.local/bin/vault recap"
    echo "  Weekly rollup: 30 23 * * 0  /home/cddal/.local/bin/vault weekly"
    echo "  Logs:          /home/cddal/.local/log/vault-{recap,weekly}.log"
}

uninstall_cron() {
    crontab -l 2>/dev/null | grep -v 'vault recap\|vault weekly' | crontab - 2>/dev/null || true
    echo "Cron jobs removed."
}

# ─── Main ───────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing vault automation scheduling..."
    if [[ "$(uname)" == "Darwin" ]]; then
        uninstall_launchd
    else
        uninstall_cron
    fi
    echo "Done."
    exit 0
fi

echo "Setting up vault automation..."
echo "  vault binary: $VAULT_BIN"
echo ""

if [[ "$(uname)" == "Darwin" ]]; then
    install_launchd
else
    install_cron
fi

echo ""
echo "Run manually:"
echo "  vault recap              # today's recap"
echo "  vault recap yesterday    # backfill yesterday"
echo "  vault weekly             # this week's rollup"
