#!/bin/bash

# Config
GPG_RECIPIENT="$USER"
CRED_FILE="encrypted_passwords.txt"

# Function to encrypt text
encrypt_password() {
    local plain="$1"
    echo -n "$plain" | gpg --yes -r "$GPG_RECIPIENT" -e --armor | base64 | tr -d '\n'
}

# Ask for inputs dynamically
read -rp "Enter name: " name
read -rsp "Enter password: " password
echo

# Encrypt password
encrypted_password=$(encrypt_password "$password")

# Append to file
echo "$name=$encrypted_password" >> "$CRED_FILE"

echo "✅ Added: $name"
cat "$CRED_FILE"
