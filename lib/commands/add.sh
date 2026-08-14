cmd_add() {
    local name hostname user port group password private_key encrypted_password
    local full_host identity_file keypath auth_summary

    ui_title "Add a server"
    ui_muted "Press Ctrl-C at any point to cancel."
    ui_blank

    # Identity (group + name) is collected first so the "already exists"
    # check can run immediately. It used to run only after hostname, user
    # and port had also been typed, throwing all of that away on a clash.
    while true; do
        read -rp "Server name (e.g. web-01): " name || return 1
        validate_token "$name" "Server name" && break
    done

    while true; do
        read -rp "Group [default]: " group || return 1
        group=${group:-default}
        validate_token "$group" "Group" && break
    done

    full_host="$(cred_key "$group" "$name")" # "group/name"

    if host_exists "$full_host"; then
        ui_error "'$full_host' already exists."
        ui_hint "Use 'server edit' to change it, or pick a different name."
        return 1
    fi

    while true; do
        read -rp "HostName (IP or domain): " hostname || return 1
        validate_hostname "$hostname" && break
    done

    while true; do
        read -rp "User: " user || return 1
        [[ -n "$user" ]] && break
        ui_error "User cannot be empty."
    done

    while true; do
        # `|| return 1` matters here: on EOF (Ctrl-D, or piped stdin that
        # ran out) read fails and leaves the variable empty, and without it
        # this loop would reprint its error forever.
        read -rp "Port [22]: " port || return 1
        port=${port:-22}
        validate_port "$port" && break
    done

    ui_blank
    ui_muted "Leave the password blank to authenticate with an SSH key instead."
    read -rsp "Password: " password || return 1
    ui_blank

    auth_summary="none"

    if [[ -n "$password" ]]; then
        encrypted_password=$(encrypt_password "$password") || return 1
        cred_set "$full_host" "$encrypted_password"
        auth_summary="🔒 password"
    else
        read -rp "Path to private key (Enter to skip): " private_key || return 1
        private_key="$(expand_tilde "$private_key")"

        if [[ -n "$private_key" ]]; then
            while [[ ! -f "$private_key" ]]; do
                ui_error "'$private_key' not found."
                read -rp "Path to private key (Enter to skip): " private_key || return 1
                private_key="$(expand_tilde "$private_key")"
                [[ -z "$private_key" ]] && break
            done
            if [[ -n "$private_key" && -f "$private_key" ]]; then
                keypath="$(keyfile_path "$group" "$name")"
                ensure_private_dir "$(dirname "$keypath")"
                cp "$private_key" "$keypath"
                chmod 600 "$keypath"
                auth_summary="🔑 ssh key"
            fi
        fi
    fi

    identity_file=""
    [[ -f "$(keyfile_path "$group" "$name")" ]] && identity_file="$(keyfile_path "$group" "$name")"

    host_append_block "$full_host" "$hostname" "$user" "$port" "$identity_file"

    # Previously only the password branch reported success — adding a
    # key-authenticated host, or one with no credential at all, printed
    # nothing and left you unsure whether it had worked.
    ui_ok "Added $full_host ($user@$hostname:$port, auth: $auth_summary)"

    if [[ "$auth_summary" == "none" ]]; then
        ui_warn "No password or key saved — 'server ssh' will not be able to log in."
        ui_hint "Add one later with 'server edit'."
    fi
}
