#!/bin/sh
# bootstrap.sh — Alpine Linux LXC post-build configuration for proxmoxNAS.
# Configures dual-NIC networking, an internal DHCP server, an eth0
# whitelist firewall, Samba, SSH, and the smbadmin / smbuser accounts.

set -eu

#----------------------------------------------------------------------
# Pre-flight checks
#----------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: bootstrap.sh must be run as root." >&2
    exit 1
fi

for iface in eth0 eth1; do
    if [ ! -d "/sys/class/net/$iface" ]; then
        echo "ERROR: interface $iface not found." >&2
        echo "create eth0 as normal bridge and eth1 as local VM only Linux Bridge" >&2
        exit 1
    fi
done

#----------------------------------------------------------------------
# Prompt for account passwords (twice each, hidden input)
#----------------------------------------------------------------------

prompt_password() {
    user=$1
    while :; do
        printf "Password for %s: " "$user" >&2
        stty -echo
        read -r pw1
        stty echo
        printf "\n" >&2
        printf "Confirm password for %s: " "$user" >&2
        stty -echo
        read -r pw2
        stty echo
        printf "\n" >&2
        if [ -z "$pw1" ]; then
            echo "Password cannot be empty." >&2
            continue
        fi
        if [ "$pw1" != "$pw2" ]; then
            echo "Passwords do not match." >&2
            continue
        fi
        printf '%s' "$pw1"
        return 0
    done
}

SMBADMIN_PW=$(prompt_password smbadmin)
SMBUSER_PW=$(prompt_password smbuser)

#----------------------------------------------------------------------
# Packages
#----------------------------------------------------------------------

apk update
apk add samba samba-common-tools sudo iptables dhcp openssh shadow

#----------------------------------------------------------------------
# Network: eth0 = DHCP client, eth1 = static 10.10.10.1/24
#----------------------------------------------------------------------

cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto eth1
iface eth1 inet static
    address 10.10.10.1
    netmask 255.255.255.0
EOF

#----------------------------------------------------------------------
# ISC dhcpd — serves 10.10.10.10-10.10.10.50 on eth1 only
#----------------------------------------------------------------------

mkdir -p /etc/dhcp
cat > /etc/dhcp/dhcpd.conf <<'EOF'
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 10.10.10.0 netmask 255.255.255.0 {
    range 10.10.10.10 10.10.10.50;
    option routers 10.10.10.1;
    option subnet-mask 255.255.255.0;
    option broadcast-address 10.10.10.255;
}
EOF

# Bind dhcpd to eth1 only via /etc/conf.d/dhcpd
if [ -f /etc/conf.d/dhcpd ] && grep -q '^DHCPD_IFACE=' /etc/conf.d/dhcpd; then
    sed -i 's|^DHCPD_IFACE=.*|DHCPD_IFACE="eth1"|' /etc/conf.d/dhcpd
else
    echo 'DHCPD_IFACE="eth1"' >> /etc/conf.d/dhcpd
fi

rc-update add dhcpd default

#----------------------------------------------------------------------
# Firewall whitelist for eth0
#----------------------------------------------------------------------

if [ ! -f /etc/whitelist.txt ]; then
    cat > /etc/whitelist.txt <<'EOF'
# Hosts/networks allowed to reach services on eth0 (one entry per line).
192.168.26.0/24
EOF
fi

mkdir -p /etc/local.d
cat > /etc/local.d/firewall.start <<'EOF'
#!/bin/sh

ALLOWLIST=/etc/whitelist.txt

# Flush existing rules on eth0
iptables -F INPUT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow all traffic on internal interface
iptables -A INPUT -i eth1 -j ACCEPT

# Allow only listed IPs on eth0
while IFS= read -r ip; do
    # Skip empty lines and comments
    [ -z "$ip" ] && continue
    echo "$ip" | grep -q "^#" && continue
    iptables -A INPUT -i eth0 -s "$ip" -j ACCEPT
done < "$ALLOWLIST"

# Drop everything else on eth0
iptables -A INPUT -i eth0 -j DROP
EOF
chmod +x /etc/local.d/firewall.start

# /etc/local.d/*.start runs when the openrc 'local' service starts at boot.
rc-update add local default

#----------------------------------------------------------------------
# Local accounts
#   smbadmin — interactive shell, sudo (wheel), SSH-allowed
#   smbuser  — nologin shell (samba access only)
#----------------------------------------------------------------------

if ! id smbadmin >/dev/null 2>&1; then
    adduser -D -s /bin/ash -G wheel smbadmin
else
    adduser smbadmin wheel 2>/dev/null || true
fi
echo "smbadmin:${SMBADMIN_PW}" | chpasswd

if ! id smbuser >/dev/null 2>&1; then
    adduser -D -s /sbin/nologin smbuser
fi
echo "smbuser:${SMBUSER_PW}" | chpasswd

# Enable wheel group in sudoers
if [ -f /etc/sudoers ]; then
    sed -i 's|^#[[:space:]]*%wheel[[:space:]]\+ALL=(ALL)[[:space:]]\+ALL|%wheel ALL=(ALL) ALL|' /etc/sudoers
    sed -i 's|^#[[:space:]]*%wheel[[:space:]]\+ALL=(ALL:ALL)[[:space:]]\+ALL|%wheel ALL=(ALL:ALL) ALL|' /etc/sudoers
fi
grep -qE '^%wheel[[:space:]]+ALL=' /etc/sudoers || echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# Disable the root account: lock its password and switch its shell to nologin.
# Host-level entry (pct enter / lxc-attach) still works for rescue.
passwd -l root
usermod -s /sbin/nologin root 2>/dev/null || sed -i 's|^root:\([^:]*\):\([^:]*\):\([^:]*\):\([^:]*\):\([^:]*\):.*|root:\1:\2:\3:\4:\5:/sbin/nologin|' /etc/passwd

#----------------------------------------------------------------------
# SSH: root login disabled, password auth on, smbadmin only
#----------------------------------------------------------------------

SSHD_CONFIG=/etc/ssh/sshd_config

set_sshd() {
    key=$1
    value=$2
    sed -i -E "/^[#[:space:]]*${key}([[:space:]]|$)/d" "$SSHD_CONFIG"
    echo "${key} ${value}" >> "$SSHD_CONFIG"
}

set_sshd PermitRootLogin no
set_sshd PasswordAuthentication yes
set_sshd AllowUsers smbadmin

rc-update add sshd default

#----------------------------------------------------------------------
# Register samba users (uses the same passwords)
#----------------------------------------------------------------------

(printf '%s\n%s\n' "${SMBADMIN_PW}" "${SMBADMIN_PW}") | smbpasswd -a -s smbadmin
(printf '%s\n%s\n' "${SMBUSER_PW}"  "${SMBUSER_PW}")  | smbpasswd -a -s smbuser

rc-update add samba default

#----------------------------------------------------------------------
# Apply now (best-effort — some services may already be running)
#----------------------------------------------------------------------

rc-service networking restart || true
rc-service dhcpd       start   || true
rc-service local       start   || true
rc-service sshd        restart || true
rc-service samba       start   || true

unset SMBADMIN_PW SMBUSER_PW

cat <<EOF

Bootstrap complete.
  eth0    : DHCP client
  eth1    : 10.10.10.1/24 (dhcpd serving 10.10.10.10-10.10.10.50)
  Firewall: /etc/whitelist.txt (eth0 default-deny, eth1 allowed)
  Users   : smbadmin (wheel/sudo, SSH), smbuser (samba only, nologin)
  Root    : disabled (password locked, shell /sbin/nologin)
EOF
