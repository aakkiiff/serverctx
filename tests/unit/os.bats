#!/usr/bin/env bats

load '../helpers/test_helper'

setup() {
    setup_isolated_env
}

teardown() {
    teardown_short_home
}

@test "os_type reports mac or linux for the current uname" {
    case "$(uname -s)" in
        Darwin) [ "$(os_type)" = "mac" ] ;;
        Linux)  [ "$(os_type)" = "linux" ] ;;
    esac
}

@test "ping_once reports a reachable host as up" {
    run ping_once "reachable.example.com" 1
    [ "$status" -eq 0 ]
}

@test "ping_once reports an unreachable host as down" {
    export PING_MOCK_FAIL_HOSTS="unreachable.example.com"
    run ping_once "unreachable.example.com" 1
    [ "$status" -ne 0 ]
}

@test "ping_once converts the timeout to milliseconds on macOS, seconds on Linux (confirmed via man ping: -W means ms on macOS, s on Linux iputils)" {
    ping_once "reachable.example.com" 1
    if [[ "$OS_TYPE" == "mac" ]]; then
        grep -q -- "-W 1000 " "$MOCK_LOG"
    else
        grep -q -- "-W 1 " "$MOCK_LOG"
    fi
}

@test "clipboard_copy pipes stdin to the platform clipboard tool" {
    printf 'hunter2' | clipboard_copy
    [ "$(cat "$MOCK_CLIPBOARD_FILE")" = "hunter2" ]
}

@test "tcp_port_open detects a real open TCP port" {
    command -v nc &>/dev/null || skip "nc not available on this system"
    nc -l 34597 &>/dev/null &
    local nc_pid=$!
    sleep 0.2

    run tcp_port_open "127.0.0.1" "34597" 1
    kill "$nc_pid" 2>/dev/null || true

    [ "$status" -eq 0 ]
}

@test "tcp_port_open reports a closed local port as unreachable, quickly (no listener bound)" {
    local start=$SECONDS
    run tcp_port_open "127.0.0.1" "34598" 1
    [ "$status" -ne 0 ]
    (( SECONDS - start <= 3 ))
}

@test "tcp_port_open times out against a filtered/black-holed host instead of hanging on the OS's default connect timeout" {
    local start=$SECONDS
    run tcp_port_open "192.0.2.1" "80" 1
    [ "$status" -ne 0 ]
    (( SECONDS - start <= 5 ))
}

@test "tcp_port_open treats an empty port (host has no Port line) as closed, without attempting a connection" {
    run tcp_port_open "127.0.0.1" "" 1
    [ "$status" -ne 0 ]
}

@test "host_reachable returns success from ping alone, without invoking the (slow, here) TCP fallback" {
    local start=$SECONDS
    run host_reachable "192.0.2.1" "80" 5
    [ "$status" -eq 0 ]
    (( SECONDS - start <= 1 ))
}

@test "host_reachable falls back to a TCP connect when ping fails, and succeeds if the port is open" {
    command -v nc &>/dev/null || skip "nc not available on this system"
    export PING_MOCK_FAIL_HOSTS="127.0.0.1"
    nc -l 34599 &>/dev/null &
    local nc_pid=$!
    sleep 0.2

    run host_reachable "127.0.0.1" "34599" 1
    kill "$nc_pid" 2>/dev/null || true

    [ "$status" -eq 0 ]
}

@test "host_reachable reports offline when both ping and the TCP fallback fail" {
    export PING_MOCK_FAIL_HOSTS="127.0.0.1"
    run host_reachable "127.0.0.1" "34600" 1
    [ "$status" -ne 0 ]
}

@test "require_cmds passes silently when every command exists" {
    run require_cmds cat ls
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "require_cmds lists every missing command and points at 'server init'" {
    run require_cmds cat this-tool-does-not-exist-xyz another-missing-one-xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"this-tool-does-not-exist-xyz"* ]]
    [[ "$output" == *"another-missing-one-xyz"* ]]
    [[ "$output" != *" cat"* ]]
    [[ "$output" == *"server init"* ]]
}

@test "supports_color is false when stdout is not a terminal (e.g. captured by 'run', piped, or redirected)" {
    run supports_color
    [ "$status" -ne 0 ]
}

@test "run_privileged runs the command via sudo when not root" {
    run_privileged echo hello
    grep -q "^sudo echo hello$" "$MOCK_LOG"
}

@test "pkg_install on Linux without apt/apt-get gives a clear 'unsupported distro' message instead of a raw command-not-found" {
    OS_TYPE=linux PATH="/usr/bin:/bin" run pkg_install fzf
    [ "$status" -ne 0 ]
    [[ "$output" == *"No 'apt'/'apt-get' found"* ]]
    [[ "$output" == *"Ubuntu/Debian"* ]]
}

@test "pkg_install on Linux with apt available installs via run_privileged (sudo apt update / install)" {
    OS_TYPE=linux run pkg_install this-package-definitely-does-not-exist-xyz
    [ "$status" -eq 0 ]
    grep -q "sudo apt update -y" "$MOCK_LOG"
    grep -q "sudo apt install -y this-package-definitely-does-not-exist-xyz" "$MOCK_LOG"
}
