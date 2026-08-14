cmd_backup() {
    require_cmds tar || return 1

    ui_title "Backing up serverctx"

    # The old code blew away any existing backup with `rm -rf` before it knew
    # whether the new one would even succeed — a failed backup could leave
    # you with neither.
    if [[ -d "$backup_dir" ]]; then
        ui_warn "'$backup_dir' already exists and will be replaced."
        if ! ui_confirm "Overwrite the existing backup?"; then
            ui_cancel "Cancelled — the existing backup was left alone."
            return 1
        fi
        rm -rf "$backup_dir"
    fi

    if ! mkdir -p "$backup_dir"; then
        ui_error "Failed to create '$backup_dir'."
        ui_hint "Check the permissions in $(pwd)."
        return 1
    fi
    chmod 700 "$backup_dir"

    if [[ ! -f "$SSH_CONFIG_FILE" ]]; then
        ui_error "No SSH config found at $SSH_CONFIG_FILE."
        ui_hint "Run 'server init' first."
        return 1
    fi
    cp "$SSH_CONFIG_FILE" "$backup_dir/ssh_config"
    ui_ok "SSH config"

    if [[ ! -f "$CRED_FILE" ]]; then
        ui_warn "No credentials file at $CRED_FILE — continuing without it."
    else
        cp "$CRED_FILE" "$backup_dir/server_credentials"
        ui_ok "Saved passwords"
    fi

    # tar's exit code isn't checked directly below: it returns non-zero for
    # non-fatal warnings too (e.g. "pax format cannot archive sockets" from
    # a live gpg-agent socket, which we don't want preserved anyway) — the
    # actual signal that the backup worked is whether a non-empty archive
    # came out the other end.
    if [[ -d "$HOME/.ssh/keys" ]]; then
        tar -cf "$backup_dir/ssh-keys-backup.tar" -C "$HOME/.ssh" keys
        if [[ -s "$backup_dir/ssh-keys-backup.tar" ]]; then
            ui_ok "SSH keys"
        else
            ui_warn "Failed to archive SSH keys (see the tar output above)."
        fi
    else
        ui_warn "No SSH keys at $HOME/.ssh/keys — skipping."
    fi

    # Checking for an actual keyring directory rather than `gpg --list-keys
    # "$GPG_RECIPIENT"`: GPG_RECIPIENT may be unset here and resolved later,
    # elsewhere, via gpg_recipient() (env override, or the identity `server
    # init` persisted to ~/.ssh/.gpg_recipient) — this check shouldn't
    # depend on that resolution to decide whether a keyring exists to back up.
    if [[ -d "$HOME/.gnupg" ]] && gpg --list-secret-keys &>/dev/null; then
        tar -cf "$backup_dir/gnupg-backup.tar" -C "$HOME" .gnupg
        if [[ -s "$backup_dir/gnupg-backup.tar" ]]; then
            ui_ok "GPG keyring"
        else
            ui_warn "Failed to archive the GPG keyring (see the tar output above)."
        fi
    else
        ui_warn "No GPG keyring at $HOME/.gnupg — skipping."
    fi

    chmod 600 "$backup_dir"/* 2>/dev/null

    ui_blank
    ui_ok "Backup written to $backup_dir"
    ui_warn "This backup contains your GPG private key and your encrypted passwords."
    ui_hint "Together they are enough to read every saved password."
    ui_hint "Move it somewhere encrypted and delete this copy when you're done."
}
