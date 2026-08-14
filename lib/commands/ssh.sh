cmd_ssh() {
    local full_host group selected_host value decrypted_password keypath

    require_cmds fzf ssh || return 1

    full_host="$(pick_host "Connect to")" || return 1
    group="${full_host%%/*}"
    selected_host="${full_host#*/}"

    if cred_exists "$full_host"; then
        value=$(cred_get "$full_host")
        ui_step "Decrypting saved password…"
        decrypted_password=$(decrypt_password "$value") || return 1
        if [[ -z "$decrypted_password" ]]; then
            ui_error "Failed to decrypt the password for '$full_host'."
            return 1
        fi

        # Only promise the clipboard if the copy actually succeeded —
        # clipboard_copy fails (with its own warning) when no pbcopy/wl-copy/
        # xclip is available, and this used to claim success regardless.
        if printf '%s' "$decrypted_password" | clipboard_copy; then
            clipboard_clear_after 30
            ui_ok "Password copied to clipboard — clears in 30s."
        fi
        ui_step "Connecting to ${full_host}…"
        touch_host_recent "$full_host"
        ssh "$full_host"
    else
        keypath="$(keyfile_path "$group" "$selected_host")"
        if [[ -f "$keypath" ]]; then
            # Not an error: connecting by key is a perfectly normal setup.
            # This previously printed "❌ Password is not saved" first on
            # every successful key-based connection, which read as a failure.
            ui_step "Connecting to $full_host using its SSH key…"
            touch_host_recent "$full_host"
            ssh -i "$keypath" "$full_host"
        else
            ui_error "No password or SSH key saved for '$full_host'."
            ui_hint "Add one with 'server edit', or set up key auth with 'server remember'."
            return 1
        fi
    fi
}
