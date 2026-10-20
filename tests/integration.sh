#!/usr/bin/env bash
# Eris Box end-to-end test. Runs on a throw-away Ubuntu VM (GitHub Actions) as root:
#   sudo bash tests/integration.sh GUEST_OS_1 GUEST_OS_2
# Two network namespaces play "the internet":
#   cli  203.0.113.2 -> host 203.0.113.1        (customers / port forwards / main IP)
#   isp2 192.0.2.1   -> host ext1 192.0.2.10    (a second network card with its own IP)
cd "$(dirname "$0")/.." || exit 1
OS_A="${1:-ubuntu-24.04}"
OS_B="${2:-debian-12}"
EB=/usr/local/bin/erisbox
HOSTIP=203.0.113.1
PASS=0; FAIL=0; FAILED=()

pass() { echo "  PASS  $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); FAILED+=("$*"); }
check() { # description command...
  local d="$1"; shift
  if "$@" >/tmp/eb-check.out 2>&1; then pass "$d"; else fail "$d"; sed 's/^/          /' /tmp/eb-check.out | tail -n 25; fi
}
not() { ! "$@"; }
retry() { # seconds command...
  local n="$1" i; shift
  for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  "$@"
}
section() { echo; echo "=== $* ==="; }
conf() { grep "^$2=" "/etc/erisbox/guests/$1.conf" | cut -d"'" -f2; }
eq() { [ "$1" = "$2" ] || { echo "expected '$2', got '$1'"; return 1; }; }
between() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] || { echo "$1 is not between $2 and $3"; return 1; }; }
banner() { # ns ip port -> prints the first 7 bytes (SSH-2.0)
  ip netns exec "$1" timeout 6 python3 -c "import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),5); print(s.recv(7).decode())" "$2" "$3"
}
banner_from() { # ns src ip port
  ip netns exec "$1" timeout 6 python3 -c "import socket,sys; s=socket.create_connection((sys.argv[2],int(sys.argv[3])),5,(sys.argv[1],0)); print(s.recv(7).decode())" "$2" "$3" "$4"
}
is_ssh() { [ "$("$@" 2>/dev/null)" = "SSH-2.0" ]; }
cgv() { lxc-cgroup -n "$1" "$2"; }
running() { [ "$(lxc-info -n "$1" -sH 2>/dev/null)" = RUNNING ]; }
booted() { $EB exec "$1" -- sh -c 'systemctl is-system-running 2>/dev/null | grep -Eq "running|degraded"'; }
inside() { local n="$1"; shift; $EB exec "$n" -- "$@"; }
http_from_cli() { ip netns exec cli curl -fsS --max-time 8 "$@"; }
http_code_from_cli() { ip netns exec cli curl -s -o /dev/null --max-time 8 -w '%{http_code}' "$@"; }
guest_service() { # machine unit command...  -> a restarting systemd service inside the machine
  local m="$1" u="$2"; shift 2
  printf '[Service]\nExecStart=%s\nRestart=always\nRestartSec=1\nOOMPolicy=continue\n[Install]\nWantedBy=multi-user.target\n' "$*" \
    | $EB exec "$m" -- sh -c "cat > /etc/systemd/system/$u.service"
  $EB exec "$m" -- systemctl daemon-reload
  $EB exec "$m" -- systemctl enable --now "$u" >/dev/null 2>&1
}

