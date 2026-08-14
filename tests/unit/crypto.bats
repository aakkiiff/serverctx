#!/usr/bin/env bats
# Exercises real gpg against a disposable, passphrase-less test keyring
# (generated once per file into BATS_FILE_TMPDIR) — never the developer's
# real ~/.gnupg.

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

@test "encrypt_password then decrypt_password returns the original plaintext" {
    local encrypted decrypted
    encrypted=$(encrypt_password "correct horse battery staple")
    decrypted=$(decrypt_password "$encrypted")
    [ "$decrypted" = "correct horse battery staple" ]
}

@test "encrypted output is base64 (safe for a single credentials-file line) and does not contain the plaintext" {
    local encrypted
    encrypted=$(encrypt_password "hunter2")
    [[ "$encrypted" != *$'\n'* ]]
    [[ "$encrypted" != *"hunter2"* ]]
}

@test "round-trip survives special characters in the password" {
    local encrypted decrypted
    encrypted=$(encrypt_password 'p@ss/word=with$symbols&stuff')
    decrypted=$(decrypt_password "$encrypted")
    [ "$decrypted" = 'p@ss/word=with$symbols&stuff' ]
}

@test "gpg_recipient prefers an explicit GPG_RECIPIENT env override" {
    echo "from-config-file@example.com" > "$HOME/.ssh/.gpg_recipient"
    GPG_RECIPIENT="from-env@example.com" run gpg_recipient
    [ "$output" = "from-env@example.com" ]
}

@test "gpg_recipient falls back to the persisted ~/.ssh/.gpg_recipient when no env override is set" {
    echo "from-config-file@example.com" > "$HOME/.ssh/.gpg_recipient"
    unset GPG_RECIPIENT
    run gpg_recipient
    [ "$output" = "from-config-file@example.com" ]
}

@test "regression: encryption works when the GPG key's UID differs from \$USER, via the persisted recipient (not just \$USER)" {
    # This is exactly the failure mode of hardcoding GPG_RECIPIENT="$USER":
    # the test key's UID is an email, not the Unix login name, so encrypting
    # straight to "$USER" would fail with "No public key".
    echo "$GPG_RECIPIENT" > "$HOME/.ssh/.gpg_recipient"
    unset GPG_RECIPIENT

    local encrypted decrypted
    encrypted=$(encrypt_password "works-without-user-match")
    decrypted=$(decrypt_password "$encrypted")
    [ "$decrypted" = "works-without-user-match" ]
}

@test "encrypt_password fails with a clear message (not a raw gpg error) when gpg isn't installed" {
    PATH="/usr/bin:/bin" run encrypt_password "irrelevant"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing required tool(s): gpg"* ]]
}

@test "encrypt_password fails with a clear message when no GPG key exists yet, and never writes a credential silently" {
    local empty_gnupghome="$BATS_TEST_TMPDIR/empty_gnupg"
    mkdir -p "$empty_gnupghome"
    chmod 700 "$empty_gnupghome"

    GNUPGHOME="$empty_gnupghome" run encrypt_password "irrelevant"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No GPG key found"* ]]
    [[ "$output" != *"irrelevant"* ]]
}

@test "decrypt_password fails with a clear message when no GPG key exists yet, instead of a confusing empty prompt" {
    local empty_gnupghome="$BATS_TEST_TMPDIR/empty_gnupg2"
    mkdir -p "$empty_gnupghome"
    chmod 700 "$empty_gnupghome"

    GNUPGHOME="$empty_gnupghome" run decrypt_password "irrelevant"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No GPG key found"* ]]
}

@test "add.sh does not store an empty credential when encrypt_password fails (regression: callers must check its exit code)" {
    host_append_block "prod/db01" "10.0.0.5" "root" "22"

    local empty_gnupghome="$BATS_TEST_TMPDIR/empty_gnupg3"
    mkdir -p "$empty_gnupghome"
    chmod 700 "$empty_gnupghome"

    GNUPGHOME="$empty_gnupghome" run cmd_add <<'INPUT'
db02
10.0.0.6
root

prod
secret123
INPUT

    [ "$status" -ne 0 ]
    run cred_exists "prod/db02"
    [ "$status" -ne 0 ]
    run host_exists "prod/db02"
    [ "$status" -ne 0 ]
}
