# Reading/writing ~/.ssh/config "Host group/name" blocks and the credentials
# file, plus input validation.
#
# Every lookup here uses literal comparison (awk -v ... $2==h, or index())
# instead of interpolating user input into a grep/sed *pattern*. The original
# script built regexes like `grep "^Host $name\$"` and `sed -i "s/^$old-/…"`
# directly from user-entered names — a name containing regex metacharacters
# (., *, [, ^, $ ...) could silently mismatch or corrupt unrelated entries.
# validate_token() closes this off structurally by restricting the charset,
# and the helpers below never build a pattern from a variable regardless.

validate_token() {
    local value="$1" label="$2"
    if [[ -z "$value" ]]; then
        ui_error "$label cannot be empty."
        return 1
    fi
    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        ui_error "$label may only contain letters, numbers, '.', '_' and '-'."
        ui_hint "It also can't start with '-'. Example: web-01"
        return 1
    fi
    return 0
}

# A TCP port is 1-65535; the old check accepted any run of digits, so 0 and
# 99999 sailed through and only failed later at connect time.
validate_port() {
    local value="$1"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
        ui_error "Port must be a number between 1 and 65535."
        return 1
    fi
    return 0
}

# A hostname/IP can't contain whitespace — the ssh config format is
# whitespace-delimited, so a value with a space in it silently writes a
# corrupt "HostName a b" line that ssh then misreads.
validate_hostname() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_error "HostName cannot be empty."
        return 1
    fi
    if [[ "$value" =~ [[:space:]] ]]; then
        ui_error "HostName cannot contain spaces."
        return 1
    fi
    return 0
}

# Shared "is there anything to work with" guard for commands that pick a
# host via fzf — gives a specific, actionable message instead of a bare
# "No hosts found" that doesn't distinguish "never initialized" (run init)
# from "initialized but empty" (run add).
require_hosts() {
    if [[ ! -f "$SSH_CONFIG_FILE" ]]; then
        ui_error "serverctx isn't initialized yet."
        ui_hint "Run 'server init' first."
        return 1
    fi
    if [[ -z "$(host_list)" ]]; then
        ui_error "No hosts found."
        ui_hint "Add your first one with 'server add'."
        return 1
    fi
    return 0
}

# Resolves everything needed to open a connection to a host: its network
# details plus whichever credential is on file. Was previously copy-pasted
# verbatim into both download.sh and upload.sh.
#
# Results come back in RH_* variables rather than stdout, since there are six
# of them and one is a decrypted password that must not be echoed anywhere:
#   RH_HOSTNAME RH_USER RH_PORT RH_AUTH ("pass"|"key") RH_PASSWORD RH_KEYPATH
resolve_host_auth() {
    local full_host="$1"
    local group="${full_host%%/*}" name="${full_host#*/}"
    local value

    RH_HOSTNAME="$(host_get_field "$full_host" "HostName")"
    RH_USER="$(host_get_field "$full_host" "User")"
    RH_PORT="$(host_get_field "$full_host" "Port")"
    RH_PORT="${RH_PORT:-22}"
    RH_AUTH=""
    RH_PASSWORD=""
    RH_KEYPATH=""

    if cred_exists "$full_host"; then
        value="$(cred_get "$full_host")"
        ui_step "Decrypting saved password…"
        RH_PASSWORD="$(decrypt_password "$value")" || return 1
        if [[ -z "$RH_PASSWORD" ]]; then
            ui_error "Failed to decrypt the password for '$full_host'."
            return 1
        fi
        RH_AUTH="pass"
        return 0
    fi

    RH_KEYPATH="$(keyfile_path "$group" "$name")"
    if [[ -f "$RH_KEYPATH" ]]; then
        RH_AUTH="key"
        return 0
    fi

    ui_error "No password or SSH key saved for '$full_host'."
    ui_hint "Add one with 'server edit'."
    return 1
}

# --- recently-used hosts ------------------------------------------------
#
# A small "<epoch>\t<group/name>" ledger, newest-first, used to float the
# servers you actually connect to to the top of the picker. Only the
# commands that genuinely open a connection record into it — picking a host
# in order to *delete* it shouldn't promote it.

