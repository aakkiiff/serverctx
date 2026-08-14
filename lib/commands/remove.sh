cmd_remove() {
    local full_host group selected_host keypath

    require_cmds fzf || return 1

    full_host="$(pick_host "Remove")" || return 1
    group="${full_host%%/*}"
    selected_host="${full_host#*/}"
    keypath="$(keyfile_path "$group" "$selected_host")"

    # Spell out everything that's about to be deleted, rather than asking to
    # confirm an unspecified "and its saved password/key".
    ui_warn "This will permanently delete:"
    ui_hint "· the '$full_host' entry in $SSH_CONFIG_FILE"
    cred_exists "$full_host" && ui_hint "· its saved password"
    [[ -f "$keypath" ]] && ui_hint "· its SSH key at $keypath"

    if ! ui_confirm "Delete '$full_host'?"; then
        ui_cancel "Cancelled — nothing was deleted."
        return 1
    fi

    host_remove_block "$full_host"
    cred_delete "$full_host"
    if [[ -f "$keypath" ]]; then
        rm "$keypath"
    fi

    ui_ok "Removed $full_host"
    return 0
}
