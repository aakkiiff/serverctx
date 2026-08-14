cmd_init() {
    local deps_failed=0 gpg_missing=0

    ui_title "Setting up serverctx"
    ui_blank

    ui_step "Checking dependencies…"
    pkg_install fzf || deps_failed=1
    pkg_install gnupg || deps_failed=1
    pkg_install sshpass || deps_failed=1
    pkg_install clipboard || deps_failed=1

    if ! require_cmds gpg; then
        ui_error "Can't continue without gpg."
        ui_hint "Install it manually, then re-run 'server init'."
        return 1
    fi

    if [[ "$OS_TYPE" == "mac" ]]; then
        # Headless/terminal pinentry frequently fails on macOS unless
        # pinentry-mac is installed and wired into gpg-agent.
        if ! command -v pinentry-mac &>/dev/null; then
            ui_step "Installing pinentry-mac (needed for GPG passphrase prompts)…"
            brew install pinentry-mac || ui_warn "Couldn't install pinentry-mac — GPG prompts may fail."
        fi
        ensure_private_dir "$HOME/.gnupg" || ui_warn "Couldn't secure ~/.gnupg — check its permissions (should be 700)."
        local pinentry_path
        pinentry_path="$(brew --prefix)/bin/pinentry-mac"
        if [[ -x "$pinentry_path" ]] && ! grep -qF "pinentry-program $pinentry_path" "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null; then
            echo "pinentry-program $pinentry_path" >> "$HOME/.gnupg/gpg-agent.conf"
            gpgconf --kill gpg-agent 2>/dev/null
        fi
    fi

    if ! gpg --list-keys | grep -q '^pub'; then
        ui_blank
        ui_title "Creating your encryption key"
        ui_muted "serverctx encrypts saved passwords with your own GPG key."
        ui_muted "The defaults are fine for most prompts:"
        ui_muted "  key type    RSA and RSA"
        ui_muted "  key size    2048 or 4096"
        ui_muted "  expiration  0 (never expires)"
        ui_muted "  passphrase  pick a strong one — it protects every saved password"
        ui_blank

        gpg --full-generate-key

        if ! gpg --list-keys | grep -q '^pub'; then
            gpg_missing=1
            ui_warn "No GPG key was created — saving passwords won't work yet."
            ui_hint "Run 'gpg --full-generate-key', then 'server init' again."
        fi
    fi

    if ! ensure_private_dir "$HOME/.ssh"; then
        ui_error "Failed to create ~/.ssh."
        ui_hint "Check the permissions on \$HOME."
        return 1
    fi
    ensure_private_dir "$HOME/.ssh/keys"

    # gpg creates ~/.gnupg itself on first use, and a keyring restored from
    # elsewhere can arrive with whatever mode it was archived with — so fix
    # it here too rather than only on the branch that created it above.
    [[ -d "$HOME/.gnupg" ]] && ensure_private_dir "$HOME/.gnupg"

    [[ -f "$SSH_CONFIG_FILE" ]] || touch "$SSH_CONFIG_FILE"
    chmod 600 "$SSH_CONFIG_FILE"

    [[ -f "$CRED_FILE" ]] || touch "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    # Persist the actual GPG identity to encrypt to, rather than assuming it
    # matches $USER (see gpg_recipient() in lib/crypto.sh for why that's
    # unsafe). Only auto-detect if nothing's configured yet, so a manually
    # chosen recipient survives re-running init.
    if [[ ! -f "$HOME/.ssh/.gpg_recipient" ]]; then
        local detected_recipient
        detected_recipient=$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^uid:/ { print $10; exit }')
        if [[ -n "$detected_recipient" ]]; then
            echo "$detected_recipient" > "$HOME/.ssh/.gpg_recipient"
            chmod 600 "$HOME/.ssh/.gpg_recipient"
            ui_muted "Encrypting passwords to GPG identity: $detected_recipient"
        fi
    fi

    ui_blank

    # Problems are reported before the closing summary — the success line
    # used to print first, so a failed dependency install scrolled past
    # underneath a cheerful "Initialized".
    if [[ "$deps_failed" -eq 1 ]]; then
        ui_warn "Some dependencies failed to install (see the errors above)."
        ui_hint "Fix those and re-run 'server init' before using the affected commands."
    fi

    if [[ "$deps_failed" -eq 0 && "$gpg_missing" -eq 0 ]]; then
        ui_ok "serverctx is ready."
        ui_muted "Add your first server with 'server add', then connect with 'server'."
    else
        ui_warn "serverctx is partially set up — see the warnings above."
    fi
}
