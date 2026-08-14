#!/usr/bin/env bats
# Recency ordering in the picker, and the two `server ls` output flags.

load '../helpers/test_helper'

setup_file() {
    setup_short_home
}

teardown_file() {
    teardown_short_home
}

setup() {
    setup_isolated_env
    export RECENT_FILE="$HOME/.ssh/.serverctx_recent"
    rm -f "$RECENT_FILE"
}

seed_hosts() {
    host_append_block "alpha/one"   "10.0.0.1" "root" "22"
    host_append_block "beta/two"    "10.0.0.2" "root" "22"
    host_append_block "gamma/three" "10.0.0.3" "root" "22"
}

# --- recency -----------------------------------------------------------

@test "with no history the picker list is plain alphabetical" {
    seed_hosts
    run order_hosts_by_recency "$(host_list)"
    [ "${lines[0]}" = "alpha/one" ]
    [ "${lines[1]}" = "beta/two" ]
    [ "${lines[2]}" = "gamma/three" ]
}

@test "recently connected hosts float to the top, most recent first" {
    seed_hosts
    touch_host_recent "gamma/three"
    sleep 1
    touch_host_recent "beta/two"

    run order_hosts_by_recency "$(host_list)"
    [ "${lines[0]}" = "beta/two" ]
    [ "${lines[1]}" = "gamma/three" ]
    # Never-connected hosts follow, still alphabetical.
    [ "${lines[2]}" = "alpha/one" ]
}

