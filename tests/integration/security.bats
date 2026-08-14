#!/usr/bin/env bats
# Regression tests for the specific security issues found in the original
# script: sshpass exposing the plaintext password via argv/ps, and
# unsanitized names being interpolated into shell/regex contexts.

load '../helpers/test_helper'

setup_file() {
    setup_short_home
}

teardown_file() {
    teardown_short_home
}

setup() {
    setup_isolated_env
    setup_test_gpg
}

@test "cmd_remember passes the password to sshpass via -f (process substitution), never -p, so it can't leak through ps" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "s3cr3t-plaintext")"

    fzf_queue "prod/db01"
    cmd_remember

    grep -q -- "-f " "$MOCK_LOG"
    run grep -- "-p " "$MOCK_LOG"
    [ "$status" -ne 0 ]
    run grep -F "s3cr3t-plaintext" "$MOCK_LOG"
    [ "$status" -ne 0 ]

    grep -q "sshpass-received-bytes" "$MOCK_LOG"
}

@test "cmd_ssh copies the decrypted password to the clipboard and connects with the right host, without leaking the password into any command's argv" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "clip-secret")"

    fzf_queue "prod/db01"
    cmd_ssh

    [ "$(cat "$MOCK_CLIPBOARD_FILE")" = "clip-secret" ]
    grep -q "ssh prod/db01" "$MOCK_LOG"
    run grep -F "clip-secret" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

@test "cmd_remember reports failure and returns non-zero when ssh-copy-id fails, instead of claiming success" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "s3cr3t-plaintext")"

    fzf_queue "prod/db01"
    export SSH_COPY_ID_MOCK_EXIT=1
    run cmd_remember

    [ "$status" -ne 0 ]
    [[ "$output" != *"✅"* ]]
    [[ "$output" == *"❌"* ]]
}

@test "a server name attempting shell/regex injection ('$(id)', 'a|b', 'a;b') is rejected by validate_token, never reaching the ssh config" {
    run validate_token '$(id)' "Name"
    [ "$status" -ne 0 ]
    run validate_token 'a|b' "Name"
    [ "$status" -ne 0 ]
    run validate_token 'a;b' "Name"
    [ "$status" -ne 0 ]
    run validate_token 'a`whoami`' "Name"
    [ "$status" -ne 0 ]
}

@test "credentials and ssh config files are created with owner-only permissions by cmd_init" {
    rm -f "$SSH_CONFIG_FILE" "$CRED_FILE"
    cmd_init >/dev/null 2>&1 || true

    [ "$(stat -f '%Lp' "$SSH_CONFIG_FILE" 2>/dev/null || stat -c '%a' "$SSH_CONFIG_FILE")" = "600" ]
    [ "$(stat -f '%Lp' "$CRED_FILE" 2>/dev/null || stat -c '%a' "$CRED_FILE")" = "600" ]
}
