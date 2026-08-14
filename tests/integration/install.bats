#!/usr/bin/env bats
# install.sh is a standalone script (not sourced into the bats process like
# lib/), so these drive it as a real subprocess via `run`, with an isolated
# $HOME so it never touches the developer's real shell rc files.

load '../helpers/test_helper'

setup() {
    HOME="$(mktemp -d "${TMPDIR_SHORT:-/tmp}/sctx-installtest-XXXXXX")"
}

teardown() {
    [[ -n "${HOME:-}" && "$HOME" == /tmp/sctx-installtest-* ]] && rm -rf "$HOME"
}

@test "install.sh installs to a custom dir and adds it to PATH via .bash_profile on macOS bash" {
    local bindir="$HOME/mybin"
    run env -i HOME="$HOME" SHELL="/bin/bash" PATH="/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "$bindir"

    [ "$status" -eq 0 ]
    [ -x "$bindir/server" ]
    [[ "$output" == *"wasn't on your PATH"* ]]
    [[ "$output" == *".bash_profile"* ]]
    grep -qF "mybin" "$HOME/.bash_profile"
}

@test "install.sh is idempotent: running it twice doesn't duplicate the PATH line" {
    local bindir="$HOME/mybin"
    env -i HOME="$HOME" SHELL="/bin/bash" PATH="/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "$bindir" >/dev/null
    env -i HOME="$HOME" SHELL="/bin/bash" PATH="/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "$bindir" >/dev/null

    # The written line uses the portable $HOME-relative form, not the
    # expanded absolute path (see the dedicated test for that below) — grep
    # for the directory's basename, which appears either way.
    [ "$(grep -c "mybin" "$HOME/.bash_profile")" -eq 1 ]
}

@test "install.sh recognizes a pre-existing \$HOME-relative PATH line (not just the literal absolute path) and doesn't duplicate it" {
    # Regression: an earlier version compared only the expanded absolute
    # path against the rc file's contents, so a line written the idiomatic
    # way — literally 'export PATH="$HOME/mybin:$PATH"', dollar sign and
    # all, rather than the expanded path — went undetected and a second,
    # redundant line got appended on every install.
    local bindir="$HOME/mybin"
    echo 'export PATH="$HOME/mybin:$PATH"' > "$HOME/.bash_profile"

    run env -i HOME="$HOME" SHELL="/bin/bash" PATH="/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "$bindir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"already"* ]]
    [ "$(wc -l < "$HOME/.bash_profile" | tr -d ' ')" = "1" ]
}

@test "install.sh detects zsh and writes to .zshrc instead of .bash_profile" {
    local bindir="$HOME/mybin"
    run env -i HOME="$HOME" SHELL="/bin/zsh" PATH="/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "$bindir"

    [ "$status" -eq 0 ]
    [[ "$output" == *".zshrc"* ]]
    grep -qF "mybin" "$HOME/.zshrc"
    [ ! -f "$HOME/.bash_profile" ]
}

@test "install.sh does not touch the rc file when the target dir is already on PATH" {
    local bindir="$HOME/mybin"
    mkdir -p "$bindir"
    run env -i HOME="$HOME" SHELL="/bin/bash" PATH="$bindir:/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "$bindir"

    [ "$status" -eq 0 ]
    [[ "$output" != *"wasn't on your PATH"* ]]
    [ ! -f "$HOME/.bash_profile" ]
}

@test "install.sh gives a clear, actionable error for an unrecognized shell instead of silently doing nothing" {
    local bindir="$HOME/mybin"
    run env -i HOME="$HOME" SHELL="/usr/local/bin/fish" PATH="/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "$bindir"

    [ "$status" -eq 0 ]
    [ -x "$bindir/server" ]
    [[ "$output" == *"export PATH="* ]]
}

@test "install.sh fails with a clear message (not a raw permission error) when the target dir isn't writable" {
    run env -i HOME="$HOME" SHELL="/bin/bash" PATH="/usr/bin:/bin" \
        bash "$ROOT_DIR/install.sh" "/nonexistent-root-only-dir"

    [ "$status" -ne 0 ]
    [[ "$output" == *"isn't writable"* ]]
    [[ "$output" == *"./install.sh /some/writable/dir"* ]]
}
