cmd_remember() {
    local full_host hostname user value decrypted_password

    require_cmds fzf sshpass ssh-copy-id || return 1

    full_host="$(pick_host "Set up passwordless login for")" || return 1
    hostname=$(host_get_field "$full_host" "HostName")
    user=$(host_get_field "$full_host" "User")

    if ! cred_exists "$full_host"; then
        ui_error "No password saved for '$full_host'."
        ui_hint "ssh-copy-id needs the password once to install your key. Add it with 'server edit'."
        return 1
    fi

    value=$(cred_get "$full_host")
    ui_step "Decrypting saved password…"
    decrypted_password=$(decrypt_password "$value") || return 1
    if [[ -z "$decrypted_password" ]]; then
        ui_error "Failed to decrypt the password for '$full_host'."
        return 1
    fi

    ui_step "Copying your public key to $user@${hostname}…"
    # -f/process-substitution (not -p) keeps the plaintext password out of
    # the argv, so it never shows up in `ps` output for other local users.
    if sshpass -f <(printf '%s' "$decrypted_password") ssh-copy-id -f "$user@$hostname" 2>&1 >/dev/null; then
        touch_host_recent "$full_host"
        ui_ok "Passwordless login is set up for $full_host."
    else
        ui_error "ssh-copy-id failed for '$full_host'."
        ui_hint "Check that the host is reachable and the saved password is correct."
        return 1
    fi
}
