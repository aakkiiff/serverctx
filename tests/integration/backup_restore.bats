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
    setup_test_gpg
}

@test "cmd_backup writes ssh_config, credentials, and keys into backup_dir without sudo" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"
    mkdir -p "$HOME/.ssh/keys/prod"
    echo "fake-key-material" > "$HOME/.ssh/keys/prod/db01"
    chmod 600 "$HOME/.ssh/keys/prod/db01"

    run cmd_backup
    [ "$status" -eq 0 ]
    [[ "$output" != *"sudo"* ]]

    [ -f "$backup_dir/ssh_config" ]
    [ -f "$backup_dir/server_credentials" ]
    [ -f "$backup_dir/ssh-keys-backup.tar" ]
    [ -f "$backup_dir/gnupg-backup.tar" ]
    grep -qF "Host prod/db01" "$backup_dir/ssh_config"
}

@test "cmd_backup then cmd_restore round-trips config, credentials, and keys into a fresh HOME" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"
    mkdir -p "$HOME/.ssh/keys/prod"
    echo "fake-key-material" > "$HOME/.ssh/keys/prod/db01"

    cmd_backup

    # Deep bats tmp paths (BATS_TEST_TMPDIR) reproduce the gpg-agent
    # socket-path-too-long failure seen elsewhere in this suite — use a
    # short /tmp path here too, and clean it up ourselves since it isn't
    # covered by setup_short_home/teardown_short_home.
    local restored_home
    restored_home="$(mktemp -d /tmp/sctx-restored-XXXXXX)"
    export HOME="$restored_home"
    export SSH_CONFIG_FILE="$HOME/.ssh/config"
    export CRED_FILE="$HOME/.ssh/server_credentials"

    printf '%s\ny\n' "$backup_dir" | cmd_restore

    [ "$(cat "$SSH_CONFIG_FILE")" = "$(cat "$backup_dir/ssh_config")" ]
    grep -qF "Host prod/db01" "$SSH_CONFIG_FILE"
    [ "$(cred_get "prod/db01")" != "" ]
    [ -f "$HOME/.ssh/keys/prod/db01" ]
    [ "$(cat "$HOME/.ssh/keys/prod/db01")" = "fake-key-material" ]

    # The restored .gnupg must contain working key material, not just an
    # emptied directory: point GNUPGHOME at the newly-restored location and
    # confirm the credential decrypts through it end-to-end.
    export GNUPGHOME="$HOME/.gnupg"
    [ "$(decrypt_password "$(cred_get "prod/db01")")" = "secret123" ]

    rm -rf "$restored_home"
}

@test "cmd_restore expands a ~/-prefixed import directory (regression: [[ -d ]] doesn't expand ~ from a variable)" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    cmd_backup
    cp -r "$backup_dir" "$HOME/my_backup_copy"

    : > "$SSH_CONFIG_FILE"
    : > "$CRED_FILE"

    printf '~/my_backup_copy\ny\n' | cmd_restore

    grep -qF "Host prod/db01" "$SSH_CONFIG_FILE"
}
