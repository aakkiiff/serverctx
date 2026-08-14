# List servers with reachability/password/key status.
#
# The original implementation used `declare -A` (bash 4+ associative
# arrays), which crashes outright on macOS's stock /bin/bash 3.2
# ("declare: -A: invalid option"). This version only uses indexed
# variables and a scratch directory of one file per host, which works on
# bash 3.2+ everywhere.

# Minimal JSON string escaping: the values below come out of ~/.ssh/config,
# which a user can hand-edit, so quotes and backslashes have to survive.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

cmd_list() {
    local as_json=0 do_ping=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)    as_json=1 ;;
            --no-ping) do_ping=0 ;;
            *)
                ui_error "Unknown option for 'server ls': $1"
                ui_hint "Valid options: --json, --no-ping"
                return 1
                ;;
        esac
        shift
    done

    local tmpdir manifest count max_name_len host_count
    if [[ "$as_json" -eq 1 ]]; then
        # For composability, an initialized-but-empty setup is a legitimate
        # empty result (handled as "[]" below), not an error — only a
        # missing config is worth failing on.
        if [[ ! -f "$SSH_CONFIG_FILE" ]]; then
            ui_error "serverctx isn't initialized yet."
            ui_hint "Run 'server init' first."
            return 1
        fi
    else
        require_hosts || return 1
    fi

    tmpdir=$(mktemp -d) || { ui_error "Failed to create a temp directory."; ui_hint "Check disk space and permissions on /tmp."; return 1; }
    manifest="$tmpdir/manifest.tsv"

    # alias<TAB>hostname<TAB>port<TAB>statusfile — a numbered statusfile per
    # line avoids deriving a filename from the alias (which could collide if
    # two group/name pairs flatten to the same string).
    local i=0 alias hostname port
    while IFS=$'\t' read -r alias hostname port; do
        i=$((i + 1))
        printf '%s\t%s\t%s\t%s\n' "$alias" "$hostname" "$port" "$tmpdir/$i.status" >> "$manifest"
    done < <(awk '
        $1=="Host" { if (host != "") print host "\t" hostname "\t" port; host=$2; hostname=""; port=""; next }
        host != "" && $1=="HostName" { hostname=$2 }
        host != "" && $1=="Port" { port=$2 }
        END { if (host != "") print host "\t" hostname "\t" port }
    ' "$SSH_CONFIG_FILE" 2>/dev/null)

    if [[ ! -s "$manifest" ]]; then
        rm -rf "$tmpdir"
        # Still valid JSON for a caller piping into jq.
        if [[ "$as_json" -eq 1 ]]; then
            printf '[]\n'
            return 0
        fi
        ui_error "No hosts found."
        ui_hint "Add your first one with 'server add'."
        return 1
    fi

    host_count=$(wc -l < "$manifest" | tr -d ' ')

    local statusfile
    if [[ "$do_ping" -eq 1 ]]; then
        # Checking N hosts can take a second or more; without this the terminal
        # just sits there looking hung while the pings fan out. Suppressed in
        # JSON mode, where stray stdout would corrupt the document.
        [[ "$as_json" -eq 1 ]] || ui_step "Checking $host_count host(s)…"
        while IFS=$'\t' read -r alias hostname port statusfile; do
            (
                # A host counts as online if it answers ping OR has its SSH port
                # open — ping alone misses hosts that block ICMP but allow SSH
                # (common behind cloud security groups); see host_reachable.
                if host_reachable "$hostname" "$port" 1; then
                    echo "online" > "$statusfile"
                else
                    echo "offline" > "$statusfile"
                fi
            ) &
        done < "$manifest"
        wait
    fi

    if [[ "$as_json" -eq 1 ]]; then
        _list_json "$manifest" "$do_ping"
        rm -rf "$tmpdir"
        return 0
    fi

    max_name_len=4  # at least as wide as the "NAME" header
    while IFS=$'\t' read -r alias hostname port statusfile; do
        local servername="${alias#*/}"
        (( ${#servername} > max_name_len )) && max_name_len=${#servername}
    done < "$manifest"

    count=0
    local group servername state status_cell pw_cell key_cell keypath
    for group in $(host_group_list); do
        printf '\n%s%s%s\n' "$_UI_C_CYAN$_UI_C_BOLD" "$group" "$_UI_C_RESET"
        # Header row: the glyph columns previously had no labels at all, so
        # 🔒/🔑/❌ were left to be guessed at. Header text is pure ASCII, so
        # %-Ns padding is accurate here.
        printf '%s  %-*s   %-10s   %-3s %-3s%s\n' \
            "$_UI_C_DIM" "$max_name_len" "NAME" "STATUS" "PW" "KEY" "$_UI_C_RESET"

        while IFS=$'\t' read -r alias hostname port statusfile; do
            [[ "$alias" == "$group/"* ]] || continue
            count=$((count + 1))
            servername="${alias#*/}"

            state="unknown"
            [[ -f "$statusfile" ]] && state=$(cat "$statusfile")

            # Emoji are double-width on screen but count as one character to
            # printf, so %-Ns can't align a column containing them. Each cell
            # below is instead assembled to a known *display* width: a
            # width-2 glyph, a space, then a %-7s word == 10 columns; and
            # width-2 "🔒" against a width-2 "· " for the boolean columns.
            case "$state" in
                online)  status_cell="🟢 $(printf '%-7s' 'online')" ;;
                offline) status_cell="🔴 $(printf '%-7s' 'offline')" ;;
                *)       status_cell="⚪ $(printf '%-7s' 'unknown')" ;;
            esac

            # "·" rather than ❌ for "not configured": ❌ is the error glyph
            # everywhere else, so a perfectly healthy key-only host used to
            # look like it had something wrong with it.
            if cred_exists "$alias"; then pw_cell="🔒 "; else pw_cell="·  "; fi

            keypath="$(keyfile_path "$group" "$servername")"
            if [[ -f "$keypath" ]]; then key_cell="🔑 "; else key_cell="·  "; fi

            # Data goes only through %s arguments, never into the format
            # string itself — a '%' in a hand-edited alias used to be parsed
            # as a conversion spec and mangle the row. The %-*s applies to
            # the bare name; the color codes are separate zero-width args so
            # they don't consume padding.
            printf '  %s%-*s%s   %s   %s %s\n' \
                "$_UI_C_GREEN" "$max_name_len" "$servername" "$_UI_C_RESET" \
                "$status_cell" "$pw_cell" "$key_cell"
        done < "$manifest"
    done

    if [[ "$do_ping" -eq 1 ]]; then
        printf '\n%s%d host(s)   🟢 reachable   🔒 password saved   🔑 key saved   ·  not set%s\n\n' \
            "$_UI_C_DIM" "$count" "$_UI_C_RESET"
    else
        printf '\n%s%d host(s)   status not checked (--no-ping)   🔒 password saved   🔑 key saved%s\n\n' \
            "$_UI_C_DIM" "$count" "$_UI_C_RESET"
    fi

    rm -rf "$tmpdir"
}

