#!/bin/bash
set -e

REPO="https://github.com/CISOfy/lynis.git"
DEST="/home/tuanlm/testlynis"

echo "[+] Checking git..."

if ! command -v git >/dev/null 2>&1; then
    echo "[-] Git is not installed."
    echo "[+] Installing git..."

    sudo apt update
    sudo apt install -y git
fi

echo "[+] Git version:"
git --version

echo "[+] Repository: $REPO"
echo "[+] Destination: $DEST"

if [ -d "$DEST/.git" ]; then
    echo "[+] Lynis already exists, updating..."

    git -C "$DEST" pull --ff-only
else
    echo "[+] Cloning Lynis..."

    # Xóa thư mục đích nếu tồn tại nhưng không phải Git repository
    if [ -e "$DEST" ]; then
        echo "[-] $DEST exists but is not a Git repository."
        exit 1
    fi

    git clone "$REPO" "$DEST"
fi

echo "[+] Setting executable permission..."
chmod +x "$DEST/lynis"

echo "[+] Lynis installed at: $DEST"

echo "[+] Test:"
"$DEST/lynis" --version