diag() {
  echo; echo "=== diagnostics ==="
  set -x
  ip -br addr; ip rule; ip route show table all | grep -v '^local\|^broadcast' | head -n 60
  nft list ruleset | head -n 250
  iptables -S FORWARD 2>/dev/null | head -n 20
  for f in /var/lib/erisbox/logs/*; do echo "--- $f"; tail -n 40 "$f"; done
  for n in t1 t2 t3 t5; do lxc-info -n "$n" 2>/dev/null; done
  journalctl -u erisbox-net -u erisbox-tick -u lxc --no-pager | tail -n 60
  dmesg 2>/dev/null | grep -i 'apparmor="DENIED"' | tail -n 20
  cat /etc/erisbox/guests/*.conf 2>/dev/null
  set +x
}

section "host preparation"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq sshpass >/dev/null
for p in 80 443; do ss -Hltn "sport = :$p" | grep -q . && echo "note: port $p is busy on this runner"; done
ip netns add cli
ip link add cli-h type veth peer name cli-c
ip link set cli-c netns cli
ip addr add "$HOSTIP/24" dev cli-h; ip link set cli-h up
ip netns exec cli ip addr add 203.0.113.2/24 dev cli-c
ip netns exec cli ip link set cli-c up; ip netns exec cli ip link set lo up
ip netns exec cli ip route add default via "$HOSTIP"
mkdir -p /tmp/www && echo cli-ok > /tmp/www/index.html
ip netns exec cli python3 -m http.server 8081 --bind 203.0.113.2 --directory /tmp/www > /tmp/cli-http.log 2>&1 &
python3 -m http.server 18080 --bind 0.0.0.0 --directory /tmp/www > /tmp/host-http.log 2>&1 &
sleep 1

section "install (one-line installer, local copy)"
if swapon --show --noheadings | grep -q .; then SWAPARG=--no-swap; else SWAPARG="--swap 2G"; fi
# shellcheck disable=SC2086
check "install.sh finishes" env ERISBOX_SRC="$PWD/erisbox.sh" bash install.sh -y --prebuild $SWAPARG
check "erisbox command works" sh -c "$EB version | grep -q 'Eris Box'"
check "erisbox-net enabled" systemctl is-enabled erisbox-net.service
check "tick timer active" systemctl is-active erisbox-tick.timer
check "lxcfs active" systemctl is-active lxcfs
check "bridge exists" ip link show erisbr0
check "nft tables loaded" nft list table ip erisbox_nat
check "default image prebuilt" sh -c "ls /var/lib/erisbox/cache/*.tar.zst"
check "swap available" sh -c "[ \$(awk '/SwapTotal/{print \$2}' /proc/meminfo) -gt 900000 ]"
SUB="$(grep '^SUBNET=' /etc/erisbox/erisbox.conf | cut -d"'" -f2)"
echo "machines subnet: $SUB.0.0/16"

section "create t1 ($OS_A, 0.2 CPU, 200M RAM, 1G swap, 2G disk)"
check "create t1" $EB create t1 --os "$OS_A" --cpu 0.2 --ram 200M --swap 1G --disk 2G --ports 5 --password Test-Pass-1234 -y
ID1="$(conf t1 ID)"; IP1="$SUB.0.$((10 + ID1))"; SSH1="$(conf t1 SSH_PORT)"
P1="$(conf t1 PORTS | cut -d: -f2 | cut -d- -f1)"
echo "t1: id $ID1 ip $IP1 ssh $SSH1 first port $P1"
check "t1 running" running t1
check "t1 booted" retry 90 booted t1
inside t1 systemctl --failed --no-legend 2>/dev/null | sed 's/^/          failed unit: /'
check "cpu.max = 0.2 core" eq "$(cgv t1 cpu.max)" "20000 100000"
check "memory.max = 200M" eq "$(cgv t1 memory.max)" 209715200
check "memory.swap.max = 1G" eq "$(cgv t1 memory.swap.max)" 1073741824
check "pids.max = 512" eq "$(cgv t1 pids.max)" 512
check "free shows ~200M RAM inside (lxcfs)" between "$(inside t1 free -m | awk '/^Mem:/{print $2}')" 150 210
echo "  INFO  'free' inside shows swap total: $(inside t1 free -m | awk '/^Swap:/{print $2}') MB (the real limit is checked below)"
echo "  INFO  lxcfs: $(lxcfs --version 2>&1 | head -1); $(systemctl cat lxcfs 2>/dev/null | grep '^ExecStart=' | tail -1)"
lxcfs --help 2>&1 | grep -i -E 'swap|cfs' | sed 's/^/          lxcfs option: /'
inside t1 grep -E '^(MemTotal|SwapTotal|SwapFree):' /proc/meminfo | sed 's/^/          inside: /'
check "df shows ~2G disk inside" between "$(inside t1 df -BM --output=size / | tail -1 | tr -dc 0-9)" 1700 2100
check "hostname inside" eq "$(inside t1 hostname)" t1
check "t1 reaches the internet" retry 30 inside t1 curl -fsS -o /dev/null --max-time 10 https://deb.debian.org/
check "apt works inside t1" inside t1 sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null'
check "SSH banner on $HOSTIP:$SSH1" retry 30 is_ssh banner cli "$HOSTIP" "$SSH1"
check "SSH password login" eq "$(ip netns exec cli sshpass -p Test-Pass-1234 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH1" root@$HOSTIP hostname)" t1
inside t1 sh -c 'mkdir -p /srv && echo hello-t1 > /srv/index.html'
guest_service t1 web1 /usr/bin/python3 -m http.server "$P1" --directory /srv
check "port range forward $HOSTIP:$P1" retry 20 sh -c "[ \"\$(ip netns exec cli curl -fsS --max-time 5 http://$HOSTIP:$P1/)\" = hello-t1 ]"
check "spoofed source IP is dropped" not inside t1 sh -c "ip addr add $SUB.0.250/16 dev eth0 && ping -c1 -W2 -I $SUB.0.250 $SUB.0.1"
inside t1 ip addr del "$SUB.0.250/16" dev eth0 2>/dev/null
check "gateway answers ping" inside t1 ping -c1 -W2 "$SUB.0.1"
check "machine cannot reach host services" not inside t1 curl -fsS --max-time 4 "http://$SUB.0.1:18080/"
check "the internet can reach host services (sanity)" http_from_cli "http://$HOSTIP:18080/"
check "cloud metadata address is blocked" not inside t1 curl -fsS --max-time 4 http://169.254.169.254/
U0="$(cgv t1 cpu.stat | awk '/^usage_usec/{print $2}')"
inside t1 timeout 5 sh -c 'while :; do :; done'
U1="$(cgv t1 cpu.stat | awk '/^usage_usec/{print $2}')"
check "CPU limit: 5 s busy loop uses <= ~1.3 s CPU" between "$(( (U1 - U0) / 1000 ))" 400 1300
inside t1 systemd-run --unit=memhog python3 -c "x=b'a'*(450<<20); import time; time.sleep(60)" >/dev/null 2>&1
sleep 12
check "450M program spills into swap" between "$(( $(cgv t1 memory.swap.current) / 1048576 ))" 150 1024
check "RAM stays within 200M" between "$(( $(cgv t1 memory.current) / 1048576 ))" 1 205
inside t1 systemctl stop memhog >/dev/null 2>&1
OOM0="$(cgv t1 memory.events | awk '/^oom_kill /{print $2}')"
check "1.4G program is killed (RAM+swap = 1.2G)" not inside t1 python3 -c "x=b'a'*(1400<<20)"
check "oom_kill counted" sh -c "[ \$(lxc-cgroup -n t1 memory.events | awk '/^oom_kill /{print \$2}') -gt ${OOM0:-0} ]"
check "disk limit: cannot write 2.6G" not inside t1 dd if=/dev/zero of=/fill bs=1M count=2600 status=none
inside t1 rm -f /fill
echo "  INFO  web1 after the OOM test: $(inside t1 systemctl show -p NRestarts --value web1) restart(s), now $(inside t1 systemctl is-active web1)"
check "web1 serving again" retry 20 sh -c "[ \"\$(ip netns exec cli curl -fsS --max-time 5 http://$HOSTIP:$P1/)\" = hello-t1 ]"

section "live changes"
check "set cpu/ram/swap/disk" $EB set t1 --cpu 0.5 --ram 300M --swap 512M --disk 3G -y
check "cpu.max = 0.5" eq "$(cgv t1 cpu.max)" "50000 100000"
check "memory.max = 300M" eq "$(cgv t1 memory.max)" 314572800
check "memory.swap.max = 512M" eq "$(cgv t1 memory.swap.max)" 536870912
check "disk grew online to ~3G" between "$(inside t1 df -BM --output=size / | tail -1 | tr -dc 0-9)" 2700 3100
check "set speed 8 Mbit" $EB set t1 --speed 8 -y
check "tbf qdisc on ebx$ID1" sh -c "tc qdisc show dev ebx$ID1 | grep -q tbf"
check "ingress policer on ebx$ID1" sh -c "tc filter show dev ebx$ID1 ingress | grep -q police"
inside t1 sh -c 'head -c 4000000 /dev/urandom > /srv/big.bin'
SPEED="$(ip netns exec cli curl -s -o /dev/null --max-time 30 -w '%{speed_download}' "http://$HOSTIP:$P1/big.bin" | cut -d. -f1)"
check "download from t1 is limited to ~1 MB/s" between "${SPEED:-0}" 150000 1400000
check "remove speed limit" $EB set t1 --speed 0 -y
check "no qdisc left" not sh -c "tc qdisc show dev ebx$ID1 | grep -q tbf"

section "create t2 ($OS_B, image built on demand)"
check "create t2" $EB create t2 --os "$OS_B" --ports none --password Test-Pass-5678 -y
SSH2="$(conf t2 SSH_PORT)"
check "t2 running" running t2
check "t2 booted" retry 90 booted t2
check "t2 is $OS_B" inside t2 grep -q "ID=${OS_B%%-*}" /etc/os-release
check "SSH banner on $HOSTIP:$SSH2" retry 30 is_ssh banner cli "$HOSTIP" "$SSH2"
check "t2 reaches the internet" retry 30 inside t2 curl -fsS -o /dev/null --max-time 10 https://deb.debian.org/
check "machines are isolated from each other" not inside t2 ping -c1 -W2 "$IP1"
check "hairpin: t2 reaches t1 through the public port" eq "$(inside t2 curl -fsS --max-time 5 "http://$HOSTIP:$P1/")" hello-t1

section "dedicated IP: routed extra IP on the main card"
check "ip add t1 198.51.100.77" $EB ip add t1 198.51.100.77 --force -y
WAN="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
check "address added to $WAN" sh -c "ip -4 addr show dev $WAN | grep -q 198.51.100.77"
check "1:1 inbound: SSH on 198.51.100.77:22" retry 15 is_ssh banner cli 198.51.100.77 22
check "1:1 inbound: any port (198.51.100.77:$P1)" eq "$(http_from_cli "http://198.51.100.77:$P1/")" hello-t1
inside t1 curl -fsS --max-time 5 http://203.0.113.2:8081/ >/dev/null
check "t1 goes out as 198.51.100.77" grep -q '^198.51.100.77 ' /tmp/cli-http.log
inside t2 curl -fsS --max-time 5 http://203.0.113.2:8081/ >/dev/null
check "t2 goes out as the server IP" grep -q "^$HOSTIP " /tmp/cli-http.log
check "second IP for t1" $EB ip add t1 198.51.100.78 --force -y
check "t1 got its second private address" sh -c "$EB exec t1 -- ip -4 addr show eth0 | grep -q '$SUB.1.$((10 + ID1))/'"
check "1:1 inbound on the second IP" retry 15 is_ssh banner cli 198.51.100.78 22
inside t1 curl -fsS --max-time 5 --interface "$SUB.1.$((10 + ID1))" http://203.0.113.2:8081/ >/dev/null
check "t1 can send from the second IP" grep -q '^198.51.100.78 ' /tmp/cli-http.log
check "a third IP is refused (max 2)" not $EB ip add t1 198.51.100.79 --force -y
check "ip del second IP" $EB ip del t1 198.51.100.78 -y
check "second IP no longer answers" not is_ssh banner cli 198.51.100.78 22
check "ip list" sh -c "$EB ip list | grep -q 198.51.100.77"

section "dedicated IP: second network card with policy routing"
ip netns add isp2
ip link add ext1 type veth peer name isp2-c
ip link set isp2-c netns isp2
ip addr add 192.0.2.10/24 dev ext1; ip link set ext1 up
ip netns exec isp2 ip addr add 192.0.2.1/24 dev isp2-c
ip netns exec isp2 ip link set isp2-c up; ip netns exec isp2 ip link set lo up
ip netns exec isp2 ip addr add 198.18.0.1/32 dev lo
ip netns exec isp2 ip route add default via 192.0.2.10
ip netns exec isp2 python3 -m http.server 8082 --bind 198.18.0.1 --directory /tmp/www > /tmp/isp2-http.log 2>&1 &
sleep 1
check "ip add t2 192.0.2.10 (found on ext1)" $EB ip add t2 192.0.2.10 --force -y
check "stored with card ext1 and gateway 192.0.2.1" sh -c "grep -q \"IPS='192.0.2.10,192.0.2.10,ext1,192.0.2.1,0'\" /etc/erisbox/guests/t2.conf"
check "policy rule for 192.0.2.10" sh -c "ip rule | grep -q 'from 192.0.2.10 lookup'"
check "inbound from a far address answers via ext1" retry 15 is_ssh banner_from isp2 198.18.0.1 192.0.2.10 22
check "t2 reaches the far network through ext1" inside t2 curl -fsS --max-time 5 http://198.18.0.1:8082/
check "t2 goes out there as 192.0.2.10" grep -q '^192.0.2.10 ' /tmp/isp2-http.log
check "t2 main-IP SSH still works" is_ssh banner cli "$HOSTIP" "$SSH2"

section "port forwards"
check "port add t1 8085:$P1" $EB port add t1 "8085:$P1" --proto tcp -y
check "8085 -> t1:$P1" eq "$(http_from_cli "http://$HOSTIP:8085/")" hello-t1
check "conflicting port is refused" not $EB port add t2 8085 -y
check "port del t1 8085" $EB port del t1 8085 -y
check "8085 closed again" not http_from_cli "http://$HOSTIP:8085/"
check "change SSH port of t1 to 2299" $EB port ssh t1 2299 -y
check "SSH on 2299" retry 10 is_ssh banner cli "$HOSTIP" 2299

section "domain proxy (nginx)"
if ss -Hltn "sport = :80" | grep -q . || ss -Hltn "sport = :443" | grep -q .; then
  echo "  SKIP  ports 80/443 are busy on this runner"
else
  check "domain enable" $EB domain enable -y
  guest_service t1 web80 /usr/bin/python3 -m http.server 80 --directory /srv
  openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=site1.test -keyout /tmp/k.pem -out /tmp/c.pem -days 2 >/dev/null 2>&1
  cat /tmp/k.pem /tmp/c.pem | $EB exec t1 -- sh -c 'cat > /srv/kc.pem'
  printf '%s\n' "import http.server, ssl, os" "os.chdir('/srv')" \
    "s = http.server.HTTPServer(('', 443), http.server.SimpleHTTPRequestHandler)" \
    "c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain('/srv/kc.pem')" \
    "s.socket = c.wrap_socket(s.socket, server_side=True)" "s.serve_forever()" | $EB exec t1 -- sh -c 'cat > /srv/tls.py'
  guest_service t1 web443 /usr/bin/python3 /srv/tls.py
  check "domain add t1 site1.test" $EB domain add t1 site1.test -y
  check "HTTP by Host header" retry 10 sh -c "[ \"\$(ip netns exec cli curl -fsS --max-time 5 -H 'Host: site1.test' http://$HOSTIP/)\" = hello-t1 ]"
  check "unknown domain gets 404" eq "$(http_code_from_cli -H 'Host: nope.test' "http://$HOSTIP/")" 404
  check "HTTPS passthrough by SNI" retry 10 sh -c "[ \"\$(ip netns exec cli curl -fsSk --max-time 5 --resolve site1.test:443:$HOSTIP https://site1.test/)\" = hello-t1 ]"
  check "another machine reaches the site through the proxy" eq "$(inside t2 curl -fsS --max-time 5 -H 'Host: site1.test' "http://$HOSTIP/")" hello-t1
  check "wildcard domain" $EB domain add t2 example.test --wildcard -y
  check "nginx has the wildcard" grep -q '\.example\.test' /etc/nginx/conf.d/erisbox-http.conf
  check "domain list" sh -c "$EB domain list | grep -q site1.test"
  check "domain del" $EB domain del site1.test -y
  check "deleted domain gets 404" retry 10 sh -c "[ \"\$(ip netns exec cli curl -s -o /dev/null --max-time 5 -w '%{http_code}' -H 'Host: site1.test' http://$HOSTIP/)\" = 404 ]"
fi

section "traffic, quota, expiry (5-minute housekeeping)"
check "tick runs" $EB _tick
check "traffic counted for t1" sh -c "read a b c d < /var/lib/erisbox/traffic/t1; [ \$((a + b)) -gt 100000 ]"
check "set a tiny quota on t2" $EB set t2 --traffic 0.000001 -y
check "tick enforces the quota" $EB _tick
check "t2 marked overquota" eq "$(conf t2 NOTE)" overquota
check "t2 stopped" not running t2
check "start of an over-quota machine is refused" not $EB start t2
check "traffic reset brings it back" $EB traffic t2 --reset -y
check "t2 running again" retry 30 running t2
check "remove quota" $EB set t2 --traffic 0 -y
check "set an expiry in the past" $EB set t2 --expire 2000-01-01 -y
$EB _tick >/dev/null 2>&1
check "t2 expired" eq "$(conf t2 NOTE)" expired
check "expired t2 stopped" not running t2
check "renew 30 days" $EB renew t2 30 -y
check "renewed until +30 days" eq "$(conf t2 EXPIRE)" "$(date -d '+30 days' +%F)"
check "t2 running after renew" retry 30 running t2

section "self-repair and autostart"
nft delete table ip erisbox_nat
$EB _tick >/dev/null 2>&1
check "tick restores deleted NAT rules" nft list table ip erisbox_nat
check "SSH works after repair" retry 15 is_ssh banner cli "$HOSTIP" 2299
lxc-stop -n t1 -t 20 >/dev/null 2>&1; lxc-stop -n t2 -t 20 >/dev/null 2>&1
check "t1 disk unmounted after stop" not mountpoint -q /var/lib/erisbox/mnt/t1
check "boot autostart (lxc-autostart)" lxc-autostart
check "t1 back" retry 30 running t1
check "t2 back" retry 30 running t2
check "t1 SSH after autostart" retry 60 is_ssh banner cli "$HOSTIP" 2299
check "dedicated IP after autostart" retry 30 is_ssh banner cli 198.51.100.77 22

section "password, backup, restore, reinstall"
check "passwd t1" $EB passwd t1 New-Pass-9999 -y
check "login with the new password" retry 20 sh -c "[ \"\$(ip netns exec cli sshpass -p New-Pass-9999 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p 2299 root@$HOSTIP hostname)\" = t1 ]"
inside t2 touch /root/marker
check "backup t2" $EB backup t2 -y
BK="$(ls -t /var/lib/erisbox/backups/t2-*.tar.zst | head -1)"
check "backup file exists" test -s "$BK"
check "delete t2" $EB delete t2 -y
check "t2 config gone" not test -e /etc/erisbox/guests/t2.conf
check "t2 disk gone" not test -e /var/lib/erisbox/disks/t2.img
check "t2 LXC container gone" not test -e /var/lib/lxc/t2
check "restore as t3" $EB restore "$BK" t3 -y
check "t3 running" retry 30 running t3
check "t3 has t2's files" inside t3 test -e /root/marker
check "t3 SSH" retry 60 is_ssh banner cli "$HOSTIP" "$(conf t3 SSH_PORT)"
check "restore again as t5 (uid range must move)" $EB restore "$BK" t5 -y
check "t5 uid range differs from t3" not eq "$(conf t5 UIDBASE)" "$(conf t3 UIDBASE)"
check "t5 running" retry 30 running t5
check "t5 files are owned by its root" eq "$(inside t5 stat -c %u /root/marker)" 0
check "t5 keeps setuid bits" eq "$(inside t5 stat -c %a /usr/bin/sudo)" 4755
check "t5 SSH" retry 60 is_ssh banner cli "$HOSTIP" "$(conf t5 SSH_PORT)"
check "reinstall t3 with $OS_A" $EB reinstall t3 --os "$OS_A" --password Reinst-Pass-1 -y
check "t3 running after reinstall" retry 30 running t3
check "t3 files were erased" not inside t3 test -e /root/marker
check "t3 is now $OS_A" inside t3 grep -q "ID=${OS_A%%-*}" /etc/os-release

section "reports"
check "list" $EB list
check "list --json is valid JSON" sh -c "$EB list --json | python3 -m json.tool >/dev/null"
check "status" $EB status
check "info t1" $EB info t1
check "image list" $EB image list
check "settings show" $EB settings
check "help" $EB help

[ "$FAIL" -gt 0 ] && diag

section "delete and uninstall"
check "delete t5" $EB delete t5 -y
check "uninstall --purge" $EB uninstall --purge -y
check "bridge removed" not ip link show erisbr0
check "nft tables removed" not nft list table ip erisbox_nat
check "routing rules removed" not sh -c "ip rule | grep -q '^31000:'"
check "extra IP removed from $WAN" not sh -c "ip -4 addr show dev $WAN | grep -q 198.51.100.77"
check "containers removed" not test -e /var/lib/lxc/t1
check "command removed" not test -e $EB
check "data removed" not test -e /var/lib/erisbox

echo
echo "=============================================="
echo "  $PASS passed, $FAIL failed  (host $(. /etc/os-release; echo "$VERSION_ID"), guests $OS_A + $OS_B)"
for f in "${FAILED[@]}"; do echo "  - $f"; done
echo "=============================================="
[ "$FAIL" = 0 ]
