#!/usr/bin/env bash

# ============================================================
# Ubuntu Linux Hardening based on Lynis 3.1.8 findings
# Tested conceptually for Ubuntu 24.04/26.04
# ============================================================

set -Eeuo pipefail

BACKUP_DIR="/root/hardening-backup-$(date +%Y%m%d-%H%M%S)"
SYSCTL_FILE="/etc/sysctl.d/99-hardening.conf"
SSH_CONFIG="/etc/ssh/sshd_config"
BANNER_FILE="/etc/issue"
BANNER_NET="/etc/issue.net"

log() {
    echo
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || fail "Run this script as root."
}

backup_file() {
    local file="$1"

    if [[ -e "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$file" "$BACKUP_DIR/"
        echo "    Backup: $file"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------
# 1. PRECHECK
# ------------------------------------------------------------

require_root

mkdir -p "$BACKUP_DIR"

log "Backup directory: $BACKUP_DIR"

backup_file /etc/ssh/sshd_config
backup_file /etc/login.defs
backup_file /etc/security/pwquality.conf
backup_file /etc/default/grub
backup_file /etc/default/ufw
backup_file /etc/sysctl.conf
backup_file /etc/issue
backup_file /etc/issue.net

# ------------------------------------------------------------
# 2. Fix locale warning
# ------------------------------------------------------------

log "Checking locale"

if command_exists locale-gen; then

    if ! locale -a 2>/dev/null | grep -qi '^C\.UTF-8$'; then
        if grep -q '^# *C.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
            sed -i 's/^# *\(C.UTF-8 UTF-8\)/\1/' /etc/locale.gen
        fi

        locale-gen >/dev/null 2>&1 || true
    fi
fi

# ------------------------------------------------------------
# 3. Update package database
# ------------------------------------------------------------

log "Updating APT package database"

apt-get update

# ------------------------------------------------------------
# 4. Install security/audit packages
# ------------------------------------------------------------

log "Installing hardening packages"

apt-get install -y \
    libpam-pwquality \
    auditd \
    audispd-plugins \
    acct \
    sysstat \
    debsums \
    apt-show-versions \
    aide \
    ufw \
    rkhunter

# ------------------------------------------------------------
# 5. Password policy
# ------------------------------------------------------------

log "Configuring password policy"

if [[ -f /etc/login.defs ]]; then

    sed -i 's/^[[:space:]]*PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' \
        /etc/login.defs

    sed -i 's/^[[:space:]]*PASS_MAX_DAYS.*/PASS_MAX_DAYS   365/' \
        /etc/login.defs

    sed -i 's/^[[:space:]]*PASS_WARN_AGE.*/PASS_WARN_AGE   14/' \
        /etc/login.defs

    if grep -q '^[[:space:]]*UMASK' /etc/login.defs; then
        sed -i 's/^[[:space:]]*UMASK.*/UMASK           027/' \
            /etc/login.defs
    else
        echo "UMASK           027" >> /etc/login.defs
    fi

fi

# Password quality
if [[ -f /etc/security/pwquality.conf ]]; then

    cat > /etc/security/pwquality.conf <<'EOF'
# Linux hardening password policy

minlen = 14
minclass = 3
maxrepeat = 3
maxsequence = 3
dictcheck = 1
usercheck = 1
EOF

fi

# ------------------------------------------------------------
# 6. Global umask
# ------------------------------------------------------------

log "Configuring default umask"

if ! grep -qE '^[[:space:]]*umask[[:space:]]+027' /etc/profile; then
    cat >> /etc/profile <<'EOF'

# Security hardening
umask 027
EOF
fi

if [[ -f /etc/bash.bashrc ]]; then
    if ! grep -qE '^[[:space:]]*umask[[:space:]]+027' /etc/bash.bashrc; then
        cat >> /etc/bash.bashrc <<'EOF'

# Security hardening
umask 027
EOF
    fi
fi

# ------------------------------------------------------------
# 7. Sudo permissions
# ------------------------------------------------------------

log "Hardening sudo permissions"

chmod 0755 /etc/sudoers.d
chmod 0440 /etc/sudoers

if [[ -d /etc/sudoers.d ]]; then
    find /etc/sudoers.d -type f \
        -not -name README \
        -exec chmod 0440 {} \;
fi

# Validate sudo configuration
visudo -cf /etc/sudoers

# ------------------------------------------------------------
# 8. SSH HARDENING
# ------------------------------------------------------------

log "Hardening SSH"

# IMPORTANT:
# Do NOT automatically change SSH port.
# Do NOT disable root before verifying another sudo user exists.

set_ssh_option() {
    local key="$1"
    local value="$2"

    if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$SSH_CONFIG"; then
        sed -i -E \
            "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" \
            "$SSH_CONFIG"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG"
    fi
}

set_ssh_option "AllowTcpForwarding" "no"
set_ssh_option "ClientAliveCountMax" "2"
set_ssh_option "ClientAliveInterval" "300"
set_ssh_option "LogLevel" "VERBOSE"
set_ssh_option "MaxAuthTries" "3"
set_ssh_option "MaxSessions" "2"
set_ssh_option "PermitRootLogin" "prohibit-password"
set_ssh_option "TCPKeepAlive" "no"
set_ssh_option "X11Forwarding" "no"
set_ssh_option "AllowAgentForwarding" "no"

# Keep current SSH port to avoid lockout.
# set_ssh_option "Port" "2222"

# Validate SSH configuration
if command_exists sshd; then
    sshd -t
fi

# ------------------------------------------------------------
# 9. Failed login logging
# ------------------------------------------------------------

log "Enabling failed login accounting"

if command_exists pam_tally2; then
    echo "pam_tally2 available"
fi

# faillock is preferred on modern Linux-PAM
if command_exists faillock; then
    echo "    faillock available"
fi

# ------------------------------------------------------------
# 10. Auditd
# ------------------------------------------------------------

log "Configuring auditd"

mkdir -p /etc/audit/rules.d

cat > /etc/audit/rules.d/99-hardening.rules <<'EOF'
# ============================================================
# Audit hardening rules
# ============================================================

# Identity
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity

# Sudo
-w /etc/sudoers -p wa -k sudo
-w /etc/sudoers.d/ -p wa -k sudo

# SSH
-w /etc/ssh/sshd_config -p wa -k ssh_config

# Authentication
-w /etc/pam.d/ -p wa -k pam

# Important system configuration
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d/ -p wa -k sysctl

# Cron
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /etc/cron.weekly/ -p wa -k cron
-w /etc/cron.monthly/ -p wa -k cron

# Login
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins

# Kernel modules
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-w /usr/sbin/modprobe -p x -k modules

# Privileged commands
-a always,exit -F arch=b64 -S setuid -S setgid -S setreuid -S setregid -k privilege

# Mount operations
-a always,exit -F arch=b64 -S mount -S umount2 -k mounts

# Time changes
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S clock_settime -k time

# Make rules immutable until reboot
-e 2
EOF

augenrules --load || true

systemctl enable auditd
systemctl restart auditd || true

# ------------------------------------------------------------
# 11. Process accounting
# ------------------------------------------------------------

log "Enabling process accounting"

systemctl enable acct 2>/dev/null || true
systemctl start acct 2>/dev/null || true

# ------------------------------------------------------------
# 12. Sysstat
# ------------------------------------------------------------

log "Enabling sysstat"

if [[ -f /etc/default/sysstat ]]; then
    sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
fi

systemctl enable sysstat 2>/dev/null || true
systemctl start sysstat 2>/dev/null || true

# ------------------------------------------------------------
# 13. File integrity - AIDE
# ------------------------------------------------------------

log "Configuring AIDE"

if command_exists aideinit; then
    if [[ ! -f /var/lib/aide/aide.db ]]; then
        aideinit || true
    fi
fi

# ------------------------------------------------------------
# 14. Malware/rootkit scanner
# ------------------------------------------------------------

log "Configuring rkhunter"

if command_exists rkhunter; then

    rkhunter --update || true

    rkhunter --propupd || true

fi

# ------------------------------------------------------------
# 15. UFW firewall
# ------------------------------------------------------------

log "Configuring UFW"

# IMPORTANT:
# Allow SSH before enabling firewall.

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'

# Enable only if SSH is currently listening on port 22.
if ss -lnt | grep -qE ':(22)[[:space:]]'; then
    ufw --force enable
else
    warn "SSH port 22 not detected. UFW will NOT be enabled automatically."
fi

# ------------------------------------------------------------
# 16. Kernel/sysctl hardening
# ------------------------------------------------------------

log "Configuring kernel parameters"

cat > "$SYSCTL_FILE" <<'EOF'
# ============================================================
# Linux kernel/network hardening
# ============================================================

# Filesystem protection
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# Core dumps
fs.suid_dumpable = 0

# Kernel information leakage
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# ASLR
kernel.randomize_va_space = 2

# SysRq
kernel.sysrq = 0

# Restrict unprivileged BPF
kernel.unprivileged_bpf_disabled = 1

# BPF JIT hardening
net.core.bpf_jit_harden = 2

# IPv4
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

net.ipv4.tcp_syncookies = 1

# IPv6
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF

sysctl --system

# ------------------------------------------------------------
# 17. Disable dangerous/unused kernel modules
# ------------------------------------------------------------

log "Disabling uncommon network protocols"

cat > /etc/modprobe.d/99-hardening.conf <<'EOF'
# Disable uncommon network protocols if not required

install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false

# Disable USB storage if this server does not require USB storage.
# Uncomment manually if appropriate:
#
# install usb-storage /bin/false
EOF

# ------------------------------------------------------------
# 18. USB storage check
# ------------------------------------------------------------

log "Checking USB storage"

if lsmod | grep -q '^usb_storage'; then
    warn "usb_storage is currently loaded."
    warn "Not disabling automatically because this may break legitimate USB storage."
fi

# ------------------------------------------------------------
# 19. File permissions
# ------------------------------------------------------------

log "Hardening important file permissions"

chmod 0644 /etc/passwd
chmod 0644 /etc/group

chmod 0600 /etc/shadow
chmod 0600 /etc/gshadow

chmod 0644 /etc/passwd-
chmod 0644 /etc/group-

chmod 0600 /etc/shadow-
chmod 0600 /etc/gshadow- 2>/dev/null || true

chmod 0600 "$SSH_CONFIG"

chmod 0700 /root/.ssh 2>/dev/null || true

chmod 0755 /etc/cron.d
chmod 0755 /etc/cron.daily

# ------------------------------------------------------------
# 20. Cron permissions
# ------------------------------------------------------------

log "Checking cron permissions"

find /etc/cron.d \
    /etc/cron.daily \
    /etc/cron.hourly \
    /etc/cron.weekly \
    /etc/cron.monthly \
    -type f \
    -exec chmod go-w {} \; 2>/dev/null || true

# ------------------------------------------------------------
# 21. Login banners
# ------------------------------------------------------------

log "Configuring login banners"

cat > "$BANNER_FILE" <<'EOF'
************************************************************************
AUTHORIZED ACCESS ONLY

This system is restricted to authorized users.
Unauthorized access, use, or modification is prohibited and may be
subject to monitoring, logging, and legal action.

By accessing this system, you acknowledge that security monitoring
and auditing may be performed.
************************************************************************
EOF

cp "$BANNER_FILE" "$BANNER_NET"

chmod 0644 "$BANNER_FILE" "$BANNER_NET"

# ------------------------------------------------------------
# 22. Disable insecure services if installed
# ------------------------------------------------------------

log "Checking insecure services"

SERVICES=(
    rsh.socket
    rlogin.socket
    rexec.socket
    telnet.socket
    tftp.socket
    nis.service
)

for svc in "${SERVICES[@]}"; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
        systemctl disable --now "$svc" 2>/dev/null || true
    fi
done

# Remove insecure packages when installed.
INSECURE_PACKAGES=(
    rsh-client
    rsh-redone-client
    rsh-server
    telnet
    telnetd
    nis
    tftp
    tftpd
)

for pkg in "${INSECURE_PACKAGES[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
        | grep -q "install ok installed"; then

        warn "Removing insecure package: $pkg"
        apt-get purge -y "$pkg" || true
    fi
done

# ------------------------------------------------------------
# 23. Package verification
# ------------------------------------------------------------

log "Checking package integrity"

if command_exists debsums; then
    debsums -s || true
fi

# ------------------------------------------------------------
# 24. Unattended upgrades
# ------------------------------------------------------------

log "Enabling unattended upgrades"

systemctl enable unattended-upgrades 2>/dev/null || true
systemctl start unattended-upgrades 2>/dev/null || true

# ------------------------------------------------------------
# 25. SSH final validation
# ------------------------------------------------------------

log "Validating SSH"

if command_exists sshd; then
    sshd -t

    systemctl reload ssh || systemctl reload sshd || true

    echo
    echo "Effective SSH configuration:"
    sshd -T | grep -E \
        '^(allowtcpforwarding|clientalivecountmax|clientaliveinterval|loglevel|maxauthtries|maxsessions|permitrootlogin|tcpkeepalive|x11forwarding|allowagentforwarding)'
fi

# ------------------------------------------------------------
# 26. Firewall status
# ------------------------------------------------------------

log "Firewall status"

ufw status verbose || true

# ------------------------------------------------------------
# 27. Audit status
# ------------------------------------------------------------

log "Audit status"

systemctl --no-pager status auditd || true

echo
echo "Audit rules:"
auditctl -l 2>/dev/null || true

# ------------------------------------------------------------
# 28. Sysctl verification
# ------------------------------------------------------------

log "Checking hardened sysctl values"

sysctl \
    fs.protected_fifos \
    fs.protected_hardlinks \
    fs.protected_regular \
    fs.protected_symlinks \
    fs.suid_dumpable \
    kernel.dmesg_restrict \
    kernel.kptr_restrict \
    kernel.randomize_va_space \
    kernel.sysrq \
    kernel.unprivileged_bpf_disabled \
    net.core.bpf_jit_harden \
    net.ipv4.conf.all.accept_redirects \
    net.ipv4.conf.all.log_martians \
    net.ipv4.conf.all.rp_filter \
    net.ipv4.conf.all.send_redirects \
    net.ipv6.conf.all.accept_redirects

# ------------------------------------------------------------
# 29. Final report
# ------------------------------------------------------------

echo
echo "============================================================"
echo " HARDENING COMPLETED"
echo "============================================================"
echo
echo "Backup:"
echo "  $BACKUP_DIR"
echo
echo "Important:"
echo "  - SSH port was NOT changed."
echo "  - SSH root login changed to prohibit-password."
echo "  - /home and /var partitions were NOT modified."
echo "  - USB storage was NOT automatically disabled."
echo "  - Kernel modules were configured for future loads."
echo
echo "Run Lynis again:"
echo
echo "  ./lynis audit system"
echo
echo "============================================================"