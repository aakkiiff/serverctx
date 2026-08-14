# OS detection and cross-platform (macOS/Ubuntu) shims.
# Every place the rest of the codebase would otherwise call an OS-specific
# tool directly (ping, pbcopy/xclip, apt/brew) goes through here. All
# in-place file edits elsewhere use awk+mktemp+mv rather than `sed -i`,
# which sidesteps both the GNU/BSD `sed -i` argument mismatch and the
# regex-injection risk of interpolating user input into a sed/grep pattern.

os_type() {
    case "$(uname -s)" in
        Darwin) echo "mac" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

OS_TYPE="$(os_type)"

# Checks that every given command exists on PATH; prints one friendly,
# actionable line per missing tool (instead of letting a raw "command not
# found" surface later, out of context, from deep inside some pipeline) and
# returns 1 if any are missing.
require_cmds() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        ui_error "Missing required tool(s): ${missing[*]}"
        ui_hint "Run 'server init' to install them."
        return 1
    fi
    return 0
}

# Creates a directory that must not be readable by other local users, and
# tightens it if it already exists with looser permissions.
#
# A bare `mkdir -p` inherits the umask — commonly 022, so 755 — which is
# wrong for anything holding key material. gpg warns loudly about it
# ("unsafe permissions on homedir") and ssh refuses to use a private key
# that other users can read, so the chmod is not optional.
ensure_private_dir() {
    local dir="$1"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || return 1
    return 0
}

# Runs a command with root privileges: bare if already root (common in
# containers), via sudo otherwise. Fails with a clear message rather than a
# raw "sudo: command not found" if neither applies.
run_privileged() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        ui_error "This step needs root privileges, but you're not root and sudo isn't available."
        ui_hint "Re-run as root, or install sudo, then try again."
        return 1
    fi
}

# Whether it's safe to emit ANSI color codes on the given stream (default:
# stdout, fd 1 — pass 2 to ask about stderr). Piping `server ls` to a file
# would otherwise embed raw escape sequences in the output.
#
# Also honours the two standard opt-outs: NO_COLOR (https://no-color.org,
# any non-empty value) and TERM=dumb, which terminals and CI systems set to
# say they can't render styling.
supports_color() {
    local fd="${1:-1}"
    [[ -z "${NO_COLOR:-}" ]] || return 1
    [[ "${TERM:-}" != "dumb" ]] || return 1
    [[ -t "$fd" ]]
}

# The flag set every fzf call site must build on.
#
# Unknown flags are FATAL to fzf ("unknown option"), and Ubuntu LTS ships
# far older fzf than Homebrew does (20.04 → 0.20, 22.04 → 0.29, 24.04 →
# 0.44; macOS/brew → 0.74+). So this deliberately uses the oldest accepted
# spelling of each flag — `--reverse` rather than `--layout=reverse` (0.21+)
# and bare `--border` rather than `--border=rounded` (0.24+) — which modern
# fzf still accepts. Keep it that way: a newer spelling here breaks the CLI
# outright on older distros rather than degrading.
fzf_base_opts() {
    printf '%s\n' --reverse --border --height=40% --cycle --info=inline
}

# ping's -W flag means different units on different platforms:
#   Linux (iputils)   -W <seconds>
#   macOS (BSD ping)  -W <milliseconds>
# ping_once returns 0 if the host answered within timeout_secs, 1 otherwise.
ping_once() {
    local hostname="$1" timeout_secs="${2:-1}"
    if [[ "$OS_TYPE" == "mac" ]]; then
        ping -c1 -W "$((timeout_secs * 1000))" "$hostname" &>/dev/null
    else
        ping -c1 -W "$timeout_secs" "$hostname" &>/dev/null
    fi
}

# TCP-connect fallback for hosts that answer SSH but block ICMP (common
# behind cloud security groups / hardened firewalls) — ping alone would
# wrongly report these as offline. Uses bash's /dev/tcp instead of `nc`:
# nc's listen/timeout flags differ between BSD (macOS) and GNU (Linux)
# builds, the same portability trap ping's -W has above. A bare /dev/tcp
# connect has no timeout of its own though — a filtered host can otherwise
# block for the OS's full default connect timeout — so a background timer
# kills the attempt after timeout_secs.
tcp_port_open() {
    local hostname="$1" port="$2" timeout_secs="${3:-1}"
    [[ -n "$port" ]] || return 1

    ( exec 3<>"/dev/tcp/$hostname/$port" ) 2>/dev/null &
    local attempt_pid=$!

    ( sleep "$timeout_secs"; kill "$attempt_pid" ) &>/dev/null &
    local timer_pid=$!

    local result=0
    wait "$attempt_pid" 2>/dev/null || result=1
    kill "$timer_pid" 2>/dev/null
    wait "$timer_pid" 2>/dev/null
    return "$result"
}

