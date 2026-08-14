# Shared bats setup: isolated $HOME/config/creds, mocked external tools.
# Load with: load '../helpers/test_helper'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOCK_BIN="$ROOT_DIR/tests/fixtures/mock_bin"

load_lib() {
    source "$ROOT_DIR/lib/os.sh"
    source "$ROOT_DIR/lib/ui.sh"
    source "$ROOT_DIR/lib/crypto.sh"
    source "$ROOT_DIR/lib/sshconfig.sh"
    local f
    for f in "$ROOT_DIR"/lib/commands/*.sh; do
        source "$f"
    done
}

# Fresh $HOME, ssh config, credentials file, mocked PATH. Does NOT set up
# GNUPGHOME/GPG_RECIPIENT — call setup_test_gpg (once per file, it's slow)
# for tests that actually need to encrypt/decrypt.
#
# If setup_file already called setup_short_home (needed by any test file
# that also calls setup_test_gpg), reuse that HOME instead of clobbering it
# with a fresh one on every single test.
setup_isolated_env() {
    if [[ "${HOME:-}" != /tmp/sctx-* ]]; then
        setup_short_home
    fi
    export SSH_CONFIG_FILE="$HOME/.ssh/config"
    export CRED_FILE="$HOME/.ssh/server_credentials"
    : > "$SSH_CONFIG_FILE"
    : > "$CRED_FILE"
    export backup_dir="$BATS_TEST_TMPDIR/serverctx_backup"

    export PATH="$MOCK_BIN:$PATH"
    export MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    export MOCK_CLIPBOARD_FILE="$BATS_TEST_TMPDIR/clipboard"
    : > "$MOCK_LOG"
    : > "$MOCK_CLIPBOARD_FILE"

    unset FZF_MOCK_OUTPUT FZF_MOCK_QUEUE PING_MOCK_FAIL_HOSTS SSH_COPY_ID_MOCK_EXIT SCP_MOCK_EXIT SFTP_MOCK_ROOT SFTP_MOCK_EXIT

    load_lib
}

# Generates a throwaway ed25519 GPG key with no passphrase, once per bats
# *file* (BATS_FILE_TMPDIR persists across tests in the same file, unlike
# BATS_TEST_TMPDIR). Never touches the real user keyring.
#
# Uses $HOME/.gnupg (not some other scratch path) because cmd_backup and
# cmd_restore hardcode ~/.gnupg to match gpg's own default — same as real
# usage, where GNUPGHOME is normally unset.
setup_test_gpg() {
    export GNUPGHOME="$HOME/.gnupg"
    export GPG_RECIPIENT="serverctx-test@example.com"
    if [[ ! -d "$GNUPGHOME" ]]; then
        mkdir -p "$GNUPGHOME"
        chmod 700 "$GNUPGHOME"
        gpg --batch --pinentry-mode loopback --passphrase '' \
            --quick-generate-key "$GPG_RECIPIENT" default default never &>/dev/null
    fi
}

# Each argument is one fzf invocation's worth of output ("a turn"). A turn
# can itself contain embedded newlines — pass e.g. $'c\nsomefile' to
# reproduce fzf's own multi-line --expect output (pressed key on one line,
# selection on the next), as real `fzf --expect=c,enter` would return after
# the user pressed 'c' on "somefile".
fzf_queue() {
    local queue_file="$BATS_TEST_TMPDIR/fzf_queue"
    : > "$queue_file"
    local turn
    for turn in "$@"; do
        printf '%s\n@@FZF_TURN_END@@\n' "$turn" >> "$queue_file"
    done
    export FZF_MOCK_QUEUE="$queue_file"
}

# bats' own tmpdir lives under macOS's $TMPDIR (/var/folders/.../T/...),
# which is deep enough that GNUPGHOME=$HOME/.gnupg pushes gpg-agent's
# longest auxiliary socket name (S.gpg-agent.browser) past the ~104-byte
# sockaddr_un limit — gpg-agent then fails to start at all ("IPC connect
# call failed"). Tests that need a real GPG keyring (setup_test_gpg) must
# use a short HOME instead of the usual $BATS_FILE_TMPDIR-based one.
setup_short_home() {
    HOME="$(mktemp -d "${TMPDIR_SHORT:-/tmp}/sctx-XXXXXX")"
    export HOME
    mkdir -p "$HOME/.ssh"
}

teardown_short_home() {
    [[ -n "${HOME:-}" && "$HOME" == /tmp/sctx-* ]] && rm -rf "$HOME"
}

# Runs a shell function with piped stdin, for testing functions that mix
# `read -rp` prompts with fzf selections. Deliberately NOT `bash -c "..."`:
# that execs a brand-new interpreter, which doesn't inherit this process's
# sourced functions (cmd_download etc.) — a plain pipeline's subshells do,
# since they're forked, not exec'd. Usage: run with_stdin $'\n' cmd_download
with_stdin() {
    local input="$1"
    shift
    printf '%s' "$input" | "$@"
}
