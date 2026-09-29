#!/bin/bash

set -e

REPO="https://github.com/CISOfy/lynis"
DEST="/home/tuanlm/testlynis"

echo "[+] Cloning Lynis..."

if [ -d "$DEST/.git" ]; then
    echo "[+] Lynis already exists, updating..."
    git -C "$DEST" pull --ff-only
else
    sudo git clone "$REPO" "$DEST"
fi

sudo chmod +x "$DEST/lynis"

echo "[+] Lynis installed at: $DEST"
echo "[+] Test:"
sudo "$DEST/lynis" --version