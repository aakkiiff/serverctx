#!/bin/bash

CRED_FILE="encrypted_passwords.txt"

read -p "Enter server name: " name

# Extract encrypted value from file
encrypted_value=$(grep "^$name=" "$CRED_FILE" | cut -d'=' -f2)

# If not found
if [[ -z "$encrypted_value" ]]; then
    echo "❌ No entry found for '$name'"
    exit 1
fi

# Decode and decrypt
echo "$encrypted_value" | base64 --decode | gpg --quiet --decrypt
