cmd_editgroup() {
    local old_group new_group affected

    require_cmds fzf || return 1

    old_group="$(pick_group "Rename group")" || return 1

    read -rp "New name for group '$old_group': " new_group || return 1
    validate_token "$new_group" "Group name" || return 1

    if [[ "$new_group" == "$old_group" ]]; then
        ui_cancel "That's already the group's name — nothing to do."
        return 1
    fi

    if host_group_list | grep -qxF "$new_group"; then
        ui_warn "Group '$new_group' already exists — its hosts will be merged together."
    fi

    # This rewrites the ssh config, the credentials file and the key
    # directory in one shot with no undo, so show the blast radius first.
    affected="$(host_names_in_group "$old_group" | wc -l | tr -d ' ')"
    ui_warn "Renaming '$old_group' → '$new_group' will update $affected host(s):"
    ui_hint "· their entries in $SSH_CONFIG_FILE"
    ui_hint "· their saved passwords"
    ui_hint "· their SSH keys under $HOME/.ssh/keys/$old_group"

    if ! ui_confirm "Rename group '$old_group'?"; then
        ui_cancel "Cancelled — nothing was renamed."
        return 1
    fi

    ui_step "Renaming…"
    host_rename_group_prefix "$old_group" "$new_group"
    cred_rename_group_prefix "$old_group" "$new_group"
    keyfile_rename_group_prefix "$old_group" "$new_group"

    ui_ok "Renamed group $old_group → $new_group ($affected host(s))"
}
