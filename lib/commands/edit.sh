cmd_edit() {
    local selected_group selected_name full_old_host full_new_host
    local old_hostname old_port old_user new_hostname new_port new_user
    local new_group new_name password private_key old_keypath new_keypath identity_file encrypted_password

    require_cmds fzf || return 1

    full_old_host="$(pick_host "Edit")" || return 1
    selected_group="${full_old_host%%/*}"
    selected_name="${full_old_host#*/}"

    old_hostname=$(host_get_field "$full_old_host" "HostName")
    old_port=$(host_get_field "$full_old_host" "Port")
    old_user=$(host_get_field "$full_old_host" "User")
    old_keypath="$(keyfile_path "$selected_group" "$selected_name")"

    # Show what's currently stored before asking what to change — in
    # particular whether a password or key exists, which was previously
    # invisible and left the user guessing at the password prompt.
    ui_title "Editing $full_old_host"
    if cred_exists "$full_old_host"; then
        ui_muted "Auth: 🔒 password saved"
    elif [[ -f "$old_keypath" ]]; then
        ui_muted "Auth: 🔑 ssh key at $old_keypath"
    else
        ui_muted "Auth: none saved"
    fi
    ui_muted "Press Enter to keep the current value shown in [brackets]."
    ui_blank

    read -rp "Group [$selected_group]: " new_group || return 1
    new_group=${new_group:-$selected_group}
    validate_token "$new_group" "Group" || return 1

    read -rp "Name [$selected_name]: " new_name || return 1
    new_name=${new_name:-$selected_name}
    validate_token "$new_name" "Server name" || return 1

    full_new_host="$new_group/$new_name"

    # Checked here, immediately after the name is known, rather than after
    # the password prompt — the old order made you type a password only to
    # be told the target name was already taken, discarding everything.
    if [[ "$full_new_host" != "$full_old_host" ]] && host_exists "$full_new_host"; then
        ui_error "'$full_new_host' already exists."
        ui_hint "Pick a different group or name."
        return 1
    fi

    while true; do
        read -rp "HostName [$old_hostname]: " new_hostname || return 1
        new_hostname=${new_hostname:-$old_hostname}
        validate_hostname "$new_hostname" && break
    done

    read -rp "User [$old_user]: " new_user || return 1
    new_user=${new_user:-$old_user}

    while true; do
        # `|| return 1` on the read: without it, EOF (Ctrl-D, or a closed
        # stdin when piped) leaves the variable empty and this loop reprints
        # its error forever.
        read -rp "Port [${old_port:-22}]: " new_port || return 1
        new_port=${new_port:-${old_port:-22}}
        validate_port "$new_port" && break
    done

    read -rsp "New password (Enter to keep current): " password || return 1
    ui_blank

    # Credentials: an explicit new password always wins; otherwise, if the
    # identity (group/name) changed, carry the existing credential over to
    # the new key so it isn't orphaned under the old one.
    if [[ -n "$password" ]]; then
        encrypted_password="$(encrypt_password "$password")" || return 1
        cred_set "$full_new_host" "$encrypted_password"
        [[ "$full_new_host" != "$full_old_host" ]] && cred_delete "$full_old_host"
    elif [[ "$full_new_host" != "$full_old_host" ]] && cred_exists "$full_old_host"; then
        cred_set "$full_new_host" "$(cred_get "$full_old_host")"
        cred_delete "$full_old_host"
        ui_muted "Saved password carried over to $full_new_host."
    fi

    # Key file handling happens before the config block is (re)written below,
    # so the final IdentityFile path (if any) is known up front instead of
    # having to patch the block after the fact.
    read -rp "Path to new private key (Enter to keep current): " private_key || true
    private_key="$(expand_tilde "$private_key")"
    new_keypath="$(keyfile_path "$new_group" "$new_name")"

    if [[ -n "$private_key" ]]; then
        if [[ -f "$private_key" ]]; then
            ensure_private_dir "$(dirname "$new_keypath")"
            cp "$private_key" "$new_keypath"
            chmod 600 "$new_keypath"
            [[ "$new_keypath" != "$old_keypath" && -f "$old_keypath" ]] && rm -f "$old_keypath"
        else
            # Warning, not an error: nothing was lost, the existing key is
            # still in place and the edit continues.
            ui_warn "'$private_key' not found — keeping the existing key."
        fi
    elif [[ "$new_keypath" != "$old_keypath" && -f "$old_keypath" ]]; then
        ensure_private_dir "$(dirname "$new_keypath")"
        mv "$old_keypath" "$new_keypath"
        ui_muted "SSH key moved to $new_keypath."
    fi

    identity_file=""
    [[ -f "$new_keypath" ]] && identity_file="$new_keypath"

    host_remove_block "$full_old_host"
    host_append_block "$full_new_host" "$new_hostname" "$new_user" "$new_port" "$identity_file"

    if [[ "$full_new_host" == "$full_old_host" ]]; then
        ui_ok "Updated $full_new_host"
    else
        ui_ok "Updated $full_old_host → $full_new_host"
    fi
}