# Records a connection to $1. Best-effort throughout: this is a convenience
# ranking, so a failure here must never take down the command that called it.
touch_host_recent() {
    local alias="$1" tmp now
    [[ -n "$alias" ]] || return 0
    [[ -n "${RECENT_FILE:-}" ]] || return 0

    now="$(date +%s 2>/dev/null)" || return 0
    tmp="$(mktemp)" || return 0

    # Drop any earlier entry for this host, then cap the file so it can't
    # grow without bound on a long-lived machine.
    if [[ -f "$RECENT_FILE" ]]; then
        awk -F'\t' -v a="$alias" '$2 != a' "$RECENT_FILE" > "$tmp" 2>/dev/null
    fi
    printf '%s\t%s\n' "$now" "$alias" >> "$tmp"
    sort -rn "$tmp" 2>/dev/null | head -n 50 > "$RECENT_FILE" 2>/dev/null
    rm -f "$tmp"
    chmod 600 "$RECENT_FILE" 2>/dev/null
    return 0
}

# Reorders a newline-separated host list: most recently connected first,
# then everything else alphabetically. Hosts in the ledger that no longer
# exist are skipped, so a removed server can't linger at the top.
order_hosts_by_recency() {
    local hosts="$1"
    local seen ts alias

    if [[ -z "${RECENT_FILE:-}" || ! -s "${RECENT_FILE:-}" ]]; then
        printf '%s\n' "$hosts" | sort
        return 0
    fi

    seen="$(mktemp)" || { printf '%s\n' "$hosts" | sort; return 0; }

    while IFS=$'\t' read -r ts alias; do
        [[ -n "$alias" ]] || continue
        printf '%s\n' "$hosts" | grep -qxF -- "$alias" || continue
        grep -qxF -- "$alias" "$seen" 2>/dev/null && continue
        printf '%s\n' "$alias"
        printf '%s\n' "$alias" >> "$seen"
    done < <(sort -rn "$RECENT_FILE" 2>/dev/null)

    printf '%s\n' "$hosts" | sort | while IFS= read -r alias; do
        [[ -n "$alias" ]] || continue
        grep -qxF -- "$alias" "$seen" 2>/dev/null || printf '%s\n' "$alias"
    done

    rm -f "$seen"
    return 0
}

# `[[ -f "$path" ]]` does NOT expand a leading ~ when $path came from a
# variable — tilde expansion only happens on bare words at parse time, not
# on the contents of a variable. A path typed as "~/.ssh/id_rsa" at a `read`
# prompt would otherwise look for a literal file named "~" in the current
# directory and confusingly report "not found".
expand_tilde() {
    local path="$1"
    case "$path" in
        "~") echo "$HOME" ;;
        "~/"*) echo "$HOME/${path#\~/}" ;;
        *) echo "$path" ;;
    esac
}

# mktemp wrapper with a friendly error instead of silently proceeding with
# an empty path — `awk ... > "$tmp"` with tmp="" fails with a confusing
# "ambiguous redirect" rather than saying what actually went wrong.
safe_mktemp() {
    local t
    t="$(mktemp)" || { ui_error "Failed to create a temp file."; ui_hint "Check disk space and permissions on /tmp."; return 1; }
    echo "$t"
}

host_exists() {
    local host="$1"
    awk -v h="$host" '$1=="Host" && $2==h { f=1 } END { exit !f }' "$SSH_CONFIG_FILE" 2>/dev/null
}

host_list() {
    awk '$1=="Host" { print $2 }' "$SSH_CONFIG_FILE" 2>/dev/null
}

host_group_list() {
    host_list | awk -F/ '{ print $1 }' | sort -u
}

host_names_in_group() {
    local group="$1"
    awk -v g="$group/" '$1=="Host" && index($2,g)==1 { print substr($2, length(g)+1) }' "$SSH_CONFIG_FILE" 2>/dev/null
}

host_get_field() {
    local host="$1" field="$2"
    awk -v h="$host" -v f="$field" '
        $1=="Host" && $2==h { in_block=1; next }
        in_block && $1=="Host" { exit }
        in_block && $1==f { print $2 }
    ' "$SSH_CONFIG_FILE" 2>/dev/null
}

host_remove_block() {
    local host="$1" tmp
    tmp="$(safe_mktemp)" || return 1
    awk -v h="$host" '
        $1=="Host" && $2==h { skip=1; next }
        $1=="Host" { skip=0 }
        !skip { print }
    ' "$SSH_CONFIG_FILE" > "$tmp" && mv "$tmp" "$SSH_CONFIG_FILE"
}