# Emits the manifest as a JSON array on stdout. Kept separate from the
# table rendering so neither has to carry the other's formatting concerns.
_list_json() {
    local manifest="$1" do_ping="$2"
    local alias hostname port statusfile group servername state keypath
    local first=1

    printf '[\n'
    while IFS=$'\t' read -r alias hostname port statusfile; do
        group="${alias%%/*}"
        servername="${alias#*/}"
        keypath="$(keyfile_path "$group" "$servername")"

        if [[ "$do_ping" -eq 1 ]]; then
            state="unknown"
            [[ -f "$statusfile" ]] && state=$(cat "$statusfile")
            state="\"$(json_escape "$state")\""
        else
            state="null"
        fi

        [[ "$first" -eq 1 ]] || printf ',\n'
        first=0

        # Emitted unquoted as a JSON number, so anything non-numeric from a
        # hand-edited config would make the document invalid.
        [[ "$port" =~ ^[0-9]+$ ]] || port=22

        printf '  {"host":"%s","group":"%s","name":"%s","hostname":"%s","user":"%s","port":%s,"status":%s,"password":%s,"key":%s}' \
            "$(json_escape "$alias")" \
            "$(json_escape "$group")" \
            "$(json_escape "$servername")" \
            "$(json_escape "$hostname")" \
            "$(json_escape "$(host_get_field "$alias" "User")")" \
            "$port" \
            "$state" \
            "$(cred_exists "$alias" && echo true || echo false)" \
            "$([[ -f "$keypath" ]] && echo true || echo false)"
    done < "$manifest"
    printf '\n]\n'
}
