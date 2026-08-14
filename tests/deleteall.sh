#!/usr/bin/env bash
# Manual reset helper for local testing: uninstalls dependencies and wipes
# everything `server init`/`server add` create, so you can re-test from a
# clean slate. Not part of the automated test suite (see tests/unit and
# tests/integration for that) — this touches your real ~/.ssh and ~/.gnupg.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/os.sh"

uninstall_pkg() {
    local pkg="$1"
    if [[ "$OS_TYPE" == "mac" ]]; then
        command -v brew &>/dev/null && brew uninstall "$pkg" 2>/dev/null
    else
        sudo apt remove --purge -y "$pkg" && sudo apt autoremove -y
    fi
}

if command -v fzf &>/dev/null; then
    echo "🧹 Removing fzf..."
    uninstall_pkg fzf
fi

if command -v gpg &>/dev/null; then
    echo "🧹 Removing GPG..."
    uninstall_pkg gnupg
fi

if [[ -d ~/.gnupg ]]; then
    echo "🗑️ Deleting ~/.gnupg..."
    rm -rf ~/.gnupg
fi

echo "🗑️ Cleaning ~/.ssh files..."
[[ -f "$HOME/.ssh/config" ]] && rm -f "$HOME/.ssh/config"
[[ -f "$HOME/.ssh/server_credentials" ]] && rm -f "$HOME/.ssh/server_credentials"
[[ -d "$HOME/.ssh/keys" ]] && rm -rf "$HOME/.ssh/keys"

# Only remove ~/.ssh if it's empty
if [[ -d "$HOME/.ssh" && -z "$(ls -A "$HOME/.ssh")" ]]; then
    rmdir "$HOME/.ssh"
    echo "🗑️ Removed empty ~/.ssh directory."
fi

echo
echo "✅ Cleanup complete. You can now re-run your script to test fresh behavior."
