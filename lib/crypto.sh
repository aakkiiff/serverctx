# Password encryption at rest, via the user's own GPG keypair.
# SSH_CONFIG_FILE/CRED_FILE are set by the entrypoint before sourcing this
# file (and are overridable via env for tests).

# Resolves who to encrypt to: an explicit $GPG_RECIPIENT env override wins;
# otherwise the identity cmd_init detected and persisted to
# ~/.ssh/.gpg_recipient; otherwise $USER as a last resort.
#
# $USER alone is NOT a safe default: it's only correct if the user's GPG key
# UID happens to be their Unix login name, which it usually isn't (keys are
# normally keyed to an email). Assuming otherwise silently breaks every
# encrypt/decrypt call with "No public key" — cmd_init's auto-detection step
# exists specifically to avoid that.
gpg_recipient() {
    if [[ -n "${GPG_RECIPIENT:-}" ]]; then
        echo "$GPG_RECIPIENT"
        return
    fi
    if [[ -f "$HOME/.ssh/.gpg_recipient" ]]; then
        cat "$HOME/.ssh/.gpg_recipient"
        return
    fi
    echo "$USER"
}

# Checked by encrypt/decrypt before touching gpg, so a missing binary or
# missing key surfaces as one clear line instead of a raw gpg stderr dump
# (or, worse for encrypt_password specifically, an empty-but-"successful"
# credential silently written — see callers, which now check its exit code).
gpg_ready() {
    require_cmds gpg || return 1
    if [[ -z "$(gpg --list-secret-keys --with-colons 2>/dev/null)" ]]; then
        ui_error "No GPG key found."
        ui_hint "Run 'server init' to set one up."
        return 1
    fi
    return 0
}

encrypt_password() {
    gpg_ready || return 1
    local plain="$1"
    echo -n "$plain" | gpg --yes -r "$(gpg_recipient)" -e --armor | base64 | tr -d '\n'
}

decrypt_password() {
    gpg_ready || return 1
    local encrypted="$1"
    echo "$encrypted" | base64 --decode | gpg --quiet --decrypt
}
