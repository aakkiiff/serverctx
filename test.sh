#!/bin/bash

# Config
GPG_RECIPIENT="$USER"
CRED_FILE="encrypted_passwords.txt"

# Inputs
name="server2"
password="your_password"

# Encrypt password
encrypted_password=$(
  echo -n "$password" | gpg --yes -r "$GPG_RECIPIENT" -e --armor | base64 | tr -d '\n'
)

# Append to file
echo "$name=$encrypted_password" >> "$CRED_FILE"

echo "✅ Added: $name"
cat "$CRED_FILE"
