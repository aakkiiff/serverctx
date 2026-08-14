#!/usr/bin/env bash
# Builds dist/server (if needed) and installs it to a directory on PATH.
# Usage: ./install.sh [install-dir]   (default: /usr/local/bin, falls back
# to ~/.local/bin if /usr/local/bin isn't writable without sudo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
    Darwin|Linux) : ;;
    *) echo "❌ Unsupported OS: $(uname -s). serverctx supports macOS and Ubuntu/Debian." >&2; exit 1 ;;
esac

# Adds $1 to PATH via the user's shell startup file if it isn't already
# there. A fresh ~/.local/bin install is otherwise invisible until the user
# manually edits their shell config and opens a new terminal — which is
# exactly the "command not found" trap this exists to avoid.
ensure_path_entry() {
    local dir="$1"
    case ":$PATH:" in
        *":$dir:"*) return 0 ;; # already on PATH this session, nothing to do
    esac

    # A dir under $HOME is written (and searched for) in its $HOME-relative
    # form — "$HOME/.local/bin", literally, dollar sign and all — since
    # that's the idiomatic way to write such a line and how a human (or an
    # earlier run of this script, or a dotfile manager) most likely already
    # wrote it. Comparing only the absolute form would miss that existing
    # line and append a redundant, functionally-duplicate one.
    local dir_portable="$dir"
    if [[ "$dir" == "$HOME"/* ]]; then
        dir_portable="\$HOME${dir#"$HOME"}"
    fi

    local shell_name rc_file=""
    shell_name="$(basename "${SHELL:-}")"
    case "$shell_name" in
        zsh) rc_file="$HOME/.zshrc" ;;
        bash)
            # Terminal.app opens login shells on macOS, which read
            # .bash_profile, not .bashrc; most Linux terminals open
            # non-login shells, which read .bashrc.
            if [[ "$(uname -s)" == "Darwin" ]]; then
                rc_file="$HOME/.bash_profile"
            else
                rc_file="$HOME/.bashrc"
            fi
            ;;
    esac

    if [[ -z "$rc_file" ]]; then
        echo "⚠️  $dir isn't on your PATH, and '$shell_name' isn't a shell I can configure"
        echo "   automatically. Add this to its startup file yourself:"
        echo "   export PATH=\"$dir:\$PATH\""
        return 0
    fi

    if [[ -f "$rc_file" ]] && { grep -qF "$dir" "$rc_file" 2>/dev/null || grep -qF "$dir_portable" "$rc_file" 2>/dev/null; }; then
        echo "⚠️  $dir isn't on your PATH in this terminal session, but it's already"
        echo "   configured in $rc_file — open a new terminal, or run: source $rc_file"
        return 0
    fi

    touch "$rc_file"
    { echo ""; echo "export PATH=\"$dir_portable:\$PATH\""; } >> "$rc_file"
    echo "⚠️  $dir wasn't on your PATH — added it to $rc_file."
    echo "   Open a new terminal, or run: source $rc_file"
}

"$SCRIPT_DIR/build.sh"

install_dir="${1:-/usr/local/bin}"
if [[ "${1:-}" == "" ]] && [[ ! -w "$install_dir" ]]; then
    install_dir="$HOME/.local/bin"
    echo "⚠️  /usr/local/bin isn't writable; installing to $install_dir instead."
fi

if ! mkdir -p "$install_dir" 2>/dev/null || [[ ! -w "$install_dir" ]]; then
    echo "❌ '$install_dir' isn't writable. Pass a writable directory instead:" >&2
    echo "   ./install.sh /some/writable/dir" >&2
    exit 1
fi

cp "$SCRIPT_DIR/dist/server" "$install_dir/server"
chmod +x "$install_dir/server"

echo "✅ Installed to $install_dir/server"

ensure_path_entry "$install_dir"

echo "Run 'server init' to get started."
