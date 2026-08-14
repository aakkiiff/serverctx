# Browses a remote server over SFTP and downloads a chosen file/folder via
# scp, into the current directory. Ported from an experimental branch
# (dev-remote-content-mgt) that was never merged to main; rewritten against
# this codebase's helpers (pick_host/resolve_host_auth/ui_*) and with a few
# real bugs from that branch fixed along the way — see inline notes.
cmd_download() {
    local full_host
    local RH_HOSTNAME RH_USER RH_PORT RH_AUTH RH_PASSWORD RH_KEYPATH
    local remote_path list_output sftp_status clean_list selection key item is_dir scp_status

    require_cmds fzf scp sftp || return 1

    full_host="$(pick_host "Download from")" || return 1
    resolve_host_auth "$full_host" || return 1
    # sshpass is only needed on the password path, so it's checked here
    # rather than up front — key-authenticated hosts shouldn't be blocked by
    # a missing sshpass (this used to surface as a raw "command not found").
    [[ "$RH_AUTH" == "pass" ]] && { require_cmds sshpass || return 1; }

    ui_title "$full_host"
    ui_muted "enter open folder / download file · c download as-is · esc cancel"
    ui_blank

    local fopts=()
    while IFS= read -r o; do fopts+=("$o"); done < <(fzf_base_opts)

    remote_path="."
    while true; do
        ui_step "Listing $remote_path on ${RH_HOSTNAME}…"
        # stderr is captured rather than discarded so a refused connection or
        # permission error can be told apart from a genuinely empty folder —
        # previously both produced the same "empty or inaccessible" message.
        #
        # -oStrictHostKeyChecking=no is specifically for this non-interactive
        # heredoc-driven listing session, which can't answer an interactive
        # "continue connecting?" prompt — the actual scp transfer below runs
        # in the foreground and is left free to use normal host-key checking.
        if [[ "$RH_AUTH" == "pass" ]]; then
            list_output=$(sshpass -f <(printf '%s' "$RH_PASSWORD") \
                sftp -P "$RH_PORT" -oBatchMode=no -oStrictHostKeyChecking=no "$RH_USER@$RH_HOSTNAME" <<SFTP_CMDS 2>&1
cd "$remote_path"
ls -l
bye
SFTP_CMDS
)
        else
            list_output=$(sftp -i "$RH_KEYPATH" -P "$RH_PORT" -oBatchMode=no -oStrictHostKeyChecking=no "$RH_USER@$RH_HOSTNAME" <<SFTP_CMDS 2>&1
cd "$remote_path"
ls -l
bye
SFTP_CMDS
)
        fi
        sftp_status=$?

        if [[ "$sftp_status" -ne 0 ]]; then
            ui_error "Couldn't reach $RH_USER@$RH_HOSTNAME."
            [[ -n "$list_output" ]] && ui_hint "$(printf '%s' "$list_output" | tail -n2)"
            return 1
        fi

        clean_list=$(printf '%s\n' "$list_output" | sed '/^sftp>/d;/^$/d;/^ls -l$/d;/^Connected to /d' \
            | awk '{name=$NF; type=substr($1,1,1); if(type=="d"){print name"/"} else {print name}}')

        if [[ -z "$clean_list" ]]; then
            ui_warn "'$remote_path' is empty."
            if [[ "$remote_path" == "." ]]; then
                ui_cancel "Nothing to download."
                return 1
            fi
            remote_path=$(dirname "$remote_path")
            continue
        fi

        # Offer a way back out — the original never listed one: `find`-based
        # navigation there never produced a ".." entry, and its Ctrl-P
        # binding just aborted the picker instead of going up.
        [[ "$remote_path" != "." ]] && clean_list=$'..\n'"$clean_list"

        selection=$(printf '%s\n' "$clean_list" | fzf "${fopts[@]}" \
            --prompt="$remote_path > " \
            --header='enter open/download · c download as-is · esc cancel' \
            --expect=enter,c)
        if [[ -z "$selection" ]]; then
            ui_cancel "Cancelled."
            return 1
        fi

        key=$(printf '%s\n' "$selection" | head -n1)
        item=$(printf '%s\n' "$selection" | tail -n1)
        item="${item%/}"
        [[ -n "$item" ]] || continue

        if [[ "$item" == ".." ]]; then
            remote_path=$(dirname "$remote_path")
            continue
        fi

        is_dir=0
        printf '%s\n' "$clean_list" | grep -qxF "$item/" && is_dir=1

        if [[ "$key" == "enter" && "$is_dir" -eq 1 ]]; then
            remote_path="$remote_path/$item"
            continue
        elif [[ "$key" != "enter" && "$key" != "c" ]]; then
            ui_cancel "Cancelled."
            return 1
        fi

        # scp -r silently overwrites whatever is already here; say so first.
        if [[ -e "./$item" ]]; then
            ui_warn "'./$item' already exists in $(pwd)."
            if ! ui_confirm "Overwrite it?"; then
                ui_cancel "Cancelled — nothing was downloaded."
                return 1
            fi
        fi

        ui_step "Downloading $remote_path/${item}…"
        # Bug in the ported version: `if CREDENTIAL_FLAG=="key"` (missing
        # [[ ]] and $) is a bare variable assignment used as a condition,
        # which "succeeds" unconditionally regardless of auth method — so
        # it always took the key-based (-i) branch, even for password auth,
        # and silently reassigned the flag variable as a side effect.
        if [[ "$RH_AUTH" == "key" ]]; then
            scp -i "$RH_KEYPATH" -P "$RH_PORT" -r "$RH_USER@$RH_HOSTNAME:$remote_path/$item" ./
        else
            sshpass -f <(printf '%s' "$RH_PASSWORD") scp -P "$RH_PORT" -r "$RH_USER@$RH_HOSTNAME:$remote_path/$item" ./
        fi
        scp_status=$?
        if [[ "$scp_status" -eq 0 ]]; then
            touch_host_recent "$full_host"
            ui_ok "Downloaded $item → $(pwd)/$item"
            return 0
        else
            ui_error "Download failed for '$item'."
            ui_hint "scp exited with status $scp_status."
            return 1
        fi
    done
}
