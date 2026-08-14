cmd_restore() {
    local import_dir

    require_cmds tar || return 1

    if [[ ! -d "$HOME/.ssh" ]]; then
        if ! ensure_private_dir "$HOME/.ssh"; then
            ui_error "Failed to create ~/.ssh."
            ui_hint "Check the permissions on \$HOME."
            return 1
        fi
        ui_muted "Created ~/.ssh"
    fi

    read -rp "Import directory [./serverctx_backup]: " import_dir || return 1
    import_dir="${import_dir:-./serverctx_backup}"
    import_dir="$(expand_tilde "$import_dir")"

    if [[ ! -d "$import_dir" ]]; then
        ui_error "'$import_dir' not found."
        return 1
    fi

    # Verify the archives BEFORE touching anything. The old flow ran
    # `rm -rf ~/.gnupg` first and only discovered a corrupt tarball
    # afterwards — by which point the user's entire GPG keyring, and with it
    # the ability to decrypt every saved password, was already gone.
    if [[ -f "$import_dir/gnupg-backup.tar" ]] && ! tar -tf "$import_dir/gnupg-backup.tar" &>/dev/null; then
        ui_error "'$import_dir/gnupg-backup.tar' is unreadable or corrupt."
        ui_hint "Nothing has been changed. Check the backup and try again."
        return 1
    fi
    if [[ -f "$import_dir/ssh-keys-backup.tar" ]] && ! tar -tf "$import_dir/ssh-keys-backup.tar" &>/dev/null; then
        ui_error "'$import_dir/ssh-keys-backup.tar' is unreadable or corrupt."
        ui_hint "Nothing has been changed. Check the backup and try again."
        return 1
    fi

    ui_blank
    ui_warn "Restoring from '$import_dir' will overwrite:"
    [[ -f "$import_dir/ssh_config" ]]          && ui_hint "· $SSH_CONFIG_FILE (all current host entries)"
    [[ -f "$import_dir/server_credentials" ]]  && ui_hint "· $CRED_FILE (all saved passwords)"
    [[ -f "$import_dir/ssh-keys-backup.tar" ]] && ui_hint "· $HOME/.ssh/keys"
    [[ -f "$import_dir/gnupg-backup.tar" ]]    && ui_hint "· $HOME/.gnupg — your entire GPG keyring, replaced"

    if ! ui_confirm "Restore over your current setup?"; then
        ui_cancel "Cancelled — nothing was changed."
        return 1
    fi

    ui_blank
    ui_step "Restoring from ${import_dir}…"

    if [[ -f "$import_dir/ssh_config" ]]; then
        if cp "$import_dir/ssh_config" "$SSH_CONFIG_FILE"; then
            chmod 600 "$SSH_CONFIG_FILE"
            ui_ok "SSH config"
        else
            ui_warn "Failed to restore the SSH config — check permissions on $SSH_CONFIG_FILE."
        fi
    else
        ui_warn "No ssh_config in the backup — skipping."
    fi

    if [[ -f "$import_dir/server_credentials" ]]; then
        if cp "$import_dir/server_credentials" "$CRED_FILE"; then
            chmod 600 "$CRED_FILE"
            ui_ok "Saved passwords"
        else
            ui_warn "Failed to restore credentials — check permissions on $CRED_FILE."
        fi
    else
        ui_warn "No server_credentials in the backup — skipping."
    fi

    if [[ -f "$import_dir/gnupg-backup.tar" ]]; then
        rm -rf "$HOME/.gnupg"
        if tar -xf "$import_dir/gnupg-backup.tar" -C "$HOME"; then
            find "$HOME/.gnupg" -type d -exec chmod 700 {} \;
            find "$HOME/.gnupg" -type f -exec chmod 600 {} \;
            ui_ok "GPG keyring"
        else
            ui_error "Failed to extract the GPG keyring."
            ui_hint "Your previous ~/.gnupg has been removed — restore it from another backup."
        fi
    else
        ui_warn "No gnupg-backup.tar in the backup — skipping."
    fi

    if [[ -f "$import_dir/ssh-keys-backup.tar" ]]; then
        ensure_private_dir "$HOME/.ssh/keys"
        if tar -xf "$import_dir/ssh-keys-backup.tar" -C "$HOME/.ssh"; then
            find "$HOME/.ssh/keys" -type d -exec chmod 700 {} \;
            find "$HOME/.ssh/keys" -type f -exec chmod 600 {} \;
            ui_ok "SSH keys"
        else
            ui_warn "Failed to extract the SSH keys."
        fi
    else
        ui_warn "No ssh-keys-backup.tar in the backup — skipping."
    fi

    ui_blank
    ui_ok "Restore complete."
    ui_muted "Check your servers with 'server ls'."
}
