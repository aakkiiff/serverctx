
# 📦 `serverctx` — Simple SSH Server Manager

<p align="center">
  <img src="./assets/Demo.gif" alt="Demo" />
</p>
<hr>

`server` is a lightweight Bash utility to easily manage and connect to your SSH server entries. It helps you:

- ➕ Add new SSH hosts
- 🗑 Remove existing hosts interactively
- ✏️ Edit existing hosts with ease
- 📋 List all SSH hosts with quick online/offline ping status
- 🔑 Quickly connect to any configured SSH host 
- 🆘 Get helpful usage instructions

---

## ⚠️ Prerequisites

- Bash shell (Linux, macOS, WSL, etc.)
## 🚀 Installation
1.  **Clone or download the script**
```
git clone https://github.com/aakkiiff/serverctx.git
cd serverctx
```
2.  **Make it executable and move to your PATH**
```
chmod +x server
sudo mv server /usr/local/bin/
```
Now you can run `server` from anywhere!
## ⚙️ Setup & Initialization
Simply run the initialization script:
```
server init
```
## 📚 Usage
```
server init, -i            # Initialize the server manager (install dependencies)
server                     # Interactively select and connect to an SSH server
server ssh                 # Interactively select and connect to an SSH server
server add                 # Add a new SSH server entry
server rm                  # Remove an existing SSH server entry
server edit                # Edit an existing SSH server entry
server ls                  # List all SSH servers with ping status
server pswd                # Get the password for a selected server
server --help, -h          # Show this help message
```

## 🧪 Examples
### Add a new server
`server add`
### List servers with status
`server ls`
### Connect to a server interactively
`server` 
or
`server ssh`
### Remove a server
`server rm`
### Edit a server
`server edit`
## 🧹 Uninstall
`sudo rm /usr/local/bin/server`