host_append_block() {
    local host="$1" hostname="$2" user="$3" port="$4" identity_file="${5:-}"
    {
        echo ""
        echo "Host $host"
        echo "    HostName $hostname"
        echo "    User $user"
        echo "    Port $port"
        # Written so plain `ssh`/`scp`/`rsync`/anything else that reads this
        # config picks up the saved key too, not just `server ssh` (which
        # already passes -i explicitly as a fallback for entries written
        # before this field existed).
        [[ -n "$identity_file" ]] && echo "    IdentityFile $identity_file"
    } >> "$SSH_CONFIG_FILE"
    # Without this, the function's return status is that of the [[ ... ]]
    # above — which is 1 (false) on every call that omits identity_file,
    # breaking every caller that checks/relies on this function's exit code.
    return 0
}

host_rename_group_prefix() {
    local old_group="$1" new_group="$2" tmp
    tmp="$(safe_mktemp)" || return 1
    # IdentityFile values are full paths under ~/.ssh/keys/<group>/<name>
    # (see keyfile_path) — keep that path's group segment in sync here too,
    # otherwise a renamed host's config block points at a key file that
    # keyfile_rename_group_prefix just moved out from under it.
    awk -v og="$old_group/" -v ng="$new_group/" \
        -v okp="$HOME/.ssh/keys/$old_group/" -v nkp="$HOME/.ssh/keys/$new_group/" '
        $1=="Host" && index($2,og)==1 { $2 = ng substr($2, length(og)+1) }
        $1=="IdentityFile" && index($2,okp)==1 { print "    IdentityFile " nkp substr($2, length(okp)+1); next }
        { print }
    ' "$SSH_CONFIG_FILE" > "$tmp" && mv "$tmp" "$SSH_CONFIG_FILE"
}

# --- credentials file: keyed by "group/name" (unambiguous, since '/' can't
# appear inside group or name — validate_token forbids it) ---

cred_key() {
    echo "$1/$2"
}

cred_exists() {
    local key="$1"
    awk -v k="$key=" 'index($0,k)==1 { f=1 } END { exit !f }' "$CRED_FILE" 2>/dev/null
}

cred_get() {
    local key="$1"
    awk -v k="$key=" 'index($0,k)==1 { print substr($0, length(k)+1) }' "$CRED_FILE" 2>/dev/null
}

cred_delete() {
    local key="$1" tmp
    tmp="$(safe_mktemp)" || return 1
    awk -v k="$key=" 'index($0,k)!=1' "$CRED_FILE" > "$tmp" && mv "$tmp" "$CRED_FILE"
}

cred_set() {
    local key="$1" value="$2"
    cred_delete "$key"
    echo "$key=$value" >> "$CRED_FILE"
}

cred_rename_group_prefix() {
    local old_group="$1" new_group="$2" tmp
    tmp="$(safe_mktemp)" || return 1
    awk -v og="$old_group/" -v ng="$new_group/" '
        index($0,og)==1 { print ng substr($0, length(og)+1); next }
        { print }
    ' "$CRED_FILE" > "$tmp" && mv "$tmp" "$CRED_FILE"
}

# --- ssh key files: stored at ~/.ssh/keys/<group>/<name>, mirroring the
# config's own group/name structure instead of flattening with '-' (the
# flattened scheme was ambiguous: group="a" name="b-c" and group="a-b"
# name="c" both produced the same file "a-b-c") ---

keyfile_path() {
    echo "$HOME/.ssh/keys/$1/$2"
}

keyfile_rename_group_prefix() {
    local old_group="$1" new_group="$2"
    local old_dir="$HOME/.ssh/keys/$old_group" new_dir="$HOME/.ssh/keys/$new_group"
    [[ -d "$old_dir" ]] || return 0
    ensure_private_dir "$(dirname "$new_dir")"
    if [[ -d "$new_dir" ]]; then
        # merge: move individual files rather than clobber an existing dir
        find "$old_dir" -type f -exec mv {} "$new_dir/" \;
        rmdir "$old_dir" 2>/dev/null
    else
        mv "$old_dir" "$new_dir"
    fi
}
