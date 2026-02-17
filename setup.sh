#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_SCRIPT="$SCRIPT_DIR/vault"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vault-cli"
BIN_DIR="$HOME/.local/bin"

echo "Vault CLI Setup"
echo "==============="

# Ensure bin directory exists and is in PATH
mkdir -p "$BIN_DIR"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "Warning: $BIN_DIR is not in your PATH"
    echo "Add to your .zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# Symlink the vault script
ln -sf "$VAULT_SCRIPT" "$BIN_DIR/vault"
echo "Linked: $BIN_DIR/vault -> $VAULT_SCRIPT"

# Create config if it doesn't exist
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config" ]]; then
    # Auto-detect vault dir: the repo this script lives in
    VAULT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    cat > "$CONFIG_DIR/config" <<EOF
# Vault CLI configuration
VAULT_DIR="$VAULT_DIR"
EOF
    echo "Created config: $CONFIG_DIR/config (VAULT_DIR=$VAULT_DIR)"
else
    echo "Config already exists: $CONFIG_DIR/config"
fi

chmod +x "$VAULT_SCRIPT"

# Install zsh completions
COMP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/completions"
mkdir -p "$COMP_DIR"
ln -sf "$SCRIPT_DIR/completions.zsh" "$COMP_DIR/_vault"
echo "Linked completions: $COMP_DIR/_vault"
echo ""
echo "Add to .zshrc if not already present:"
echo '  fpath=("$HOME/.local/share/zsh/completions" $fpath)'
echo '  autoload -Uz compinit && compinit'
echo ""
echo "Done! Run 'vault help' to get started."
