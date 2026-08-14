#!/usr/bin/env bats

load '../helpers/test_helper'

setup() {
    setup_isolated_env
}

teardown() {
    teardown_short_home
}

@test "validate_token rejects empty value" {
    run validate_token "" "Name"
    [ "$status" -ne 0 ]
}

@test "validate_token rejects '/' (internal delimiter)" {
    run validate_token "prod/db" "Name"
    [ "$status" -ne 0 ]
}

@test "validate_token rejects '=' (credentials-file delimiter)" {
    run validate_token "prod=db" "Name"
    [ "$status" -ne 0 ]
}

@test "validate_token rejects a leading '-' (could be misread as a flag)" {
    run validate_token "-x" "Name"
    [ "$status" -ne 0 ]
}

@test "validate_token rejects regex metacharacters" {
    run validate_token 'evil.*[a-z]$' "Name"
    [ "$status" -ne 0 ]
}

@test "validate_token accepts alnum, dot, underscore, dash" {
    run validate_token "my-server.01_a" "Name"
    [ "$status" -eq 0 ]
}

@test "host_append_block then host_exists round-trips" {
    host_append_block "prod/db" "1.2.3.4" "root" "22"
    run host_exists "prod/db"
    [ "$status" -eq 0 ]
    run host_exists "prod/other"
    [ "$status" -ne 0 ]
}

@test "host_get_field reads HostName/User/Port from the right block only" {
    host_append_block "prod/db" "1.2.3.4" "root" "22"
    host_append_block "prod/web" "5.6.7.8" "admin" "2222"

    [ "$(host_get_field "prod/db" "HostName")" = "1.2.3.4" ]
    [ "$(host_get_field "prod/web" "HostName")" = "5.6.7.8" ]
    [ "$(host_get_field "prod/web" "Port")" = "2222" ]
}

@test "host_remove_block removes only the targeted host" {
    host_append_block "prod/db" "1.2.3.4" "root" "22"
    host_append_block "prod/web" "5.6.7.8" "admin" "2222"

    host_remove_block "prod/db"

    run host_exists "prod/db"
    [ "$status" -ne 0 ]
    run host_exists "prod/web"
    [ "$status" -eq 0 ]
}

@test "host_names_in_group only returns hosts with an exact group prefix (no false match on a longer group name)" {
    host_append_block "prod/db" "1.2.3.4" "root" "22"
    host_append_block "production/web" "5.6.7.8" "admin" "22"

    run host_names_in_group "prod"
    [ "$output" = "db" ]
}

@test "cred round-trip: set, exists, get, delete" {
    cred_set "prod/db" "ZmFrZS1jaXBoZXJ0ZXh0"
    run cred_exists "prod/db"
    [ "$status" -eq 0 ]
    [ "$(cred_get "prod/db")" = "ZmFrZS1jaXBoZXJ0ZXh0" ]

    cred_delete "prod/db"
    run cred_exists "prod/db"
    [ "$status" -ne 0 ]
}

@test "cred keys for different group/name splits do not collide (regression: old '-'-flattened scheme did)" {
    # group="a" name="b-c"  vs  group="a-b" name="c" used to both flatten to
    # the credentials-file key "a-b-c" under the old scheme.
    cred_set "$(cred_key "a" "b-c")" "value-one"
    cred_set "$(cred_key "a-b" "c")" "value-two"

    [ "$(cred_get "a/b-c")" = "value-one" ]
    [ "$(cred_get "a-b/c")" = "value-two" ]
}

@test "keyfile_path keeps different group/name splits in separate files (regression: old flattened scheme collided)" {
    local p1 p2
    p1="$(keyfile_path "a" "b-c")"
    p2="$(keyfile_path "a-b" "c")"
    [ "$p1" != "$p2" ]
}

