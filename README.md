# proxmoxNAS

`bootstrap.sh` — post-build configuration for an **Alpine Linux LXC** that
acts as a Samba NAS on a Proxmox host. It configures dual-NIC networking,
serves DHCP on an isolated internal bridge, restricts inbound traffic on
the public side via an IP allow-list, installs and enables Samba, and
hardens the OS by creating two local accounts and disabling root.

## What it configures

| Area | Result |
|---|---|
| `eth0` | DHCP client (the "outside" / management bridge) |
| `eth1` | Static `10.10.10.1/24` (the "inside" / VM-only bridge) |
| DHCP server | `dnsmasq` (DHCP only, DNS disabled) bound to **eth1**, range `10.10.10.10`–`10.10.10.50` |
| Firewall | INPUT default-deny on `eth0`; allow `lo`, allow all on `eth1`, allow source IPs/CIDRs listed in `/etc/whitelist.txt` (initially `192.168.26.0/24`) |
| Samba | `samba` + `samba-common-tools` installed and enabled |
| SSH | root login disabled, password auth on, only `smbadmin` permitted |
| Accounts | `smbadmin` (wheel/sudo, shell, SSH) and `smbuser` (`/sbin/nologin`, samba only) |
| Root | password locked, shell set to `/sbin/nologin` |

The firewall script is installed at `/etc/local.d/firewall.start` and
runs at boot via the openrc `local` service.

## Prerequisites — Proxmox host

Before creating the container, make sure the two Linux bridges exist on
the host:

1. **`vmbr0`** — normal bridge with an uplink (your LAN).
2. **`vmbr1`** — local VM-only bridge, **no uplink** (no physical port,
   no other VLAN). This is the isolated 10.10.10.0/24 segment that
   `dnsmasq` will serve.

In the Proxmox UI: *Datacenter → \<node\> → System → Network → Create →
Linux Bridge*. Leave **Bridge ports** empty for `vmbr1`.

## Create the LXC container

Use the Alpine template (download via *pveam* or the UI). Either via the
web UI or with `pct` on the host (replace `<vmid>` and template name as
appropriate):

```sh
pct create <vmid> local:vztmpl/alpine-3.20-default_*.tar.xz \
    --hostname proxmoxnas \
    --cores 2 --memory 1024 --swap 512 \
    --rootfs local-lvm:8 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --net1 name=eth1,bridge=vmbr1,ip=manual \
    --features nesting=1 \
    --unprivileged 1 \
    --start 1
```

Both NICs must be present and named `eth0` and `eth1` — the script
refuses to run otherwise and tells you to *"create eth0 as normal bridge
and eth1 as local VM only Linux Bridge"*.

## Run the bootstrap

From the Proxmox host:

```sh
pct enter <vmid>
```

Inside the container (as root):

```sh
apk add curl
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Elevennails/proxmoxNAS/main/bootstrap.sh)"
```

(`sh -c "$(...)"` runs the downloaded script with the terminal still
attached as stdin, so the password prompts work — unlike `curl ... | sh`.
Alpine's `/bin/sh` is BusyBox `ash` and is always present, so no extra
shell needs to be installed.)

<details>
<summary>Alternative: clone and run</summary>

```sh
apk add git
git clone https://github.com/Elevennails/proxmoxNAS.git
cd proxmoxNAS
chmod +x bootstrap.sh
./bootstrap.sh
```
</details>

The script will prompt **twice** for each of two passwords:

1. `smbadmin` — the sudoer / SSH user (also a samba user).
2. `smbuser` — the samba-only user (no shell login).

Everything else is non-interactive.

## Verify after the run

```sh
ip -4 addr show eth0       # should show a DHCP lease
ip -4 addr show eth1       # should show 10.10.10.1/24
rc-status                  # dnsmasq, sshd, samba, local should be 'started'
iptables -L INPUT -n -v    # allow lo, allow eth1, allow whitelisted srcs on eth0, drop eth0
cat /etc/whitelist.txt
```

Plug a test client into the `vmbr1` segment (or boot another LXC on it)
and confirm it gets a `10.10.10.10`–`10.10.10.50` lease.

## Day-2: editing the allow-list

`/etc/whitelist.txt` is read on every boot by `/etc/local.d/firewall.start`.
Add or remove IPs / CIDRs (one per line, `#` for comments) and either
reboot or re-run the script:

```sh
sh /etc/local.d/firewall.start
```

## Recovery

The script disables root login (locks the password and sets the shell to
`/sbin/nologin`). If you lock yourself out of `smbadmin`, you can still
get in from the Proxmox host with `pct enter <vmid>` — that bypasses
login entirely.
