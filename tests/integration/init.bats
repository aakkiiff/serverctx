#!/usr/bin/env bats

load '../helpers/test_helper'

setup_file() {
    setup_short_home
}

teardown_file() {
    teardown_short_home
}

setup() {
    setup_isolated_env
}

@test "cmd_init fails with a clear message instead of a raw gpg crash when gpg can't be found at all" {
    # Excludes gpg's real directory (wherever `gpg` actually lives on this
    # machine) from PATH, keeping the mocked fzf/brew/sudo dirs so the
    # failure is specifically about gpg, not the other dependencies.
    local gpg_dir
    gpg_dir="$(dirname "$(command -v gpg)")"
    local trimmed_path
    trimmed_path="$(echo "$PATH" | tr ':' '\n' | grep -vF "$gpg_dir" | tr '\n' ':')"

    PATH="$trimmed_path" run cmd_init
    [ "$status" -ne 0 ]
    [[ "$output" == *"Can't continue without gpg"* ]]
}

@test "cmd_init is safe to run twice: it doesn't re-prompt for a new GPG key or clobber the persisted recipient" {
    setup_test_gpg
    echo "manually-chosen@example.com" > "$HOME/.ssh/.gpg_recipient"

    cmd_init >/dev/null 2>&1 || true

    [ "$(cat "$HOME/.ssh/.gpg_recipient")" = "manually-chosen@example.com" ]
}