# A host counts as reachable if it answers ping OR has its configured SSH
# port open — see tcp_port_open above for why ping alone isn't enough.
host_reachable() {
    local hostname="$1" port="$2" timeout_secs="${3:-1}"
    ping_once "$hostname" "$timeout_secs" && return 0
    tcp_port_open "$hostname" "$port" "$timeout_secs"
}

# Clipboard: pbcopy on macOS, wl-copy under Wayland, xclip under X11.
clipboard_copy() {
    if [[ "$OS_TYPE" == "mac" ]]; then
        pbcopy
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy &>/dev/null; then
        wl-copy
    elif command -v xclip &>/dev/null; then
        xclip -selection clipboard
    else
        ui_warn "No clipboard tool found (pbcopy/wl-copy/xclip) — skipping the copy."
        cat >/dev/null
        return 1
    fi
}

clipboard_clear_after() {
    local delay_secs="${1:-30}"
    ( sleep "$delay_secs"; printf '' | clipboard_copy ) &>/dev/null &disown
}

# Best-effort dependency install. Ubuntu/Debian uses apt, macOS uses Homebrew.
# sshpass has no Homebrew core formula (removed over password-on-argv policy
# concerns); we fall back to a well-known community tap and warn either way,
# since passing plaintext passwords to sshpass is itself a residual risk
# (mitigated by using -f/process-substitution instead of -p, see remember.sh).
#
# "clipboard" is a virtual target rather than a real package name: which
# tool it means depends on the OS and, on Linux, the session type — this
# mirrors clipboard_copy()'s own runtime detection above, so init provisions
# whatever that function will actually reach for (pbcopy needs nothing on
# macOS; wl-clipboard under Wayland; xclip otherwise).
pkg_install() {
    local pkg="$1"

    if [[ "$pkg" == "clipboard" ]]; then
        if [[ "$OS_TYPE" == "mac" ]]; then
            return 0
        elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
            pkg="wl-clipboard"
        else
            pkg="xclip"
        fi
    fi

    case "$OS_TYPE" in
        mac)
            command -v brew &>/dev/null || { ui_error "Homebrew not found."; ui_hint "Install it from https://brew.sh first."; return 1; }
            local brew_formula="$pkg" brew_check="$pkg"
            case "$pkg" in
                sshpass) brew_formula="hudochenkov/sshpass/sshpass" ;;
                gnupg) brew_check="gpg" ;; # binary is `gpg`, not `gnupg`
            esac
            if [[ "$pkg" == "sshpass" ]] && ! command -v sshpass &>/dev/null; then
                ui_warn "sshpass has no Homebrew core formula — installing from the hudochenkov/sshpass tap."
            fi
            if ! command -v "$brew_check" &>/dev/null; then
                ui_step "Installing ${pkg}…"
                brew install "$brew_formula" || {
                    ui_error "Failed to install '$pkg' via Homebrew."
                    ui_hint "Run 'brew install $brew_formula' to see the full error, then re-run 'server init'."
                    return 1
                }
            fi
            ;;
        linux)
            if ! command -v apt &>/dev/null && ! command -v apt-get &>/dev/null; then
                ui_error "No 'apt'/'apt-get' found."
                ui_hint "Automatic install only supports Ubuntu/Debian. On other distros install these"
                ui_hint "manually: fzf, gnupg, sshpass, xclip (or wl-clipboard), openssh-client."
                return 1
            fi

            local check_bin="$pkg"
            case "$pkg" in
                gnupg) check_bin="gpg" ;;        # binary is `gpg`, not `gnupg`
                wl-clipboard) check_bin="wl-copy" ;; # binary is `wl-copy`, not `wl-clipboard`
            esac
            if ! command -v "$check_bin" &>/dev/null; then
                # Refresh the apt index at most once per process no matter how
                # many missing packages get installed this run — cmd_init
                # calls pkg_install once per dependency, and re-running `apt
                # update` for each one is redundant.
                if [[ -z "${_apt_updated:-}" ]]; then
                    ui_step "Refreshing package lists…"
                    run_privileged apt update -y && _apt_updated=1
                fi
                ui_step "Installing ${pkg}…"
                run_privileged apt install -y "$pkg" || {
                    ui_error "Failed to install '$pkg'."
                    ui_hint "Check your network connection and apt sources, then re-run 'server init'."
                    return 1
                }
            fi
            ;;
        *)
            ui_error "Unsupported OS: $(uname -s)."
            ui_hint "serverctx supports macOS and Ubuntu/Debian."
            return 1
            ;;
    esac
}
