#!/bin/bash

#!/bin/bash

# Uninstall fzf if installed
if command -v fzf &>/dev/null; then
    echo "🧹 Removing fzf..."
    sudo apt remove --purge -y fzf
    sudo apt autoremove -y
fi

# Uninstall gpg if installed (optional: keep if you use it system-wide)
if command -v gpg &>/dev/null; then
    echo "🧹 Removing GPG..."
    sudo apt remove --purge -y gnupg
    sudo apt autoremove -y
fi

# Remove GPG keyring and config
if [[ -d ~/.gnupg ]]; then
    echo "🗑️ Deleting ~/.gnupg..."
    rm -rf ~/.gnupg
fi

# Remove ~/.ssh files created by script
echo "🗑️ Cleaning ~/.ssh files..."

[[ -f "$HOME/.ssh/config" ]] && rm -f "$HOME/.ssh/config"
[[ -f "$HOME/.ssh/server_credentials" ]] && rm -f "$HOME/.ssh/server_credentials"

# Only remove ~/.ssh if it's empty
if [[ -d "$HOME/.ssh" && -z "$(ls -A "$HOME/.ssh")" ]]; then
    rmdir "$HOME/.ssh"
    echo "🗑️ Removed empty ~/.ssh directory."
fi

echo
echo "✅ Cleanup complete. You can now re-run your script to test fresh behavior."
