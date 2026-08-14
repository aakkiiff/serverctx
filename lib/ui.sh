# The single source of truth for user-facing output.
#
# Before this existed every message was a bare `echo` with a hardcoded emoji,
# which drifted badly: the same condition printed to stdout in one command and
# stderr in another, ⚠️ was followed by one space in some files and two in
# others, and only 2 of 17 files emitted any color. Route everything through
# these helpers so those rules are enforced in one place rather than restated
# ~90 times.
#
# Conventions encoded here:
#   - Errors and warnings go to stderr. Always. Progress/success go to stdout.
#   - One space after the glyph, everywhere.
#   - Color only when the target stream is a TTY and the user hasn't opted out
#     (see supports_color in os.sh).
#   - printf, never `echo -e`: message text can contain host names and paths,
#     and echo -e would interpret backslashes inside them.

# Palette. Resolved once at source time per stream, since stdout and stderr
# can be redirected independently (e.g. `server ls > file` leaves stderr a
# TTY, so warnings should still be colored while the table must be clean).
if supports_color 1; then
    _UI_C_RED=$'\033[0;31m';    _UI_C_GREEN=$'\033[0;32m'
    _UI_C_YELLOW=$'\033[0;33m'; _UI_C_CYAN=$'\033[0;36m'
    _UI_C_BOLD=$'\033[1m';      _UI_C_DIM=$'\033[2m'
    _UI_C_RESET=$'\033[0m'
else
    _UI_C_RED=""; _UI_C_GREEN=""; _UI_C_YELLOW=""; _UI_C_CYAN=""
    _UI_C_BOLD=""; _UI_C_DIM=""; _UI_C_RESET=""
fi

if supports_color 2; then
    _UI_E_RED=$'\033[0;31m'; _UI_E_YELLOW=$'\033[0;33m'
    _UI_E_DIM=$'\033[2m';    _UI_E_RESET=$'\033[0m'
else
    _UI_E_RED=""; _UI_E_YELLOW=""; _UI_E_DIM=""; _UI_E_RESET=""
fi

ui_error() {
    printf '%s❌ %s%s\n' "$_UI_E_RED" "$*" "$_UI_E_RESET" >&2
}

ui_warn() {
    printf '%s⚠️ %s%s\n' "$_UI_E_YELLOW" "$*" "$_UI_E_RESET" >&2
}

ui_ok() {
    printf '%s✅ %s%s\n' "$_UI_C_GREEN" "$*" "$_UI_C_RESET"
}

ui_info() {
    printf '%s\n' "$*"
}

# Announces work that is about to take a noticeable moment (a network round
# trip, a GPG decrypt that may pop a pinentry dialog, a package install), so
# the terminal never just sits there looking hung.
ui_step() {
    printf '%s⏳ %s%s\n' "$_UI_C_DIM" "$*" "$_UI_C_RESET"
}

# A continuation line under an error/warning: what to actually do about it.
# Indented to align under the glyph, dimmed so the primary line leads.
ui_hint() {
    printf '%s   %s%s\n' "$_UI_E_DIM" "$*" "$_UI_E_RESET" >&2
}

# Deliberately walking away (Esc at a picker, answering "no" at a prompt) is
# not an error, so it doesn't get the alarm glyph or red. Callers still
# return non-zero afterwards so `server rm && deploy` correctly stops.
ui_cancel() {
    printf '%s%s%s\n' "$_UI_C_DIM" "${*:-Cancelled.}" "$_UI_C_RESET"
}

ui_title() {
    printf '%s%s%s\n' "$_UI_C_BOLD" "$*" "$_UI_C_RESET"
}

# Dimmed helper text under a prompt or title (key legends, defaults, notes).
ui_muted() {
    printf '%s%s%s\n' "$_UI_C_DIM" "$*" "$_UI_C_RESET"
}

ui_blank() {
    printf '\n'
}

