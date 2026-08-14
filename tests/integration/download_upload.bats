#!/usr/bin/env bats
# cmd_download / cmd_upload — ported from an experimental branch that was
# never merged to main and substantially rewritten in the process (see
# lib/commands/download.sh and upload.sh for what changed and why). These
# tests cover the specific bugs fixed during that rewrite as well as normal
# navigation, using a real local directory tree as a stand-in remote
# filesystem for the sftp mock (see tests/fixtures/mock_bin/sftp).

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

    # Stand-in "remote" filesystem for the sftp mock:
    #   file1.txt
    #   subdir/file2.txt
    #   emptydir/
    export SFTP_MOCK_ROOT="$BATS_TEST_TMPDIR/fake_remote"
    mkdir -p "$SFTP_MOCK_ROOT/subdir" "$SFTP_MOCK_ROOT/emptydir"
    echo "root file" > "$SFTP_MOCK_ROOT/file1.txt"
    echo "subdir file" > "$SFTP_MOCK_ROOT/subdir/file2.txt"

    cd "$BATS_TEST_TMPDIR" || return 1
}

teardown() {
    unset SFTP_MOCK_ROOT
}

@test "cmd_download resolves the host's actual configured port for both the sftp listing and the scp transfer (regression: was hardcoded to 22)" {
    host_append_block "prod/db01" "10.0.0.5" "root" "2222"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    fzf_queue "prod/db01" $'c\nfile1.txt'
    cmd_download

    grep -q -- "-P 2222" "$MOCK_LOG"
    run grep -- "-P 22 " "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

@test "cmd_download uses sshpass -f (not -p) for password auth, never leaking the plaintext password into any logged argv" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "s3cr3t-plaintext")"

    fzf_queue "prod/db01" $'c\nfile1.txt'
    cmd_download

    grep -q -- "-f " "$MOCK_LOG"
    run grep -- "-p " "$MOCK_LOG"
    [ "$status" -ne 0 ]
    run grep -F "s3cr3t-plaintext" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

@test "cmd_download with password auth never touches -i/keyfile (regression: ported 'if CREDENTIAL_FLAG==key' bug always took the key branch)" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    fzf_queue "prod/db01" $'c\nfile1.txt'
    cmd_download

    run grep -- "-i " "$MOCK_LOG"
    [ "$status" -ne 0 ]
    grep -q "sshpass" "$MOCK_LOG"
}

@test "cmd_download with key auth uses -i/keyfile and never invokes sshpass" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    mkdir -p "$HOME/.ssh/keys/prod"
    echo "fake-key" > "$(keyfile_path "prod" "db01")"

    fzf_queue "prod/db01" $'c\nfile1.txt'
    cmd_download

    grep -q -- "-i $(keyfile_path "prod" "db01")" "$MOCK_LOG"
    run grep "sshpass" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

@test "cmd_download downloads a file listed at the browse root when 'c' is pressed" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    fzf_queue "prod/db01" $'c\nfile1.txt'
    run cmd_download

    [ "$status" -eq 0 ]
    [[ "$output" == *"Downloaded file1.txt"* ]]
    grep -q "scp .*root@10.0.0.5:./file1.txt" "$MOCK_LOG"
}

@test "cmd_download navigates into a subdirectory (Enter) and downloads a file there" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    fzf_queue "prod/db01" $'enter\nsubdir' $'c\nfile2.txt'
    run cmd_download

    [ "$status" -eq 0 ]
    [[ "$output" == *"Downloaded file2.txt"* ]]
    grep -q "scp .*root@10.0.0.5:./subdir/file2.txt" "$MOCK_LOG"
}

@test "cmd_download navigates back out via the '..' entry (regression: the ported version never offered a working way back)" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    fzf_queue "prod/db01" $'enter\nsubdir' $'enter\n..' $'c\nfile1.txt'
    run cmd_download

    [ "$status" -eq 0 ]
    [[ "$output" == *"Downloaded file1.txt"* ]]
    grep -q "scp .*root@10.0.0.5:./file1.txt" "$MOCK_LOG"
}

