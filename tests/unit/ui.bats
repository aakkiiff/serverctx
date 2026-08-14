#!/usr/bin/env bats
# The output layer: stream routing, color gating, and the confirm helper.
# These encode the conventions that used to drift across ~90 ad-hoc echoes.

load '../helpers/test_helper'

setup() {
    setup_isolated_env
}

teardown() {
    teardown_short_home
}

@test "errors and warnings go to stderr; success, steps and info go to stdout" {
    local out err
    out="$( { ui_error "E"; ui_warn "W"; ui_hint "H"; ui_ok "O"; ui_step "S"; ui_info "I"; } 2>/dev/null )"
    err="$( { ui_error "E"; ui_warn "W"; ui_hint "H"; ui_ok "O"; ui_step "S"; ui_info "I"; } 2>&1 1>/dev/null )"

    [[ "$out" == *"O"* && "$out" == *"S"* && "$out" == *"I"* ]]
    [[ "$out" != *"E"* && "$out" != *"W"* ]]

    [[ "$err" == *"E"* && "$err" == *"W"* && "$err" == *"H"* ]]
    [[ "$err" != *"O"* && "$err" != *"S"* ]]
}

@test "no ANSI escape sequences are emitted when the stream isn't a terminal" {
    local combined
    combined="$( { ui_error "E"; ui_warn "W"; ui_ok "O"; ui_step "S"; ui_title "T"; ui_muted "M"; } 2>&1 | cat -v )"
    [[ "$combined" != *'^['* ]]
}

@test "supports_color honours NO_COLOR and TERM=dumb" {
    # Not a TTY under bats either way, so the point here is that the opt-outs
    # short-circuit before the TTY check rather than depending on it.
    NO_COLOR=1 run supports_color 1
    [ "$status" -ne 0 ]
    TERM=dumb run supports_color 1
    [ "$status" -ne 0 ]
}

@test "ui_confirm accepts only y/yes and defaults to no on blank input" {
    printf 'y\n'   | ui_confirm "Q?" >/dev/null
    printf 'Y\n'   | ui_confirm "Q?" >/dev/null
    printf 'yes\n' | ui_confirm "Q?" >/dev/null

    ! printf '\n'      | ui_confirm "Q?" >/dev/null
    ! printf 'n\n'     | ui_confirm "Q?" >/dev/null
    ! printf 'maybe\n' | ui_confirm "Q?" >/dev/null
}

@test "ui_confirm declines on EOF, so a non-interactive run can never agree to something destructive" {
    ! ui_confirm "Q?" </dev/null >/dev/null
}

@test "regression: a variable immediately followed by '…' still interpolates (bash 3.2 multibyte parsing)" {
    # On macOS's stock bash 3.2 in a UTF-8 locale, "$VAR…" is parsed as the
    # name VAR plus the ellipsis's leading continuation byte — an unset
    # variable — so the value silently vanishes. Ubuntu's bash 5 is fine,
    # which makes it a mac-only failure. Every call site braces the variable.
    local host="10.0.0.5"
    local rendered
    rendered="$(ui_step "Connecting to ${host}…")"
    [[ "$rendered" == *"10.0.0.5"* ]]
}

@test "no lib/ source uses the unbraced \$VAR… form that breaks on bash 3.2" {
    run grep -rnP '\$[A-Za-z_][A-Za-z0-9_]*…' "$ROOT_DIR/lib/"
    [ "$status" -ne 0 ]
}

@test "fzf_base_opts emits only flags that pre-0.21 fzf accepts (Ubuntu 20.04 ships 0.20)" {
    local opts
    opts="$(fzf_base_opts)"
    # The newer spellings are fatal ("unknown option") on older fzf.
    [[ "$opts" != *"--layout="* ]]
    [[ "$opts" != *"--border="* ]]
    [[ "$opts" == *"--reverse"* ]]
    [[ "$opts" == *"--border"* ]]
}

@test "no fzf call site in lib/ uses a post-0.20 flag spelling" {
    # Strips comments first — os.sh's own explanation of *why* these
    # spellings are avoided naturally mentions them.
    run bash -c "grep -rhv '^[[:space:]]*#' '$ROOT_DIR'/lib/*.sh '$ROOT_DIR'/lib/commands/*.sh \
        | grep -- '--layout=reverse\|--border=rounded\|--border=sharp\|--walker\|--tmux'"
    [ "$status" -ne 0 ]
}

@test "ensure_private_dir creates a directory as 700 regardless of the umask" {
    local d="$BATS_TEST_TMPDIR/newdir"
    ( umask 022; ensure_private_dir "$d" )
    [ "$(stat -f '%Lp' "$d" 2>/dev/null || stat -c '%a' "$d")" = "700" ]
}

@test "ensure_private_dir tightens a directory that already exists too loosely" {
    local d="$BATS_TEST_TMPDIR/loose"
    mkdir -p "$d"
    chmod 755 "$d"
    ensure_private_dir "$d"
    [ "$(stat -f '%Lp' "$d" 2>/dev/null || stat -c '%a' "$d")" = "700" ]
}

@test "no sensitive directory is created with a bare mkdir (which inherits the umask)" {
    # gpg warns about a 755 ~/.gnupg and ssh refuses a world-readable key,
    # so every such mkdir must go through ensure_private_dir.
    run grep -rn 'mkdir -p "\$HOME' "$ROOT_DIR/lib/"
    [ "$status" -ne 0 ]
}
