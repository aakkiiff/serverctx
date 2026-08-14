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

@test "cmd_editgroup renames a group across config, credentials, and key files" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"
    mkdir -p "$HOME/.ssh/keys/prod"
    echo "keydata" > "$HOME/.ssh/keys/prod/db01"

    fzf_queue "prod"
    printf 'staging\ny\n' | cmd_editgroup

    run host_exists "staging/db01"
    [ "$status" -eq 0 ]
    run host_exists "prod/db01"
    [ "$status" -ne 0 ]

    [ "$(decrypt_password "$(cred_get "staging/db01")")" = "secret123" ]
    [ -f "$HOME/.ssh/keys/staging/db01" ]
    [ ! -f "$HOME/.ssh/keys/prod/db01" ]
}

@test "cmd_editgroup updates a host's IdentityFile path to follow the group rename" {
    local keypath
    keypath="$(keyfile_path "prod" "db01")"
    mkdir -p "$(dirname "$keypath")"
    echo "keydata" > "$keypath"
    host_append_block "prod/db01" "10.0.0.5" "root" "22" "$keypath"

    fzf_queue "prod"
    printf 'staging\ny\n' | cmd_editgroup

    [ "$(host_get_field "staging/db01" "IdentityFile")" = "$(keyfile_path "staging" "db01")" ]
    [ -f "$(keyfile_path "staging" "db01")" ]
}

@test "cmd_editgroup does not affect a group that only shares a text prefix (prod vs production)" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "production/web01" "10.0.0.6" "root" "22"

    fzf_queue "prod"
    printf 'staging\ny\n' | cmd_editgroup

    run host_exists "staging/db01"
    [ "$status" -eq 0 ]
    run host_exists "production/web01"
    [ "$status" -eq 0 ]
    run host_exists "staging/web01"
    [ "$status" -ne 0 ]
}