@test "cmd_download handles an empty subdirectory without crashing or looping forever, then lets the user back out" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    # Turns after the host pick: descend into emptydir (which reports the
    # empty listing and pops back up to the root), then cancel out of the
    # root listing shown afterwards.
    fzf_queue "prod/db01" $'enter\nemptydir' ""
    run cmd_download

    [ "$status" -ne 0 ]
    [[ "$output" == *"is empty"* ]]
    [[ "$output" == *"Cancelled"* ]]
}

@test "cmd_download reports cancellation cleanly when the user cancels the picker (e.g. Esc), instead of an ambiguous exit code" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"

    fzf_queue "prod/db01" ""
    run cmd_download

    [ "$status" -ne 0 ]
    [[ "$output" == *"Cancelled"* ]]
}

@test "pick_local_path lets the user browse into a subdirectory and select a file there" {
    mkdir -p localdir/localsub
    echo "x" > localdir/localsub/pick_me.txt

    fzf_queue $'enter\nlocaldir' $'enter\nlocalsub' $'c\npick_me.txt'
    run pick_local_path

    [ "$status" -eq 0 ]
    [ "$output" = "./localdir/localsub/pick_me.txt" ]
}

@test "pick_local_path supports navigating back out via '..' (regression: the ported local_fzf's 'go up' never worked — find() never lists a .. entry)" {
    mkdir -p localdir
    echo "x" > top_level.txt

    fzf_queue $'enter\nlocaldir' $'enter\n..' $'c\ntop_level.txt'
    run pick_local_path

    [ "$status" -eq 0 ]
    [ "$output" = "./top_level.txt" ]
}

@test "cmd_upload uploads the picked local file to the configured host/port/remote-path" {
    host_append_block "prod/db01" "10.0.0.5" "root" "2222"
    cred_set "prod/db01" "$(encrypt_password "secret123")"
    echo "local content" > mylocalfile.txt

    fzf_queue "prod/db01" $'c\nmylocalfile.txt'
    run with_stdin $'/remote/dest/\n' cmd_upload

    [ "$status" -eq 0 ]
    [[ "$output" == *"Uploaded"* ]]
    grep -q -- "-P 2222" "$MOCK_LOG"
    grep -q "scp .*mylocalfile.txt root@10.0.0.5:/remote/dest/" "$MOCK_LOG"
}

@test "cmd_upload defaults the remote destination to the login directory (.) when left blank" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    cred_set "prod/db01" "$(encrypt_password "secret123")"
    echo "local content" > mylocalfile.txt

    fzf_queue "prod/db01" $'c\nmylocalfile.txt'
    run with_stdin $'\n' cmd_upload

    [ "$status" -eq 0 ]
    grep -q "root@10.0.0.5:\." "$MOCK_LOG"
}

@test "cmd_upload with key auth uses -i/keyfile and never invokes sshpass" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"
    mkdir -p "$HOME/.ssh/keys/prod"
    echo "fake-key" > "$(keyfile_path "prod" "db01")"
    echo "local content" > mylocalfile.txt

    fzf_queue "prod/db01" $'c\nmylocalfile.txt'
    run with_stdin $'/dest/\n' cmd_upload

    [ "$status" -eq 0 ]
    grep -q -- "-i $(keyfile_path "prod" "db01")" "$MOCK_LOG"
    run grep "sshpass" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

@test "cmd_download and cmd_upload require fzf/scp/sftp and configured hosts, same as other host-picking commands" {
    rm -f "$SSH_CONFIG_FILE"
    run cmd_download
    [ "$status" -ne 0 ]
    [[ "$output" == *"isn't initialized"* ]]

    run cmd_upload
    [ "$status" -ne 0 ]
    [[ "$output" == *"isn't initialized"* ]]
}