# y/N confirmation for anything destructive. Defaults to NO: a bare Enter,
# EOF (piped/closed stdin), or anything that isn't y/yes declines, so a
# non-interactive invocation can never accidentally agree to delete things.
ui_confirm() {
    local prompt="$1" reply
    printf '%s%s [y/N] %s' "$_UI_C_BOLD" "$prompt" "$_UI_C_RESET"
    read -r reply || reply=""
    [[ "$reply" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# --- pickers -----------------------------------------------------------
#
# One picker, two shapes, chosen by how much there is to look at.
#
# A single flat list of "group/name" is the right thing for a small
# inventory: one keystroke, fuzzy search across everything, nothing to
# navigate. It stops working as the list grows. 20 groups of 20 hosts is
# 400 rows — still searchable if you already know the name you want, but no
# longer *browsable*, and the group structure that organises them is
# invisible in a flat list.
#
# So once there is more than one group, the picker leads with the groups,
# each showing its host count and previewing its members, and drills into
# one. Two rows keep the flat view one keystroke away:
#
#   "*"  at the top of the group list  → the flat all-hosts view
#   ".." at the top of a group         → back to the group list
#
# Navigation lives in the list rather than in a keybinding, matching the
# remote file browser in download.sh — see the note there: a bound key that
# quietly aborts the picker reads as a crash, a visible row doesn't.
#
# SERVERCTX_PICKER=flat|groups forces one shape regardless of size.
#
# Prints the chosen "group/name" on stdout; returns non-zero (having already
# reported why) if there's nothing to pick or the user cancelled.
pick_host() {
    local prompt="${1:-Select a server}"
    local hosts tmpdir mode group_count selected group name

    require_hosts || return 1
    hosts="$(host_list)"
    group_count="$(host_group_list | wc -l | tr -d ' ')"

    case "${SERVERCTX_PICKER:-auto}" in
        flat)   mode="flat" ;;
        groups) mode="groups" ;;
        # auto: the group step only earns its keystroke once there is more
        # than one group to choose between. A fresh install where everything
        # landed in "default" shouldn't have to walk past a one-row menu.
        *)      if (( group_count > 1 )); then mode="groups"; else mode="flat"; fi ;;
    esac

    tmpdir="$(mktemp -d)" || { ui_error "Failed to create a temp directory."; return 1; }
    _pick_build_previews "$tmpdir" || { rm -rf "$tmpdir"; return 1; }

    selected=""
    while true; do
        if [[ "$mode" == "flat" ]]; then
            selected="$(_pick_from_flat "$prompt" "$tmpdir" "$hosts")"
            break
        fi

        # Esc at the top level has nowhere further up to go, so it cancels.
        group="$(_pick_from_groups "$prompt" "$tmpdir")" || break

        if [[ "$group" == "*" ]]; then
            mode="flat"
            continue
        fi

        name="$(_pick_from_group "$prompt" "$tmpdir" "$group")" || break
        # ".." is the back row, not a host: validate_token forbids a name
        # starting with '.', so it can never collide with a real one.
        [[ "$name" == ".." ]] && continue

        selected="$group/$name"
        break
    done

    rm -rf "$tmpdir"

    if [[ -z "$selected" ]]; then
        ui_cancel "Cancelled."
        return 1
    fi
    printf '%s\n' "$selected"
}

