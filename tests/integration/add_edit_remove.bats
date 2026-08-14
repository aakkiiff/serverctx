#!/usr/bin/env bats
# End-to-end: drives cmd_add / cmd_edit / cmd_remove through their real
# `read -rp` prompts (via heredoc stdin) and real fzf-selection points (via
# the queued fzf mock), against a throwaway GPG key and temp config/cred
# files. Never touches the developer's real ~/.ssh or ~/.gnupg.

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

@test "cmd_add creates a host block and an encrypted credential" {
    cmd_add <<'INPUT'
db01
prod
10.0.0.5
root

secret123
INPUT

    run host_exists "prod/db01"
    [ "$status" -eq 0 ]
    [ "$(host_get_field "prod/db01" "HostName")" = "10.0.0.5" ]
    [ "$(host_get_field "prod/db01" "User")" = "root" ]
    [ "$(host_get_field "prod/db01" "Port")" = "22" ]

    run cred_exists "prod/db01"
    [ "$status" -eq 0 ]
    [ "$(decrypt_password "$(cred_get "prod/db01")")" = "secret123" ]
}

@test "cmd_add rejects a duplicate host without touching the existing entry" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"

    run cmd_add <<'INPUT'
db01
prod
10.0.0.9
root

newpass
INPUT

    [ "$(host_get_field "prod/db01" "HostName")" = "10.0.0.5" ]
}

@test "cmd_add retries on an invalid server name ('/' would break group/name parsing) and accepts the next valid one" {
    cmd_add <<'INPUT'
bad/name
db01
prod
10.0.0.5
root

secret123
INPUT

    run host_exists "prod/db01"
    [ "$status" -eq 0 ]
    run grep -qF "bad/name" "$SSH_CONFIG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_add with a private key (no password) writes an IdentityFile pointing at the saved key" {
    local keysrc="$BATS_TEST_TMPDIR/id_test_key"
    printf 'fake-key-data' > "$keysrc"

    cmd_add <<INPUT
db01
prod
10.0.0.5
root


$keysrc
INPUT

    local keypath
    keypath="$(keyfile_path "prod" "db01")"
    [ -f "$keypath" ]
    [ "$(host_get_field "prod/db01" "IdentityFile")" = "$keypath" ]
}

@test "cmd_add expands a ~/-prefixed private key path (regression: [[ -f ]] doesn't expand ~ from a variable)" {
    printf 'fake-key-data' > "$HOME/my_test_key"

    cmd_add <<'INPUT'
db03
prod
10.0.0.7
root


~/my_test_key
INPUT

    local keypath
    keypath="$(keyfile_path "prod" "db03")"
    [ -f "$keypath" ]
    [ "$(cat "$keypath")" = "fake-key-data" ]
}

@test "cmd_remove deletes the config block, credential, and key file for the selected host" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"
    mkdir -p "$HOME/.ssh/keys/prod"
    : > "$HOME/.ssh/keys/prod/db01"

    fzf_queue "prod/db01"
    cmd_remove <<< "y"

    run host_exists "prod/db01"
    [ "$status" -ne 0 ]
    run cred_exists "prod/db01"
    [ "$status" -ne 0 ]
    [ ! -f "$HOME/.ssh/keys/prod/db01" ]
}

@test "cmd_remove only removes the selected host, leaving siblings in the same group intact" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "prod/web01" "10.0.0.6" "root" "22"

    fzf_queue "prod/db01"
    cmd_remove <<< "y"

    run host_exists "prod/db01"
    [ "$status" -ne 0 ]
    run host_exists "prod/web01"
    [ "$status" -eq 0 ]
}

@test "cmd_remove aborts without deleting anything if the confirmation prompt isn't answered 'y'" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    fzf_queue "prod/db01"
    run cmd_remove <<< "n"

    [ "$status" -ne 0 ]
    run host_exists "prod/db01"
    [ "$status" -eq 0 ]
    run cred_exists "prod/db01"
    [ "$status" -eq 0 ]
}

@test "cmd_edit renames a host and migrates its credential to the new key" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    # cmd_edit prompts in order: group, name, hostname, user, port, password
    # (blank = keep current), private key (blank = keep current, hits EOF).
    fzf_queue "prod/db01"
    cmd_edit <<'INPUT'
prod
db02
10.0.0.5
root
22

INPUT

    run host_exists "prod/db01"
    [ "$status" -ne 0 ]
    run host_exists "prod/db02"
    [ "$status" -eq 0 ]

    run cred_exists "prod/db01"
    [ "$status" -ne 0 ]
    [ "$(decrypt_password "$(cred_get "prod/db02")")" = "secret123" ]
}

@test "cmd_edit renaming a host with an existing key moves the file and updates IdentityFile to match" {
    mkdir -p "$HOME/.ssh/keys/prod"
    echo "keydata" > "$(keyfile_path "prod" "db01")"
    host_append_block "prod/db01" "10.0.0.5" "root" "22" "$(keyfile_path "prod" "db01")"

    # group, name, hostname, user, port, password (blank), private key (blank -> move existing)
    fzf_queue "prod/db01"
    cmd_edit <<'INPUT'
prod
db02
10.0.0.5
root
22

INPUT

    local newkeypath
    newkeypath="$(keyfile_path "prod" "db02")"
    [ -f "$newkeypath" ]
    [ ! -f "$(keyfile_path "prod" "db01")" ]
    [ "$(host_get_field "prod/db02" "IdentityFile")" = "$newkeypath" ]
}

@test "cmd_edit with a new password overwrites the stored credential" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "oldpass")"

    fzf_queue "prod/db01"
    cmd_edit <<'INPUT'
prod
db01
10.0.0.5
root
22
newpass
INPUT

    [ "$(decrypt_password "$(cred_get "prod/db01")")" = "newpass" ]
}
