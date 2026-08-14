cmd_pswd() {
    local full_host value decrypted_password

    require_cmds fzf || return 1

    full_host="$(pick_host "Show password for")" || return 1

    if ! cred_exists "$full_host"; then
        ui_error "No password saved for '$full_host'."
        ui_hint "Add one with 'server edit'."
        return 1
    fi

    value=$(cred_get "$full_host")
    ui_step "Decrypting…"
    decrypted_password=$(decrypt_password "$value") || return 1
    if [[ -z "$decrypted_password" ]]; then
        ui_error "Failed to decrypt the password for '$full_host'."
        return 1
    fi

    ui_info "$decrypted_password"
    ui_muted "(shown for $full_host — mind your scrollback)"
}
