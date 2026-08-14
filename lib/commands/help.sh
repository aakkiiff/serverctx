cmd_help() {
    ui_blank
    ui_title "serverctx — SSH server manager"
    ui_muted "Manage, connect to, and transfer files with your SSH servers."
    ui_blank

    printf '%sUSAGE%s\n' "$_UI_C_BOLD" "$_UI_C_RESET"
    printf '  server [command]\n'
    printf '  server                     Pick a server and connect (same as %sssh%s)\n' "$_UI_C_CYAN" "$_UI_C_RESET"
    ui_blank

    printf '%sSERVERS%s\n' "$_UI_C_BOLD" "$_UI_C_RESET"
    _help_row "add"        "ad"                         "Add a new server"
    _help_row "ls"         "list"                       "List servers with status, password and key info"
    _help_row ""           "  --json"                   "Machine-readable output"
    _help_row ""           "  --no-ping"                "Skip the reachability check (faster)"
    _help_row "edit"       "-e"                         "Edit an existing server"
    _help_row "rm"         "remove, del, delete"        "Remove a server"
    _help_row "editgroup"  "-eg"                        "Rename a group of servers"
    ui_blank

    printf '%sCONNECT%s\n' "$_UI_C_BOLD" "$_UI_C_RESET"
    _help_row "ssh"        ""                           "Pick a server and connect"
    _help_row "pswd"       "password"                   "Show a server's saved password"
    _help_row "remember"   "-r"                         "Set up passwordless login (ssh-copy-id)"
    ui_blank

    printf '%sFILES%s\n' "$_UI_C_BOLD" "$_UI_C_RESET"
    _help_row "download"   "-d"                         "Browse a server and download a file/folder"
    _help_row "upload"     "-u"                         "Upload a local file/folder to a server"
    ui_blank

    printf '%sSETUP%s\n' "$_UI_C_BOLD" "$_UI_C_RESET"
    _help_row "init"       "initialize, in, -i"         "Install dependencies and set up GPG"
    _help_row "backup"     "export"                     "Back up config, passwords and keys"
    _help_row "restore"    "import"                     "Restore from a backup"
    _help_row "--help"     "help, -h"                   "Show this message"
    ui_blank

    printf '%sEXAMPLES%s\n' "$_UI_C_BOLD" "$_UI_C_RESET"
    ui_muted "  server              # pick a server and connect"
    ui_muted "  server add          # add your first server"
    ui_muted "  server ls           # see everything at a glance"
    ui_muted "  server download     # grab a file off a server"
    ui_blank
    ui_muted "Servers are addressed as group/name (e.g. prod/db01) and live in"
    ui_muted "~/.ssh/config, so plain 'ssh prod/db01' works too."
    ui_blank
}

# One command row: name, its aliases, and what it does. Aliases were almost
# entirely undocumented before — only 4 of the 13 were listed anywhere.
_help_row() {
    local name="$1" aliases="$2" desc="$3"
    printf '  %s%-11s%s %-22s %s\n' \
        "$_UI_C_CYAN" "$name" "$_UI_C_RESET" "$aliases" "$desc"
}
