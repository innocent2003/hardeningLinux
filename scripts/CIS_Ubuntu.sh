#!/bin/bash

# Kiem tra quyen root
if [[ $EUID -ne 0 ]]; then
  echo "? Vui long chay script voi quyen root."
  exit 1
fi

# Doi hostname (neu khong nhap gi thi dat mk-newhost)
read -p "Nhap hostname moi [mac dinh: mk-newhost]: " NEW_HOST
NEW_HOST=${NEW_HOST:-mk-newhost}
hostnamectl set-hostname "$NEW_HOST"
echo "? Da doi hostname thanh: $NEW_HOST"

# Cau hinh DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Sao luu & cau hinh rsyslog
TIME=$(date +%Y%m%d%H%M%S)
cp /etc/rsyslog.conf /etc/rsyslog.conf.$TIME.bak

cat >> /etc/rsyslog.conf << 'EOF'

# Log command
local2.info          /var/log/oscmd.log
EOF

cat >> ~/.bashrc << 'EOF'

# Log command
export PROMPT_COMMAND='history -a >(logger -p local2.info -t "$USER[$PWD] $SSH_CONNECTION")'
export GREP_OPTIONS='--color=auto'
EOF

source ~/.bashrc
systemctl restart rsyslog

# Disable IPv6
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p

# Cai chrony va cau hinh timezone
apt update && apt install -y chrony net-tools telnet traceroute curl
timedatectl set-timezone Asia/Ho_Chi_Minh

# Cau hinh chrony
CHRONY_CONF="/etc/chrony/chrony.conf"
cp "$CHRONY_CONF" "$CHRONY_CONF.bak"

cat > "$CHRONY_CONF" << EOF
server 10.30.60.11
keyfile /etc/chrony/chrony.keys
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
#leapsectz right/UTC
EOF

systemctl enable --now chrony
systemctl restart chrony

# Cau hinh chinh sach mat khau
cp /etc/login.defs /etc/login.defs_bk
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   7/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' /etc/login.defs

# Cau hinh SSH khong cho dang nhap root
cp /etc/ssh/sshd_config /etc/ssh/sshd_config_bk
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl reload ssh

# Cai auditd
apt install -y auditd audispd-plugins

cp /etc/audit/auditd.conf /etc/audit/auditd.conf_bk
sed -i 's/^max_log_file =.*/max_log_file = 50/' /etc/audit/auditd.conf
systemctl enable auditd --now

# Tu dong logout sau 15p khong hoat dong
echo "TMOUT=900" > /etc/profile.d/cis_tmout.sh
chmod +x /etc/profile.d/cis_tmout.sh

# Chan core dump va disable suid_dumpable
echo '* hard core 0' >> /etc/security/limits.conf
echo 'fs.suid_dumpable = 0' >> /etc/sysctl.conf
sysctl --system

echo "? Hoan tat cau hinh he thong."