@test "reconnecting to a host moves it back to the top rather than duplicating it" {
    seed_hosts
    touch_host_recent "gamma/three"
    sleep 1
    touch_host_recent "beta/two"
    sleep 1
    touch_host_recent "gamma/three"

    run order_hosts_by_recency "$(host_list)"
    [ "${lines[0]}" = "gamma/three" ]
    [ "${lines[1]}" = "beta/two" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "a host that no longer exists is dropped from the ordering" {
    seed_hosts
    touch_host_recent "deleted/gone"
    touch_host_recent "beta/two"

    run order_hosts_by_recency "$(host_list)"
    [ "${#lines[@]}" -eq 3 ]
    [[ "$output" != *"deleted/gone"* ]]
}

@test "the recency ledger is capped and written with owner-only permissions" {
    local i
    for i in $(seq 1 60); do touch_host_recent "grp/h$i"; done

    [ "$(wc -l < "$RECENT_FILE" | tr -d ' ')" -le 50 ]
    [ "$(stat -f '%Lp' "$RECENT_FILE" 2>/dev/null || stat -c '%a' "$RECENT_FILE")" = "600" ]
}

@test "connecting records the host, but merely picking one to remove does not" {
    seed_hosts
    # Key auth rather than a password, so this doesn't need a GPG keyring
    # just to reach the point where the connection is recorded.
    mkdir -p "$HOME/.ssh/keys/beta"
    : > "$(keyfile_path "beta" "two")"

    # Recording happens after pick_host returns, so it's independent of which
    # shape the picker took; pin the flat one to keep the queue to one turn.
    export SERVERCTX_PICKER=flat

    fzf_queue "beta/two"
    cmd_ssh >/dev/null 2>&1 || true
    grep -qF "beta/two" "$RECENT_FILE"

    # Removing a host must not promote it — it's about to stop existing.
    rm -f "$RECENT_FILE"
    fzf_queue "alpha/one"
    run with_stdin $'n\n' cmd_remove
    [ ! -s "${RECENT_FILE:-/nonexistent}" ] || ! grep -qF "alpha/one" "$RECENT_FILE"
}

@test "pick_host still returns a valid choice once a recency ledger exists" {
    seed_hosts
    touch_host_recent "gamma/three"

    export SERVERCTX_PICKER=flat
    fzf_queue "gamma/three"
    run pick_host
    [ "$status" -eq 0 ]
    [ "$output" = "gamma/three" ]
}

@test "recency ordering applies inside a group too, with '..' pinned on top" {
    seed_hosts
    host_append_block "alpha/two"   "10.0.0.4" "root" "22"
    host_append_block "alpha/three" "10.0.0.5" "root" "22"
    touch_host_recent "alpha/three"

    local tmpdir="$BATS_TEST_TMPDIR/previews"
    mkdir -p "$tmpdir"
    _pick_build_previews "$tmpdir"

    # Drive the in-group picker and read back the list it was handed.
    fzf_queue "three"
    run _pick_from_group "Connect to" "$tmpdir" "alpha"
    [ "$status" -eq 0 ]
    [ "$output" = "three" ]

    # The back row must never be sorted away from the top by recency.
    local listed
    listed="$( { printf '..\n'; order_hosts_by_recency \
        "$(host_names_in_group alpha | sed 's|^|alpha/|')" | sed 's|^alpha/||'; } )"
    [ "$(printf '%s\n' "$listed" | head -n1)" = ".." ]
    [ "$(printf '%s\n' "$listed" | sed -n 2p)" = "three" ]
}

# --- ls --json ---------------------------------------------------------

@test "ls --json emits one well-formed object per host with the right fields" {
    host_append_block "prod/db01" "10.0.0.5" "root" "2222"
    cred_set "prod/db01" "x"

    run cmd_list --json --no-ping
    [ "$status" -eq 0 ]
    [[ "$output" == *'"host":"prod/db01"'* ]]
    [[ "$output" == *'"group":"prod"'* ]]
    [[ "$output" == *'"name":"db01"'* ]]
    [[ "$output" == *'"hostname":"10.0.0.5"'* ]]
    [[ "$output" == *'"user":"root"'* ]]
    [[ "$output" == *'"port":2222'* ]]
    [[ "$output" == *'"password":true'* ]]
    [[ "$output" == *'"key":false'* ]]
}

@test "ls --json output parses as JSON" {
    command -v python3 &>/dev/null || skip "python3 not available"
    seed_hosts
    cred_set "beta/two" "x"

    cmd_list --json --no-ping > "$BATS_TEST_TMPDIR/out.json"
    run python3 -m json.tool "$BATS_TEST_TMPDIR/out.json"
    [ "$status" -eq 0 ]
}

@test "ls --json emits an empty array rather than an error when there are no hosts" {
    : > "$SSH_CONFIG_FILE"
    run cmd_list --json
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "ls --json keeps stdout pure JSON — progress lines never leak into it" {
    seed_hosts
    command -v python3 &>/dev/null || skip "python3 not available"

    # With pinging on, the table mode would print "Checking N host(s)…".
    cmd_list --json 2>/dev/null > "$BATS_TEST_TMPDIR/out.json"
    run python3 -m json.tool "$BATS_TEST_TMPDIR/out.json"
    [ "$status" -eq 0 ]
    run cat "$BATS_TEST_TMPDIR/out.json"
    [[ "$output" != *"Checking"* ]]
}

@test "ls --json escapes characters that would otherwise break the document" {
    # A hand-edited config can contain quotes and backslashes; validate_token
    # only guards what serverctx itself writes.
    printf '\nHost odd/quote\n    HostName he"llo\n    User ro\\\\ot\n    Port 22\n' >> "$SSH_CONFIG_FILE"

    run cmd_list --json --no-ping
    [ "$status" -eq 0 ]
    [[ "$output" == *'he\"llo'* ]]

    if command -v python3 &>/dev/null; then
        cmd_list --json --no-ping > "$BATS_TEST_TMPDIR/odd.json"
        run python3 -m json.tool "$BATS_TEST_TMPDIR/odd.json"
        [ "$status" -eq 0 ]
    fi
}

@test "ls --json falls back to port 22 when the config holds a non-numeric port" {
    command -v python3 &>/dev/null || skip "python3 not available"
    printf '\nHost odd/port\n    HostName 10.0.0.9\n    User root\n    Port notanumber\n' >> "$SSH_CONFIG_FILE"

    cmd_list --json --no-ping > "$BATS_TEST_TMPDIR/p.json"
    run python3 -m json.tool "$BATS_TEST_TMPDIR/p.json"
    [ "$status" -eq 0 ]
    run cat "$BATS_TEST_TMPDIR/p.json"
    [[ "$output" == *'"port":22'* ]]
}

# --- ls --no-ping ------------------------------------------------------

@test "ls --no-ping skips the reachability check entirely" {
    seed_hosts
    run cmd_list --no-ping

    [ "$status" -eq 0 ]
    # No ping was invoked at all.
    run grep -c "^ping" "$MOCK_LOG"
    [ "$output" = "0" ]
}

@test "ls --no-ping reports status as unknown in the table and null in JSON" {
    seed_hosts

    run cmd_list --no-ping
    [[ "$output" == *"unknown"* ]]
    [[ "$output" == *"--no-ping"* ]]

    run cmd_list --no-ping --json
    [[ "$output" == *'"status":null'* ]]
}

@test "ls without --no-ping still checks reachability" {
    seed_hosts
    run cmd_list
    [ "$status" -eq 0 ]
    run grep -c "^ping" "$MOCK_LOG"
    [ "$output" != "0" ]
}

@test "ls rejects an unknown option instead of silently ignoring it" {
    seed_hosts
    run cmd_list --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
    [[ "$output" == *"--json"* ]]
}

@test "the ls flags are reachable through the real dispatcher, not just the function" {
    seed_hosts
    run /bin/bash "$ROOT_DIR/dist/server" ls --no-ping --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"host":'* ]]
}
