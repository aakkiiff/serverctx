# Interactive local file/folder picker for cmd_upload, browsable via fzf.
# Rewritten from the ported version's `local_fzf()`: that one leaked its
# working vars into the caller (no `local`), and its "go up a directory"
# never actually worked — `find "$dir" -maxdepth 1 -not -path "$dir"` only
# ever lists $dir's own children, never a ".." entry, and its Ctrl-P binding
# just aborted the picker outright instead of navigating up.
pick_local_path() {
    local dir="." entries sel key choice path
    local fopts=()
    while IFS= read -r o; do fopts+=("$o"); done < <(fzf_base_opts)

    while true; do
        # Strips the leading "$dir/" with a parameter expansion per line
        # rather than `sed "s|^$dir/||"` — $dir went straight into a sed
        # pattern, so a directory name containing a regex metacharacter or a
        # '|' broke the listing.
        entries=""
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            entries+="${f#"$dir"/}"$'\n'
        done < <(find "$dir" -mindepth 1 -maxdepth 1 | sort)
        entries="${entries%$'\n'}"

        [[ "$dir" != "." ]] && entries=$'..\n'"$entries"

        if [[ -z "$entries" ]]; then
            ui_warn "'$dir' is empty."
            [[ "$dir" == "." ]] && return 1
            dir="$(dirname "$dir")"
            continue
        fi

        sel=$(printf '%s\n' "$entries" | fzf "${fopts[@]}" \
            --prompt="$dir > " \
            --header='enter open folder / pick file · c pick as-is · esc cancel' \
            --expect=enter,c)
        [[ -n "$sel" ]] || return 1

        key=$(printf '%s\n' "$sel" | head -n1)
        choice=$(printf '%s\n' "$sel" | tail -n1)
        [[ -n "$choice" ]] || return 1

        if [[ "$choice" == ".." ]]; then
            dir="$(dirname "$dir")"
            continue
        fi

        path="$dir/$choice"
        if [[ "$key" == "enter" && -d "$path" ]]; then
            dir="$path"
            continue
        fi
        printf '%s\n' "$path"
        return 0
    done
}

cmd_upload() {
    local full_host file_or_folder upload_path scp_status
    local RH_HOSTNAME RH_USER RH_PORT RH_AUTH RH_PASSWORD RH_KEYPATH

    require_cmds fzf scp || return 1

    full_host="$(pick_host "Upload to")" || return 1
    resolve_host_auth "$full_host" || return 1
    [[ "$RH_AUTH" == "pass" ]] && { require_cmds sshpass || return 1; }

    ui_title "Upload to $full_host"
    ui_muted "Choose a local file or folder."
    file_or_folder=$(pick_local_path)
    if [[ -z "$file_or_folder" ]]; then
        ui_cancel "Cancelled — nothing was uploaded."
        return 1
    fi

    # The old default assumed /home/$user, which is wrong for root
    # (/root), for macOS remotes (/Users/...), and for any non-standard
    # home. "." is the remote default directory scp lands in — the user's
    # actual home, whatever it happens to be.
    read -rp "Remote destination [.]: " upload_path || return 1
    upload_path="${upload_path:-.}"

    ui_step "Uploading $file_or_folder → $RH_USER@$RH_HOSTNAME:${upload_path}…"
    if [[ "$RH_AUTH" == "key" ]]; then
        scp -i "$RH_KEYPATH" -P "$RH_PORT" -r "$file_or_folder" "$RH_USER@$RH_HOSTNAME:$upload_path"
    else
        sshpass -f <(printf '%s' "$RH_PASSWORD") scp -P "$RH_PORT" -r "$file_or_folder" "$RH_USER@$RH_HOSTNAME:$upload_path"
    fi
    scp_status=$?

    if [[ "$scp_status" -eq 0 ]]; then
        touch_host_recent "$full_host"
        ui_ok "Uploaded $file_or_folder → $RH_USER@$RH_HOSTNAME:$upload_path"
        return 0
    else
        ui_error "Upload failed for '$file_or_folder'."
        ui_hint "scp exited with status $scp_status."
        return 1
    fi
}
