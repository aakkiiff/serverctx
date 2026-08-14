#!/usr/bin/env bats
# The host picker — flat for a small inventory, group→host drill-down once
# there is more than one group — plus the confirmations added to the
# destructive commands.

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

# --- pick_host: flat shape ---------------------------------------------

@test "pick_host stays a single flat list while every host is in one group" {
    host_append_block "default/db01" "10.0.0.5" "root" "22"
    host_append_block "default/api" "10.0.0.6" "ubuntu" "22"

    fzf_queue "default/api"
    run pick_host

    [ "$status" -eq 0 ]
    [ "$output" = "default/api" ]
    # One group means the group step would be a one-row menu, so it's skipped.
    [ "$(grep -c '^fzf' "$MOCK_LOG")" -eq 1 ]
}

@test "SERVERCTX_PICKER=flat keeps the flat list however many groups there are" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "staging/api" "10.0.0.6" "ubuntu" "22"

    export SERVERCTX_PICKER=flat
    fzf_queue "staging/api"
    run pick_host

    [ "$status" -eq 0 ]
    [ "$output" = "staging/api" ]
    [ "$(grep -c '^fzf' "$MOCK_LOG")" -eq 1 ]
}

@test "pick_host reports cancellation without an error glyph when the user presses Esc" {
    host_append_block "default/db01" "10.0.0.5" "root" "22"

    fzf_queue ""
    run pick_host

    [ "$status" -ne 0 ]
    [[ "$output" == *"Cancelled"* ]]
    # Walking away deliberately is not a failure to shout about.
    [[ "$output" != *"❌"* ]]
}

# --- pick_host: group drill-down ---------------------------------------
#
# A flat list of 20 groups × 20 hosts is 400 rows: searchable, but no
# longer browsable. Above one group the picker leads with the groups.

@test "pick_host drills group then host once there is more than one group" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "prod/web01" "10.0.0.6" "root" "22"
    host_append_block "staging/api" "10.0.0.7" "ubuntu" "22"

    # The group row carries its host count; the picker takes field 1.
    fzf_queue "prod      2 host(s)" "web01"
    run pick_host

    [ "$status" -eq 0 ]
    [ "$output" = "prod/web01" ]
    [ "$(grep -c '^fzf' "$MOCK_LOG")" -eq 2 ]
}

@test "the group list carries each group's host count, and '*' for all hosts" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "prod/web01" "10.0.0.6" "root" "22"
    host_append_block "staging/api" "10.0.0.7" "ubuntu" "22"

    local tmpdir="$BATS_TEST_TMPDIR/previews"
    mkdir -p "$tmpdir"
    _pick_build_previews "$tmpdir"

    run cat "$tmpdir/groups.list"
    [[ "$output" == *"prod"*"2 host(s)"* ]]
    [[ "$output" == *"staging"*"1 host(s)"* ]]
    [[ "$output" == *"*"*"all 3 host(s)"* ]]
    # "*" leads, so the flat view is reachable without scrolling.
    [[ "${lines[0]}" == "*"* ]]
}

@test "a group's preview lists the hosts inside it before you open it" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "prod/web01" "10.0.0.6" "root" "22"
    host_append_block "staging/api" "10.0.0.7" "ubuntu" "22"

    local tmpdir="$BATS_TEST_TMPDIR/previews"
    mkdir -p "$tmpdir"
    _pick_build_previews "$tmpdir"

    run cat "$tmpdir/groups/prod"
    [[ "$output" == *"db01"* ]]
    [[ "$output" == *"web01"* ]]
    # staging's member must not leak into prod's preview.
    [[ "$output" != *"api"* ]]
}

@test "'*' in the group list opens the flat all-hosts view" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "staging/api" "10.0.0.6" "ubuntu" "22"

    fzf_queue "*  all 2 host(s)" "staging/api"
    run pick_host

    [ "$status" -eq 0 ]
    # The flat view returns a full "group/name", not a bare name.
    [ "$output" = "staging/api" ]
}

@test "'..' inside a group goes back to the group list instead of cancelling" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "staging/api" "10.0.0.6" "ubuntu" "22"

    # Open prod, back out, then open staging and pick from it.
    fzf_queue "prod  1 host(s)" ".." "staging  1 host(s)" "api"
    run pick_host

    [ "$status" -eq 0 ]
    [ "$output" = "staging/api" ]
    [ "$(grep -c '^fzf' "$MOCK_LOG")" -eq 4 ]
}