@test "host_rename_group_prefix renames only the matching group, not a group that merely shares a prefix" {
    host_append_block "prod/db" "1.2.3.4" "root" "22"
    host_append_block "production/web" "5.6.7.8" "admin" "22"

    host_rename_group_prefix "prod" "staging"

    run host_exists "staging/db"
    [ "$status" -eq 0 ]
    run host_exists "production/web"
    [ "$status" -eq 0 ]
    run host_exists "staging/web"
    [ "$status" -ne 0 ]
}

@test "host_append_block writes an IdentityFile line when given a key path, and omits it otherwise" {
    host_append_block "prod/db" "1.2.3.4" "root" "22" "$HOME/.ssh/keys/prod/db"
    [ "$(host_get_field "prod/db" "IdentityFile")" = "$HOME/.ssh/keys/prod/db" ]

    host_append_block "prod/web" "5.6.7.8" "admin" "22"
    [ -z "$(host_get_field "prod/web" "IdentityFile")" ]
}

@test "host_rename_group_prefix updates an IdentityFile path to follow the group rename, not just the Host line" {
    host_append_block "prod/db" "1.2.3.4" "root" "22" "$HOME/.ssh/keys/prod/db"
    host_append_block "production/web" "5.6.7.8" "admin" "22" "$HOME/.ssh/keys/production/web"

    host_rename_group_prefix "prod" "staging"

    [ "$(host_get_field "staging/db" "IdentityFile")" = "$HOME/.ssh/keys/staging/db" ]
    # A group that only shares a text prefix keeps its own IdentityFile untouched.
    [ "$(host_get_field "production/web" "IdentityFile")" = "$HOME/.ssh/keys/production/web" ]
}

@test "a name containing regex metacharacters cannot corrupt an unrelated host entry" {
    # Historically the group/name were interpolated straight into a
    # grep/sed pattern; validate_token now blocks this at the source.
    host_append_block "prod/db" "1.2.3.4" "root" "22"
    run validate_token 'db$|web' "Name"
    [ "$status" -ne 0 ]
}

@test "require_hosts distinguishes 'never initialized' from 'initialized but empty', with a specific actionable message for each" {
    rm -f "$SSH_CONFIG_FILE"
    run require_hosts
    [ "$status" -ne 0 ]
    [[ "$output" == *"isn't initialized"* ]]
    [[ "$output" == *"server init"* ]]

    : > "$SSH_CONFIG_FILE"
    run require_hosts
    [ "$status" -ne 0 ]
    [[ "$output" == *"No hosts found"* ]]
    [[ "$output" == *"server add"* ]]

    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    run require_hosts
    [ "$status" -eq 0 ]
}

@test "expand_tilde expands a bare ~ and a ~/-prefixed path, and leaves everything else untouched" {
    [ "$(expand_tilde "~")" = "$HOME" ]
    [ "$(expand_tilde "~/.ssh/id_rsa")" = "$HOME/.ssh/id_rsa" ]
    [ "$(expand_tilde "/absolute/path")" = "/absolute/path" ]
    [ "$(expand_tilde "relative/path")" = "relative/path" ]
    [ "$(expand_tilde "")" = "" ]
    # Only a leading ~ is special — not one that just happens to appear elsewhere.
    [ "$(expand_tilde "/tmp/foo~bar")" = "/tmp/foo~bar" ]
}

@test "safe_mktemp returns a usable, writable temp file path" {
    local t
    t="$(safe_mktemp)"
    [ -f "$t" ]
    [ -w "$t" ]
    rm -f "$t"
}

@test "host_remove_block fails cleanly instead of corrupting the config when mktemp is unavailable" {
    local original
    original="$(cat "$SSH_CONFIG_FILE" 2>/dev/null || true)"
    host_append_block "prod/db01" "10.0.0.5" "root" "22"

    PATH="/nonexistent-empty-path" run host_remove_block "prod/db01"
    [ "$status" -ne 0 ]
    # The real config must be untouched — no half-written/truncated file.
    run host_exists "prod/db01"
    [ "$status" -eq 0 ]
}