# Precomputes every preview pane into a file under $tmpdir.
#
# fzf runs --preview in a separate shell that has none of these functions,
# and re-invoking $0 would behave differently for bin/server vs the bundled
# dist/server vs a sourced test run — so the text is written out ahead of
# time and the preview command is a bare `cat`.
#
# Laid out so both list shapes read the same files:
#   <tmpdir>/hosts/<group>/<name>   flat list passes {} == "group/name",
#                                   in-group list passes {} == "name"
#   <tmpdir>/groups/<group>         group list passes {1} == "group"
#
# Deliberately one awk pass plus pure-bash formatting. The previous version
# called host_get_field (an awk over the whole config) four times per host
# and cred_exists once more: at 400 hosts that was 2000 processes and a ~15s
# stall before fzf appeared. Credentials become marker files for the same
# reason — `[[ -f ]]` costs nothing, and bash 3.2 has no associative array
# to hold them in (the same constraint list.sh works around).
_pick_build_previews() {
    local tmpdir="$1"
    local line key alias group name hostname user port identity auth
    local total=0

    mkdir -p "$tmpdir/hosts" "$tmpdir/groups" "$tmpdir/creds" || {
        ui_error "Failed to prepare the picker's temp directory."
        return 1
    }

    if [[ -f "$CRED_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            key="${line%%=*}"
            # Skip blank and malformed lines: "$key" == "$line" means there
            # was no '=' at all, so there is no credential key here.
            [[ -n "$key" && "$key" != "$line" && "$key" == */* ]] || continue
            # Guarded rather than unconditional: mkdir is the only process
            # this loop would otherwise spawn, once per credential.
            [[ -d "$tmpdir/creds/${key%%/*}" ]] || mkdir -p "$tmpdir/creds/${key%%/*}"
            : > "$tmpdir/creds/$key"
        done < "$CRED_FILE"
    fi

    while IFS=$'\t' read -r alias hostname user port identity; do
        [[ -n "$alias" && "$alias" == */* ]] || continue
        group="${alias%%/*}"
        name="${alias#*/}"
        [[ -d "$tmpdir/hosts/$group" ]] || mkdir -p "$tmpdir/hosts/$group"

        if [[ -f "$tmpdir/creds/$alias" ]]; then
            auth="🔒 password"
        # keyfile_path's layout, inlined: calling it here would put a command
        # substitution back in the per-host path this function exists to keep
        # free of them. "the bulk preview builder agrees with the single-host
        # one" in picker_guardrails.bats fails if the two ever diverge.
        elif [[ -f "$HOME/.ssh/keys/$group/$name" ]]; then
            auth="🔑 ssh key"
        else
            auth="— none saved"
        fi

        _pick_render_preview "$alias" "$hostname" "$user" "$port" "$identity" "$auth" \
            > "$tmpdir/hosts/$alias"

        # One row per host in its group's preview, so the group list can show
        # what's inside a group before you commit to opening it.
        printf '  %s\n' "$name" >> "$tmpdir/groups/$group.members"
        total=$((total + 1))
    done < <(awk '
        function flush() { if (host != "") print host "\t" hostname "\t" user "\t" port "\t" identity }
        $1=="Host" { flush(); host=$2; hostname=""; user=""; port=""; identity=""; next }
        host != "" && $1=="HostName"     { hostname=$2 }
        host != "" && $1=="User"         { user=$2 }
        host != "" && $1=="Port"         { port=$2 }
        host != "" && $1=="IdentityFile" { identity=$2 }
        END { flush() }
    ' "$SSH_CONFIG_FILE" 2>/dev/null)

    _pick_build_group_list "$tmpdir" "$total"
}

# The group list rows, plus one preview per group. Split out from the host
# pass above only because it needs the final host total.
_pick_build_group_list() {
    local tmpdir="$1" total="$2"
    local group count width=6

    for group in $(host_group_list); do
        (( ${#group} > width )) && width=${#group}
    done

    # "*" can't collide with a real group — validate_token requires a group
    # to start with a letter or digit. fzf shell-quotes {1} when it
    # substitutes it into --preview, so the literal '*' filename written
    # below is passed to `cat` as a name, never expanded as a glob.
    printf '%-*s  %s\n' "$width" "*" "all $total host(s)" > "$tmpdir/groups.list"
    {
        printf 'All hosts\n\n'
        printf '  %s host(s) across every group.\n\n' "$total"
        printf '  Most recently connected first.\n'
    } > "$tmpdir/groups/*"

    # Groups stay alphabetical even though hosts are recency-ordered: the
    # group list is short and permanent enough to build muscle memory
    # against, and reshuffling it under the cursor costs more than it saves.
    for group in $(host_group_list); do
        count=0
        [[ -f "$tmpdir/groups/$group.members" ]] &&
            count="$(wc -l < "$tmpdir/groups/$group.members" | tr -d ' ')"
        printf '%-*s  %s\n' "$width" "$group" "$count host(s)" >> "$tmpdir/groups.list"
        {
            printf '%s\n\n' "$group"
            sort "$tmpdir/groups/$group.members" 2>/dev/null
        } > "$tmpdir/groups/$group"
        rm -f "$tmpdir/groups/$group.members"
    done
}

# Flat list of every "group/name".
#
# Ordered by last connection rather than alphabetically: the handful of
# servers you actually use land under the cursor instead of whichever ones
# happen to sort first.
_pick_from_flat() {
    local prompt="$1" tmpdir="$2" hosts="$3"
    local opts=()
    while IFS= read -r o; do opts+=("$o"); done < <(fzf_base_opts)

    order_hosts_by_recency "$hosts" | fzf "${opts[@]}" \
        --prompt="$prompt > " \
        --header='enter select · esc cancel' \
        --preview="cat '$tmpdir/hosts/'{}" \
        --preview-window=right:50%
}

# Group list. Rows are "<group>  <n> host(s)", so field 1 is the group —
# validate_token forbids whitespace in a group name, which is what makes
# that split safe. Returns non-zero when the user cancels.
_pick_from_groups() {
    local prompt="$1" tmpdir="$2" selected
    local opts=()
    while IFS= read -r o; do opts+=("$o"); done < <(fzf_base_opts)

    selected="$(fzf "${opts[@]}" \
        --prompt="$prompt > " \
        --header='enter open group · * all hosts · esc cancel' \
        --preview="cat '$tmpdir/groups/'{1}" \
        --preview-window=right:50% < "$tmpdir/groups.list")"

    [[ -n "$selected" ]] || return 1
    printf '%s\n' "${selected%%[[:space:]]*}"
}

# The hosts inside one group, listed by bare name — inside "prod" every row
# would otherwise repeat the "prod/" prefix that the prompt already shows.
# Recency-ordered like the flat list, with the back row pinned on top.
# Prints ".." if the user chose to go back; non-zero if they cancelled.
_pick_from_group() {
    local prompt="$1" tmpdir="$2" group="$3" selected
    local opts=()
    while IFS= read -r o; do opts+=("$o"); done < <(fzf_base_opts)

    # `cat` on the ".." row would resolve to a directory and fail, so the
    # back row gets its own preview text instead of an error in the pane.
    selected="$(_pick_group_rows "$group" | fzf "${opts[@]}" \
        --prompt="$prompt > $group/" \
        --header='enter select · .. back to groups · esc cancel' \
        --preview="cat '$tmpdir/hosts/$group/'{} 2>/dev/null || printf '  ⟵ back to the group list\n'" \
        --preview-window=right:50%)"

    [[ -n "$selected" ]] || return 1
    printf '%s\n' "$selected"
}

# The rows for one group: ".." pinned first, then the group's hosts as bare
# names in recency order.
#
# order_hosts_by_recency works in full "group/name" aliases (that's what the
# ledger stores), so names are qualified going in and stripped coming back
# out. Both directions use parameter expansion rather than `sed s|^$group/||`
# — a group name can legally contain '.', which in a sed pattern is a
# wildcard, and building patterns out of user-supplied names is the exact
# class of bug the header of sshconfig.sh exists to prevent. The strip is by
# byte offset, so no pattern is involved at all.
_pick_group_rows() {
    local group="$1" name alias aliases=""

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        aliases="$aliases$group/$name"$'\n'
    done < <(host_names_in_group "$group")

    printf '..\n'
    while IFS= read -r alias; do
        [[ -n "$alias" ]] || continue
        printf '%s\n' "${alias:${#group}+1}"
    done < <(order_hosts_by_recency "${aliases%$'\n'}")
}

# Renders one host's preview pane from already-resolved fields.
_pick_render_preview() {
    local alias="$1" hostname="$2" user="$3" port="$4" identity="$5" auth="$6"

    printf '%s\n\n' "$alias"
    printf '  HostName  %s\n' "${hostname:-—}"
    printf '  User      %s\n' "${user:-—}"
    printf '  Port      %s\n' "${port:-22}"
    printf '  Auth      %s\n' "$auth"
    [[ -n "$identity" ]] && printf '  Key file  %s\n' "$identity"
    return 0
}

# One host's preview read straight from the config. _pick_build_previews
# does the same job in bulk without the per-field awk calls; this stays for
# callers (and tests) that want a single host's pane on its own.
#
# Deliberately reads only the ssh config and local key files — no ping — so
# the picker appears instantly rather than stalling on a network round trip
# per host. Live reachability is what `server ls` is for.
_pick_host_preview() {
    local alias="$1" group="$2" name="$3"
    local hostname user port identity auth

    hostname="$(host_get_field "$alias" "HostName")"
    user="$(host_get_field "$alias" "User")"
    port="$(host_get_field "$alias" "Port")"
    identity="$(host_get_field "$alias" "IdentityFile")"

    if cred_exists "$alias"; then
        auth="🔒 password"
    elif [[ -f "$(keyfile_path "$group" "$name")" ]]; then
        auth="🔑 ssh key"
    else
        auth="— none saved"
    fi

    _pick_render_preview "$alias" "$hostname" "$user" "$port" "$identity" "$auth"
}

# Group-level picker, for the one command that genuinely operates on a whole
# group (editgroup) rather than a single host.
pick_group() {
    local prompt="${1:-Select a group}"
    local groups selected

    require_hosts || return 1
    groups="$(host_group_list)"

    local opts=()
    while IFS= read -r o; do opts+=("$o"); done < <(fzf_base_opts)

    selected="$(printf '%s\n' "$groups" | fzf "${opts[@]}" \
        --prompt="$prompt > " \
        --header='enter select · esc cancel')"

    if [[ -z "$selected" ]]; then
        ui_cancel "Cancelled."
        return 1
    fi
    printf '%s\n' "$selected"
}