@test "Esc cancels from the group list and from inside a group" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "staging/api" "10.0.0.6" "ubuntu" "22"

    fzf_queue ""
    run pick_host
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cancelled"* ]]

    fzf_queue "prod  1 host(s)" ""
    run pick_host
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cancelled"* ]]
    [[ "$output" != *"❌"* ]]
}

@test "SERVERCTX_PICKER=groups forces the group step even with a single group" {
    host_append_block "default/db01" "10.0.0.5" "root" "22"

    export SERVERCTX_PICKER=groups
    fzf_queue "default  1 host(s)" "db01"
    run pick_host

    [ "$status" -eq 0 ]
    [ "$output" = "default/db01" ]
    [ "$(grep -c '^fzf' "$MOCK_LOG")" -eq 2 ]
}

@test "in-group rows are bare names, and both shapes read the same preview files" {
    host_append_block "prod/db01" "10.0.0.5" "root" "2222"

    local tmpdir="$BATS_TEST_TMPDIR/previews"
    mkdir -p "$tmpdir"
    _pick_build_previews "$tmpdir"

    # The flat list passes {} == "prod/db01"; the in-group list passes
    # {} == "db01" against a "$tmpdir/hosts/prod/" prefix. Same file.
    [ -f "$tmpdir/hosts/prod/db01" ]
    run cat "$tmpdir/hosts/prod/db01"
    [[ "$output" == *"10.0.0.5"* ]]
    [[ "$output" == *"2222"* ]]
}

@test "the bulk preview builder agrees with the single-host one" {
    host_append_block "prod/db01" "10.0.0.5" "root" "2222"
    cred_set "prod/db01" "$(encrypt_password "secret")"
    host_append_block "prod/keyonly" "10.0.0.8" "root" "22"
    mkdir -p "$HOME/.ssh/keys/prod"
    : > "$(keyfile_path "prod" "keyonly")"
    host_append_block "prod/bare" "10.0.0.9" "root" "22"

    local tmpdir="$BATS_TEST_TMPDIR/previews"
    mkdir -p "$tmpdir"
    _pick_build_previews "$tmpdir"

    local alias
    for alias in "prod/db01" "prod/keyonly" "prod/bare"; do
        [ "$(cat "$tmpdir/hosts/$alias")" = "$(_pick_host_preview "$alias" "prod" "${alias#*/}")" ]
    done
}

@test "pick_host distinguishes 'not initialized' from 'no hosts yet'" {
    rm -f "$SSH_CONFIG_FILE"
    run pick_host
    [ "$status" -ne 0 ]
    [[ "$output" == *"isn't initialized"* ]]

    : > "$SSH_CONFIG_FILE"
    run pick_host
    [ "$status" -ne 0 ]
    [[ "$output" == *"No hosts found"* ]]
}

@test "the picker preview shows a host's connection details and auth method" {
    host_append_block "prod/db01" "10.0.0.5" "root" "2222"
    cred_set "prod/db01" "$(encrypt_password "secret")"

    run _pick_host_preview "prod/db01" "prod" "db01"
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.5"* ]]
    [[ "$output" == *"root"* ]]
    [[ "$output" == *"2222"* ]]
    [[ "$output" == *"password"* ]]
}

@test "the picker preview reports key auth, and 'none' when nothing is saved" {
    host_append_block "prod/keyonly" "10.0.0.8" "root" "22"
    mkdir -p "$HOME/.ssh/keys/prod"
    : > "$(keyfile_path "prod" "keyonly")"
    run _pick_host_preview "prod/keyonly" "prod" "keyonly"
    [[ "$output" == *"ssh key"* ]]

    host_append_block "prod/bare" "10.0.0.9" "root" "22"
    run _pick_host_preview "prod/bare" "prod" "bare"
    [[ "$output" == *"none"* ]]
}

# --- guardrails --------------------------------------------------------

@test "cmd_restore verifies archives before deleting anything, so a corrupt backup can't destroy the GPG keyring" {
    local bad="$BATS_TEST_TMPDIR/badbackup"
    mkdir -p "$bad"
    echo "not a tar file at all" > "$bad/gnupg-backup.tar"

    # A real keyring exists and must survive.
    [ -d "$HOME/.gnupg" ]

    run with_stdin "$bad"$'\ny\n' cmd_restore

    [ "$status" -ne 0 ]
    [[ "$output" == *"corrupt"* ]]
    [[ "$output" == *"Nothing has been changed"* ]]
    [ -d "$HOME/.gnupg" ]
}

@test "cmd_restore aborts without touching anything when the confirmation is declined" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cmd_backup >/dev/null
    : > "$SSH_CONFIG_FILE"

    run with_stdin "$backup_dir"$'\nn\n' cmd_restore

    [ "$status" -ne 0 ]
    [[ "$output" == *"Cancelled"* ]]
    # The emptied config was NOT restored over, since we declined.
    run host_exists "prod/db01"
    [ "$status" -ne 0 ]
}

@test "cmd_editgroup aborts without renaming anything when the confirmation is declined" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"

    fzf_queue "prod"
    run with_stdin $'staging\nn\n' cmd_editgroup

    [ "$status" -ne 0 ]
    [[ "$output" == *"Cancelled"* ]]
    run host_exists "prod/db01"
    [ "$status" -eq 0 ]
    run host_exists "staging/db01"
    [ "$status" -ne 0 ]
}

