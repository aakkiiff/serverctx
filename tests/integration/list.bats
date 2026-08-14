#!/usr/bin/env bats

load '../helpers/test_helper'

setup() {
    setup_isolated_env
}

teardown() {
    teardown_short_home
}

@test "cmd_list reports online/offline, password, and key status per host, grouped" {
    host_append_block "prod/db01" "up.example.com" "root" "22"
    host_append_block "prod/web01" "down.example.com" "root" "22"
    cred_set "prod/db01" "encrypted-value"
    mkdir -p "$HOME/.ssh/keys/prod"
    : > "$HOME/.ssh/keys/prod/web01"

    export PING_MOCK_FAIL_HOSTS="down.example.com"

    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"prod"* ]]
    [[ "$output" == *"NAME"*"STATUS"*"PW"*"KEY"* ]]
    [[ "$output" == *"db01"*"🟢 online"*"🔒"* ]]
    [[ "$output" == *"web01"*"🔴 offline"*"🔑"* ]]
    [[ "$output" == *"2 host(s)"* ]]
}

@test "cmd_list reports no hosts found on an empty config, without crashing" {
    run cmd_list
    [ "$status" -eq 1 ]
    [[ "$output" == *"No hosts found"* ]]
}

@test "cmd_list shows a host as online via the TCP fallback when ping fails but its configured port is open" {
    command -v nc &>/dev/null || skip "nc not available on this system"

    host_append_block "prod/web01" "127.0.0.1" "root" "34601"
    export PING_MOCK_FAIL_HOSTS="127.0.0.1"

    nc -l 34601 &>/dev/null &
    local nc_pid=$!
    sleep 0.2

    run cmd_list
    kill "$nc_pid" 2>/dev/null || true

    [ "$status" -eq 0 ]
    [[ "$output" == *"web01"*"🟢 online"* ]]
}

@test "cmd_list does not collide two hosts that flatten to the same string under the old '-' scheme" {
    host_append_block "a/b-c" "host-a.example.com" "root" "22"
    host_append_block "a-b/c" "host-b.example.com" "root" "22"
    export PING_MOCK_FAIL_HOSTS=""

    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 host(s)"* ]]
}

@test "regression: the bundled dist/server runs under macOS's stock bash 3.2 without a 'declare -A' crash" {
    [ -x "$ROOT_DIR/dist/server" ]
    run /bin/bash "$ROOT_DIR/dist/server" ls
    [[ "$output" != *"invalid option"* ]]
    [[ "$output" != *"declare: -A"* ]]
}

@test "an unknown command exits non-zero in both bin/server and the bundled dist/server, so scripts can detect failure" {
    [ -x "$ROOT_DIR/dist/server" ]
    run /bin/bash "$ROOT_DIR/dist/server" bogus-command-xyz
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]

    run /bin/bash "$ROOT_DIR/bin/server" bogus-command-xyz
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]
}
