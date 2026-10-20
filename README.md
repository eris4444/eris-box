# Eris Box

[![tests](https://github.com/eris4444/eris-box/actions/workflows/tests.yml/badge.svg)](https://github.com/eris4444/eris-box/actions/workflows/tests.yml)

**Split one Linux server into small, isolated machines and give them to other people.**

Got a VPS with 1 CPU and 1 GB RAM? Give a friend or a customer a machine with
**0.2 CPU, 200 MB RAM, 1 GB swap and a 2 GB disk**, with root SSH access and their own ports
or their own IP address. They can't see your files, use more than their share, or
take over each other's addresses.

Every machine is an **unprivileged LXC container** (a full Ubuntu or Debian system with
systemd, apt and SSH). Limits are enforced by the Linux kernel (cgroup v2). There is
no daemon in the background, so a tiny server keeps its RAM for the machines.

```
               your server (one public IP + optional extra IPs)
 ┌──────────────────────────────────────────────────────────────────┐
 │  1.2.3.4:2201 ──► alice  (0.2 CPU · 200M RAM · 1G swap · 2G disk) │
 │  1.2.3.4:2202 ──► bob    (0.5 CPU · 300M RAM · 512M swap · 5G)    │
 │  5.6.7.8 (all ports) ──► bob  (dedicated IP, in and out)          │
 │  shop.example.com:80/443 ──► alice  (domain proxy)                │
 └──────────────────────────────────────────────────────────────────┘
```

## Install

On a fresh **Ubuntu 22.04 or 24.04** server, as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/eris-box/main/install.sh)
```

The installer sets everything up, offers to create a swap file and prepares the
default OS image. Then it opens the menu. Later, just type `erisbox`.

**Requirements:** Ubuntu 22.04 / 24.04 (amd64 or arm64), a **KVM / VMware / Hyper-V VPS or a
dedicated server** (not an OpenVZ/LXC "container VPS"), about 1 GB of free disk for the
first OS image plus the disks you give out.

## Create your first machine

From the menu choose **1) Create a machine**, or run:

```bash
erisbox create alice --cpu 0.2 --ram 200M --swap 1G --disk 2G
```

You get everything you need to send to the user:

```
=== alice ===  RUNNING
  OS         : Ubuntu 24.04
  Resources  : CPU 0.2 core | RAM 200M | swap 1G | disk 2G | max 512 processes
  SSH        : ssh root@1.2.3.4 -p 2201
  Password   : q8XbT2mRk0aLz7Vc
  Ports      : 1.2.3.4:20001-20010 (tcp+udp, same numbers inside)
```

Inside the machine, `free -h` and `df -h /` show the machine's own RAM, swap and disk,
not the whole server's.

## Features

| | |
|---|---|
| **Limits** | CPU (e.g. `0.2` = 20 % of a core), RAM, swap, disk size, max processes, optional disk speed (MB/s, IOPS) |
| **Change live** | CPU, RAM, swap and process limits change instantly. The disk grows online and shrinks when stopped. |
| **Shared IP** | Every machine gets an SSH port plus a block of ports (TCP+UDP) on the server's IP. You can add single ports, ranges or `8080:80` mappings. |
| **Dedicated IPs** | Up to **2 extra IPv4 per machine**, mapped 1:1 (all ports in, and the machine's outgoing IP). Detected and configured automatically. |
| **Domain proxy** | Many machines can host websites on ports 80/443 of the same IP: HTTP by `Host`, HTTPS passed through untouched by SNI (each machine keeps its own certificate). |
| **Selling** | Speed limit (Mbit/s), monthly traffic quota with automatic reset, expiry date. Over-quota machines are stopped or slowed, expired ones stopped, `renew` brings them back. |
| **Safety** | Unprivileged containers with a separate uid range per machine. Machines can't spoof IPs or MACs, can't see each other, and can't reach the host's services, private networks or the cloud metadata service. Outgoing SMTP (port 25) is blocked to protect your IP's reputation. |
| **Operations** | Backup / restore (also onto another Eris Box server), reinstall OS, root console, password and SSH-key reset, JSON output, self-repair every 5 minutes, works next to ufw and Docker. |
| **Guest OS** | Ubuntu 24.04, Ubuntu 22.04, Debian 12, Debian 13, built from the official mirrors with `debootstrap` and cached. |

## Dedicated IPs

1. Buy an extra IPv4 from your server provider and attach it to **this** server in the
   provider's panel.
2. Give it to a machine:

```bash
erisbox ip add alice 5.6.7.8
```

Eris Box finds where the IP arrived and sets it up:

- **already on a network card**: used as is;
- **on a new network card without an address**: the card is brought up with DHCP (netplan)
  and gets its own routing table, so replies leave through the right card;
- **a private address that the cloud maps to the public IP** ("floating IP"): detected by
  testing which public IP each address goes out as;
- **not configured at all** (a routed IP): added to the main card.

Then it checks that traffic really leaves as that IP. All ports of the IP go to the
machine, and the machine's outgoing traffic uses it. A second IP works the same way
(programs inside bind to the machine's second private address to send from it).
If the automatic detection guesses wrong, set it by hand:
`erisbox ip add alice 5.6.7.8 --iface ens4 --gw 5.6.7.1`.

## Websites on 80/443 (domain proxy)

```bash
erisbox domain enable                      # installs nginx, needs ports 80 and 443 free
erisbox domain add alice shop.example.com
erisbox domain add bob example.org --wildcard
```

Point the domain's DNS A record at the server's IP. The machine runs its own web server
and gets its own certificates (Let's Encrypt HTTP-01 works through the proxy). If the
server itself already uses 443 (for example for a VPN), move that program to another
port and send unknown names to it: `erisbox domain default-tls 127.0.0.1:8443`.

## Command line

Everything in the menu is also a command (add `-y` to skip questions):

```bash
erisbox list                      # all machines with live usage (--json for scripts)
erisbox info alice                # connection details to send to the user
erisbox set alice --ram 300M --cpu 0.5 --disk 4G
erisbox set alice --speed 20 --traffic 100 --expire 30   # Mbit/s, GB/month, days
erisbox renew alice 30            # +30 days (from the current expiry)
erisbox port add alice 25565      # also 30000-30010 or 8080:80, --proto tcp|udp|both
erisbox port ssh alice 2222
erisbox passwd alice              # new random root password
erisbox console alice             # root shell inside
erisbox exec alice -- apt-get update
erisbox backup alice              # -> /var/lib/erisbox/backups/
erisbox restore FILE [NEW_NAME]
erisbox reinstall alice --os debian-12
erisbox stop|start|restart alice
erisbox delete alice
erisbox status                    # server usage and what was given out
erisbox update                    # latest version from GitHub
erisbox help
```

## How it works

- **Machines**: LXC 5 (`lxc-utils`) without a daemon; `lxcfs` makes `/proc` show each
  machine's own limits.
- **Disk**: one ext4 image file per machine (`/var/lib/erisbox/disks/NAME.img`), mounted
  when the machine starts. The size is a hard limit and works on any host filesystem.
- **Limits**: `cpu.max`, `memory.max`, `memory.swap.max`, `pids.max`, `io.max` (cgroup v2).
  The machines' swap comes from the server's swap, so the installer offers a swap file.
- **Network**: private bridge `erisbr0` (10.88.0.0/16 or another free range), NAT and
  rules in the server's own nftables tables (`inet erisbox`, `ip erisbox_nat`,
  `bridge erisbox_br`). Your existing firewall is left alone. Speed limits use `tc`.
- **Boot**: `erisbox-net.service` restores the network, LXC autostarts the machines, and
  `erisbox-tick.timer` counts traffic, enforces quotas and expiry, and repairs missing rules.
- **Files**: settings in `/etc/erisbox`, data in `/var/lib/erisbox`.

Overselling is allowed (the sum of the machines' RAM may exceed the server's).
`erisbox status` shows how much you have given out.

## Notes

- Machines share the server's kernel: they can't load kernel modules or run their own
  kernel. Docker inside a machine is not supported. A TUN device can be enabled
  (`--tun on`) for VPN software.
- You are responsible for what runs on your IPs. Port 25 is blocked by default
  (`erisbox settings set BLOCK_SMTP 0` to allow it).
- If your provider has a cloud firewall, open the ports you forward there too.
- Every push is tested on real Ubuntu 22.04 and 24.04 machines (see `tests/`).

## Uninstall

```bash
erisbox uninstall           # keeps the machines' disks so you can reinstall later
erisbox uninstall --purge   # removes everything
```

---

## راهنمای سریع فارسی

**Eris Box** یک سرور لینوکس را به چند «ماشین» کوچک و جدا تقسیم می‌کند. مثلاً از یک سرور با
۱ هسته و ۱ گیگ رم، به یک نفر ۰.۲ CPU، ۲۰۰ مگ رم، ۱ گیگ سواپ و ۲ گیگ دیسک می‌دهی، با SSH و
دسترسی root مخصوص خودش.

**نصب** (Ubuntu 22.04 یا 24.04، با کاربر root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/eris-box/main/install.sh)
```

بعد از نصب منو باز می‌شود. دفعه‌های بعد فقط بنویس `erisbox`.

- **ساخت ماشین:** `erisbox create ali --cpu 0.2 --ram 200M --swap 1G --disk 2G`
- **IP اختصاصی:** اول IP را از شرکت سرورت بخر و به همین سرور وصل کن، بعد:
  `erisbox ip add ali 5.6.7.8` (حداکثر ۲ IP برای هر ماشین؛ همه‌ی پورت‌ها مال همان ماشین می‌شود)
- **پورت روی IP خود سرور:** هر ماشین یک پورت SSH و یک بازه پورت می‌گیرد. پورت بیشتر:
  `erisbox port add ali 25565`
- **سایت روی 80/443:** `erisbox domain enable` و بعد `erisbox domain add ali example.com`
- **فروش:** محدودیت سرعت، حجم ماهانه و تاریخ انقضا:
  `erisbox set ali --speed 20 --traffic 100 --expire 30`
- **پشتیبان:** `erisbox backup ali` و برگرداندن با `erisbox restore`

## License

MIT
