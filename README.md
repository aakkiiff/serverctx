# 📦 serverctx

**Manage and connect to your SSH servers from one menu.** Fuzzy-search your
hosts, connect without typing passwords, and move files — all on top of your
regular `~/.ssh/config`.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Ubuntu%2FDebian-lightgrey)
![Shell](https://img.shields.io/badge/shell-Bash%203.2%2B-4EAA25?logo=gnubash&logoColor=white)

<p align="center">
  <img src="./assets/Demo.gif" alt="serverctx demo" />
</p>

## Install

Needs macOS or Ubuntu/Debian. Everything else is installed for you.

```sh
git clone https://github.com/aakkiiff/serverctx.git
cd serverctx
./install.sh
server init
```

## Use it

```sh
server add     # add a server
server ls      # see all your servers
server         # pick one and connect
```

Servers are named `group/name` (like `prod/db01`), which is also their alias in
`~/.ssh/config` — so plain `ssh prod/db01` works too. The picker puts the servers
you connect to most recently at the top.

With one group you get a single flat list. Once you have more, the picker opens
on your groups instead — pick `*` for the flat list of everything, or `..` to go
back up. Set `SERVERCTX_PICKER=flat` or `=groups` to always get one or the other.

## Commands

| Command | Aliases | What it does |
|---|---|---|
| `server` | | Pick a server and connect |
| `server add` | `ad` | Add a server |
| `server ls` | `list` | List servers with status, password and key info |
| `server ls --json` | | Same, as JSON — pipe it into `jq` |
| `server ls --no-ping` | | Same, but skip the reachability check (instant) |
| `server edit` | `-e` | Edit a server |
| `server rm` | `remove`, `del`, `delete` | Remove a server |
| `server editgroup` | `-eg` | Rename a group |
| `server ssh` | | Pick a server and connect |
| `server pswd` | `password` | Show a server's saved password |
| `server remember` | `-r` | Set up passwordless login |
| `server download` | `-d` | Browse a server and download a file/folder |
| `server upload` | `-u` | Upload a file/folder to a server |
| `server init` | `initialize`, `in`, `-i` | Install dependencies and set up GPG |
| `server backup` | `export` | Back up config, passwords and keys |
| `server restore` | `import` | Restore from a backup |
| `server --help` | `help`, `-h` | Show help |

## Security

Passwords are encrypted with your own GPG key and never stored in plaintext.
Config and key files are created readable only by you.

⚠️ **`server backup` includes your GPG private key.** Anyone with that folder
and your passphrase can read every saved password — keep it somewhere safe and
delete the local copy when you're done.

## Uninstall

```sh
sudo rm /usr/local/bin/server
```

## Development

```sh
./bin/server ls                      # run from source, no build needed
bats tests/unit tests/integration    # run the tests (brew/apt install bats-core)
./build.sh                           # rebuild dist/server after changing lib/
```

Tests never touch your real `~/.ssh` or `~/.gnupg`.

## License

[Apache 2.0](LICENSE)