@test "cmd_editgroup names the blast radius before asking to confirm" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    host_append_block "prod/web01" "10.0.0.6" "root" "22"

    fzf_queue "prod"
    run with_stdin $'staging\nn\n' cmd_editgroup

    [[ "$output" == *"2 host(s)"* ]]
}

@test "cmd_backup asks before replacing an existing backup directory" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    mkdir -p "$backup_dir"
    echo "previous backup" > "$backup_dir/sentinel"

    run with_stdin $'n\n' cmd_backup

    [ "$status" -ne 0 ]
    [[ "$output" == *"Cancelled"* ]]
    # The old backup is still intact because we declined.
    [ -f "$backup_dir/sentinel" ]
}

@test "cmd_remove lists exactly what will be deleted before confirming" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret")"
    mkdir -p "$HOME/.ssh/keys/prod"
    : > "$(keyfile_path "prod" "db01")"

    fzf_queue "prod/db01"
    run with_stdin $'n\n' cmd_remove

    [[ "$output" == *"saved password"* ]]
    [[ "$output" == *"SSH key"* ]]
    [ "$status" -ne 0 ]
    run host_exists "prod/db01"
    [ "$status" -eq 0 ]
}

@test "cmd_download asks before overwriting an existing local file" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret")"

    export SFTP_MOCK_ROOT="$BATS_TEST_TMPDIR/fake_remote"
    mkdir -p "$SFTP_MOCK_ROOT"
    echo "remote" > "$SFTP_MOCK_ROOT/file1.txt"

    cd "$BATS_TEST_TMPDIR" || return 1
    echo "local original" > ./file1.txt

    fzf_queue "prod/db01" $'c\nfile1.txt'
    run with_stdin $'n\n' cmd_download

    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    [ "$(cat ./file1.txt)" = "local original" ]
}

# --- input validation --------------------------------------------------

@test "validate_port rejects 0, 65536 and non-numeric values but accepts the valid range" {
    run validate_port 0;     [ "$status" -ne 0 ]
    run validate_port 65536; [ "$status" -ne 0 ]
    run validate_port abc;   [ "$status" -ne 0 ]
    run validate_port "";    [ "$status" -ne 0 ]
    run validate_port 1;     [ "$status" -eq 0 ]
    run validate_port 22;    [ "$status" -eq 0 ]
    run validate_port 65535; [ "$status" -eq 0 ]
}

@test "validate_hostname rejects empty values and values containing spaces" {
    run validate_hostname "";            [ "$status" -ne 0 ]
    run validate_hostname "a b";         [ "$status" -ne 0 ]
    run validate_hostname "10.0.0.5";    [ "$status" -eq 0 ]
    run validate_hostname "example.com"; [ "$status" -eq 0 ]
}

@test "cmd_add rejects an out-of-range port and re-prompts instead of writing it" {
    cmd_add <<'INPUT'
db01
prod
10.0.0.5
root
99999
22
secret123
INPUT

    [ "$(host_get_field "prod/db01" "Port")" = "22" ]
}

@test "cmd_add checks for a duplicate host before asking for connection details" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"

    # Only name and group are supplied; if the duplicate check happened
    # later, cmd_add would block waiting for a hostname that never comes.
    run cmd_add <<'INPUT'
db01
prod
INPUT

    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}
