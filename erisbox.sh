#!/usr/bin/env bash
# ERIS-BOX-SCRIPT
#
#  Eris Box - split one Linux server into small, isolated machines.
#
#  Every machine is an unprivileged LXC container with its own CPU, RAM,
#  swap and disk limits, root SSH access, forwarded ports on the server's
#  IP and (optionally) up to two dedicated public IPv4 addresses.
#
#  https://github.com/eris4444/eris-box  -  MIT license
#
#  Run "erisbox" for the menu or "erisbox help" for the command line.

SCRIPT_VER="1.1.0"
REPO="eris4444/eris-box"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C
set -o pipefail
umask 022

ETC_DIR=/etc/erisbox
GUEST_DIR=$ETC_DIR/guests
CONF_FILE=$ETC_DIR/erisbox.conf
DOMAIN_FILE=$ETC_DIR/domains
VAR_DIR=/var/lib/erisbox
DISK_DIR=$VAR_DIR/disks
MNT_DIR=$VAR_DIR/mnt
CACHE_DIR=$VAR_DIR/cache
TRAFFIC_DIR=$VAR_DIR/traffic
BACKUP_DIR=$VAR_DIR/backups
LOG_DIR=$VAR_DIR/logs
LIB_DIR=/usr/local/lib/erisbox
BIN_PATH=/usr/local/bin/erisbox
LXC_DIR=/var/lib/lxc
LOCK_FILE=/run/erisbox.lock
NFT_FILE=$VAR_DIR/rules.nft
NGINX_HTTP_CONF=/etc/nginx/conf.d/erisbox-http.conf
NGINX_STREAM_CONF=/etc/nginx/erisbox-stream.conf
UNIT_DIR=/etc/systemd/system

SUBUID_START=1000000     # first host uid/gid used for machines
SUBUID_COUNT=16777216    # size of that range (reserved for root in /etc/subuid)
MAX_ID=240               # max machines (private IPs .11 - .250)
MAX_IPS=2                # dedicated IPv4 addresses per machine
MARK_BASE=$((0x0eb00000))
TABLE_BASE=31000
RULE_PREF=31000
OS_LIST="ubuntu-24.04 ubuntu-22.04 debian-12 debian-13"
LXC_MARK="# erisbox"

YES="${ERISBOX_YES:-0}"
ARCH=""

# ---------------------------------------------------------------- output ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'
  C_M=$'\033[35m'; C_D=$'\033[2m'; C_BD=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_C=""; C_M=""; C_D=""; C_BD=""; C_0=""
fi
info() { printf '%s[*]%s %s\n' "$C_C" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
log()  {
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_DIR/erisbox.log" 2>/dev/null || true
}

# ----------------------------------------------------------------- input ---
tty_ok() { [ -t 0 ] || ( : </dev/tty ) 2>/dev/null; }
interactive() { [ "$YES" != 1 ] && tty_ok; }

# ask VAR "question" [default]  - prompts on the terminal, returns the default without one
ask() {
  local __a=""
  if ! interactive; then printf -v "$1" '%s' "${3-}"; return 0; fi
  if [ -n "${3-}" ]; then
    printf '%s %s[%s]%s: ' "$2" "$C_D" "$3" "$C_0" >/dev/tty
  else
    printf '%s: ' "$2" >/dev/tty
  fi
  IFS= read -r __a </dev/tty || __a=""
  printf -v "$1" '%s' "${__a:-${3-}}"
}
confirm() {
  local __c
  [ "$YES" = 1 ] && return 0
  tty_ok || return 1
  ask __c "$1 (y/n)" "${2:-n}"
  [[ "$__c" =~ ^[Yy] ]]
}
pause() {
  tty_ok || return 0
  printf '\n%sPress Enter to continue...%s' "$C_D" "$C_0" >/dev/tty
  IFS= read -r _ </dev/tty || true
}

# ----------------------------------------------------------------- flags ---
declare -A F=()
POS=()
BOOL_FLAGS=" all boot force json no-start no-swap prebuild purge reset reset-traffic wildcard "
parse_flags() {
  F=(); POS=()
  local k
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) YES=1 ;;
      --) shift; POS+=("$@"); break ;;
      --*=*) k="${1%%=*}"; F["${k#--}"]="${1#*=}" ;;
      --*)
        k="${1#--}"
        if [[ "$BOOL_FLAGS" == *" $k "* ]]; then
          F["$k"]=1
        else
          [ $# -ge 2 ] || die "option --$k needs a value"
          F["$k"]="$2"; shift
        fi ;;
      *) POS+=("$1") ;;
    esac
    shift
  done
}
flag() { if [ -n "${F[$1]+x}" ]; then printf '%s' "${F[$1]}"; else printf '%s' "${2-}"; fi; }
has_flag() { [ -n "${F[$1]+x}" ]; }

# ------------------------------------------------------------ validation ---
valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]]; }
valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do [ $((10#${BASH_REMATCH[$i]})) -le 255 ] || return 1; done
}
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ $((10#$1)) -ge 1 ] && [ $((10#$1)) -le 65535 ]; }
valid_int() { [[ "$1" =~ ^[0-9]{1,9}$ ]]; }
valid_num() { [[ "$1" =~ ^[0-9]{1,6}(\.[0-9]{1,6})?$ ]]; }
valid_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -d "$1" +%F 2>/dev/null)" = "$1" ]; }
# any characters (spaces, quotes, : $ ...), just not empty, no line break, at most 256 bytes
valid_password() { [ -n "$1" ] && [[ "$1" != *$'\n'* ]] && [[ "$1" != *$'\r'* ]] && [ "${#1}" -le 256 ]; }
PW_RULE="the password can be anything except empty or a line break (max 256 bytes)"
valid_url() { [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; }
valid_iface() { [[ "$1" =~ ^[A-Za-z0-9_.:@-]{1,15}$ ]] && [ "$1" != . ] && [ "$1" != .. ]; }
valid_hostport() {
  [[ "$1" =~ ^([0-9.]+):([0-9]+)$ ]] || return 1
  local h="${BASH_REMATCH[1]}" p="${BASH_REMATCH[2]}"
  valid_ipv4 "$h" && valid_port "$p"
}
valid_domain() {
  [ "${#1}" -le 253 ] && [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]
}
valid_sshkey() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9@._+-]{0,64})?$ ]]
}

# ----------------------------------------------------------- conversions ---
# "200M", "1G", "1.5g", "512" (MB) -> bytes
to_bytes() {
  local s="${1^^}"
  [[ "$s" =~ ^([0-9]{1,9}(\.[0-9]{1,6})?)([KMGT]?)(I?B)?$ ]] || return 1
  awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[3]:-M}" 'BEGIN{
    m=1048576; if(u=="K")m=1024; if(u=="G")m=1073741824; if(u=="T")m=1099511627776
    printf "%.0f\n", n*m }'
}
human() {
  awk -v b="${1:-0}" 'BEGIN{ split("B K M G T",u," "); i=1
    while (b>=1024 && i<5) { b/=1024; i++ }
    s=sprintf("%.1f",b); sub(/\.0$/,"",s); printf "%s%s\n", s, u[i] }'
}
cpu_quota() { awk -v c="$1" 'BEGIN{printf "%d\n", c*100000+0.5}'; }
# "0.20" -> 0.2, "1.0" -> 1, "0.000001" stays (never scientific notation)
norm_num() { awk -v c="$1" 'BEGIN{s=sprintf("%.6f", c+0); sub(/0+$/,"",s); sub(/\.$/,"",s); print s}'; }
norm_cpu() { norm_num "$1"; }
gb_to_bytes() { awk -v g="$1" 'BEGIN{printf "%.0f\n", g*1073741824}'; }
ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
gen_password() { head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; echo; }

check_cpu() {
  valid_num "$1" || die "CPU must be a number of cores, for example 0.2 or 1"
  local q; q=$(cpu_quota "$1")
  [ "$q" -ge 1000 ] || die "CPU must be at least 0.01"
  [ "$q" -le $(( $(host_cpus) * 100000 )) ] || die "CPU cannot be more than this server's $(host_cpus) core(s)"
}
check_size() { # what value minimum
  local b m
  b=$(to_bytes "$2") || die "invalid $1 size '$2' (examples: 200M, 1G, 1.5G)"
  m=$(to_bytes "$3")
  [ "$b" -ge "$m" ] || die "$1 must be at least $3"
}
# "30" (days from today) | "2026-12-31" | "never" -> date or empty
expire_value() {
  case "$1" in ""|0|never|none|off) echo ""; return 0 ;; esac
  if valid_int "$1"; then date -d "+$((10#$1)) days" +%F; return 0; fi
  valid_date "$1" && { echo "$1"; return 0; }
  return 1
}

# ------------------------------------------------- key='value' conf files ---
kv_load() { # file prefix
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'$ ]] || continue
    printf -v "$2${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
  done < "$1"
}
kv_save() { # file prefix keys...
  local f="$1" p="$2" k v tmp
  shift 2
  mkdir -p "${f%/*}"
  tmp="$(mktemp "$f.XXXXXX")" || die "cannot write $f"
  {
    echo "# Eris Box - generated file, change it with the erisbox command"
    for k in "$@"; do
      v="${p}${k}"; v="${!v-}"
      if [[ "$v" == *"'"* || "$v" == *$'\n'* ]]; then rm -f "$tmp"; die "invalid value for $k"; fi
      printf "%s='%s'\n" "$k" "$v"
    done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}
kv_get() { # file key
  local l
  l="$(grep -m1 "^$2='" "$1" 2>/dev/null)" || return 0
  l="${l#*=\'}"
  printf '%s' "${l%\'}"
}

# -------------------------------------------------------------- settings ---
S_KEYS="PUBLIC_IP SUBNET BRIDGE SSH_PORT_START PORT_RANGE_START PORTS_PER_GUEST DEF_OS DEF_CPU DEF_RAM DEF_SWAP DEF_DISK DEF_PIDS DNS BLOCK_SMTP BLOCK_PRIVATE QUOTA_ACTION UBUNTU_MIRROR UBUNTU_PORTS_MIRROR DEBIAN_MIRROR PROXY_ENABLED PROXY_DEFAULT_HTTP PROXY_DEFAULT_TLS"
s_defaults() {
  S_PUBLIC_IP=""; S_SUBNET="10.88"; S_BRIDGE="erisbr0"
  S_SSH_PORT_START=2201; S_PORT_RANGE_START=20001; S_PORTS_PER_GUEST=10
  S_DEF_OS="ubuntu-24.04"; S_DEF_CPU="0.2"; S_DEF_RAM="200M"; S_DEF_SWAP="1G"; S_DEF_DISK="2G"; S_DEF_PIDS=512
  S_DNS="1.1.1.1 8.8.8.8"; S_BLOCK_SMTP=1; S_BLOCK_PRIVATE=1; S_QUOTA_ACTION="stop"
  S_UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu"
  S_UBUNTU_PORTS_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
  S_DEBIAN_MIRROR="http://deb.debian.org/debian"
  S_PROXY_ENABLED=0; S_PROXY_DEFAULT_HTTP=""; S_PROXY_DEFAULT_TLS=""
}
s_load() { s_defaults; kv_load "$CONF_FILE" S_; }
# shellcheck disable=SC2086
s_save() { kv_save "$CONF_FILE" S_ $S_KEYS; }

# --------------------------------------------------------------- machines ---
# the root password is kept base64-encoded (PASSWORD64) so it may contain any character
G_KEYS="ID UIDBASE OS CPU RAM SWAP DISK PIDS IO_MBPS IO_IOPS TUN SPEED TRAFFIC_GB RESET_DAY RESET_TAG EXPIRE SSH_PORT PORTS IPS PASSWORD64 NOTE AUTOSTART CREATED"
g_reset() {
  G_NAME=""; G_ID=""; G_UIDBASE=""; G_OS=""; G_CPU=""; G_RAM=""; G_SWAP=""; G_DISK=""; G_PIDS=512
  G_IO_MBPS=0; G_IO_IOPS=0; G_TUN=0; G_SPEED=0; G_TRAFFIC_GB=0; G_RESET_DAY=0; G_RESET_TAG=""
  G_EXPIRE=""; G_SSH_PORT=""; G_PORTS=""; G_IPS=""; G_PASSWORD=""; G_PASSWORD64=""; G_NOTE=""; G_AUTOSTART=1; G_CREATED=""
}
g_conf() { printf '%s/%s.conf' "$GUEST_DIR" "$1"; }
g_exists() { valid_name "$1" && [ -f "$(g_conf "$1")" ]; }
g_pw_decode() { # PASSWORD64 -> G_PASSWORD (files from 1.0.x keep a plain PASSWORD='...')
  if [ -n "$G_PASSWORD64" ]; then G_PASSWORD="$(printf '%s' "$G_PASSWORD64" | base64 -d 2>/dev/null)"; fi
  return 0
}
g_load() {
  g_exists "$1" || die "machine '$1' not found (see: erisbox list)"
  g_reset
  kv_load "$(g_conf "$1")" G_
  g_pw_decode
  G_NAME="$1"
}
# shellcheck disable=SC2086
g_save() {
  G_PASSWORD64="$(printf '%s' "$G_PASSWORD" | base64 -w0)"
  kv_save "$(g_conf "$G_NAME")" G_ $G_KEYS
}
pw_hash() { printf '%s' "$1" | openssl passwd -6 -stdin; }   # SHA-512 crypt
g_names() {
  local f
  for f in "$GUEST_DIR"/*.conf; do
    [ -e "$f" ] || continue
    f="${f##*/}"; f="${f%.conf}"
    valid_name "$f" && printf '%s\n' "$f"
  done
}
g_base() { if [ -n "$G_UIDBASE" ]; then echo "$G_UIDBASE"; else echo $((SUBUID_START + G_ID * 65536)); fi; }
g_ip()   { printf '%s.0.%d' "$S_SUBNET" $((10 + G_ID)); }
g_ip2()  { printf '%s.1.%d' "$S_SUBNET" $((10 + G_ID)); }
gw_ip()  { printf '%s.0.1' "$S_SUBNET"; }
g_veth() { printf 'ebx%d' "$G_ID"; }
g_mac()  { printf '02:eb:00:00:%02x:%02x' $((G_ID >> 8)) $((G_ID & 255)); }
g_img()  { printf '%s/%s.img' "$DISK_DIR" "$G_NAME"; }
g_mnt()  { printf '%s/%s' "$MNT_DIR" "$G_NAME"; }
g_state() { local s; s="$(lxc-info -n "$1" -sH 2>/dev/null)"; printf '%s' "${s:-STOPPED}"; }
g_running() { [ "$(g_state "$1")" = RUNNING ]; }
g_pid() { lxc-info -n "$1" -pH 2>/dev/null; }
guest_ip_of() { printf '%s.0.%d' "$S_SUBNET" $((10 + $(kv_get "$(g_conf "$1")" ID))); }
cg_read() { lxc-cgroup -n "$1" "$2" 2>/dev/null; }
cg_supports() { [ -e "/sys/fs/cgroup/system.slice/$1" ] || [ -e "/sys/fs/cgroup/init.scope/$1" ]; }
ip_entries() { [ -n "$G_IPS" ] && printf '%s\n' "${G_IPS//;/$'\n'}" | sed '/^$/d'; }
ips_count() { ip_entries | grep -c . ; }
autostart_value() { if [ "$G_AUTOSTART" = 1 ] && [ -z "$G_NOTE" ]; then echo 1; else echo 0; fi; }

guest_exec() { # name command...
  local n="$1"; shift
  lxc-attach -n "$n" --clear-env \
    -v PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -v HOME=/root -v LANG=C.UTF-8 -v "TERM=${TERM:-xterm}" -- "$@"
}

g_usage() { # sets U_MEM U_SWAP U_DUSED U_DSIZE for the loaded machine
  U_MEM=0; U_SWAP=0; U_DUSED=0; U_DSIZE=$(to_bytes "$G_DISK")
  if g_running "$G_NAME"; then
    U_MEM=$(cg_read "$G_NAME" memory.current); U_SWAP=$(cg_read "$G_NAME" memory.swap.current)
  fi
  U_MEM=${U_MEM:-0}; U_SWAP=${U_SWAP:-0}
  if mountpoint -q "$(g_mnt)"; then
    read -r U_DUSED U_DSIZE < <(df -B1 --output=used,size "$(g_mnt)" | tail -1)
  fi
}

# ------------------------------------------------------------------- host ---
host_cpus() { nproc 2>/dev/null || echo 1; }
host_mem() { awk '/^MemTotal:/{printf "%.0f\n", $2*1024}' /proc/meminfo; }
host_memavail() { awk '/^MemAvailable:/{printf "%.0f\n", $2*1024}' /proc/meminfo; }
host_swap() { awk '/^SwapTotal:/{printf "%.0f\n", $2*1024}' /proc/meminfo; }
disk_free() { df -B1 --output=avail "${1:-$VAR_DIR}" 2>/dev/null | tail -1 | tr -d ' '; }
wan_if()  { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
wan_src() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}'; }
detect_public_ip() {
  local u ip
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d ' \r\n')"
    valid_ipv4 "$ip" && { echo "$ip"; return 0; }
  done
  wan_src
}
public_ip() { if [ -n "$S_PUBLIC_IP" ]; then echo "$S_PUBLIC_IP"; else wan_src; fi; }
is_installed() { [ -f "$CONF_FILE" ] && [ -x "$LIB_DIR/hook-prestart" ] && command -v lxc-start >/dev/null 2>&1; }
need_root() { [ "$(id -u)" = 0 ] || die "please run as root (sudo -i)"; }
need_installed() { is_installed || die "Eris Box is not installed yet - run: erisbox install"; }
take_lock() {
  exec 8>"$LOCK_FILE"
  flock -w 300 8 || die "another erisbox command is still running"
}
apt_install() {
  DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get -o DPkg::Lock::Timeout=300 update -qq \
    || warn "apt-get update reported errors"
  DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
    --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# ================================================================ INSTALL ===
cmd_install() {
  parse_flags "$@"
  need_root
  local os_id os_ver virt fresh=0
  os_id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
  os_ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
  case "$os_id" in
    ubuntu) case "$os_ver" in 22.04|24.04) ;; *) warn "Ubuntu $os_ver is not tested (22.04 and 24.04 are)";; esac ;;
    debian) warn "Debian hosts are not tested (Ubuntu 22.04 / 24.04 are)" ;;
    *) die "this server runs '$os_id' - Eris Box needs Ubuntu 22.04 or 24.04" ;;
  esac
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in
    openvz|lxc|lxc-libvirt|docker|podman|rkt|wsl|systemd-nspawn|proot|pouch|container-other)
      die "this server is itself a container ($virt). Eris Box needs a KVM / VMware / Hyper-V VPS or a dedicated server." ;;
  esac
  [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = cgroup2fs ] \
    || die "cgroup v2 is required (Ubuntu 22.04+ uses it by default)"
  case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) die "only amd64 and arm64 servers are supported" ;; esac

  info "Installing packages (LXC, lxcfs, debootstrap, nftables, ...)"
  [ -e /etc/default/lxc-net ] || printf '# Eris Box uses its own bridge\nUSE_LXC_BRIDGE="false"\n' > /etc/default/lxc-net
  apt_install lxc-utils lxcfs uidmap debootstrap nftables iproute2 zstd curl ca-certificates \
    e2fsprogs util-linux procps openssl openssh-client python3 gpg \
    || die "package installation failed"
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends \
    debian-archive-keyring ubuntu-keyring >/dev/null 2>&1 || true
  command -v lxc-start >/dev/null || die "LXC was not installed correctly"
  lxc_net_off

  mkdir -p "$GUEST_DIR" "$DISK_DIR" "$MNT_DIR" "$CACHE_DIR" "$TRAFFIC_DIR" "$BACKUP_DIR" "$LOG_DIR" "$LIB_DIR" "$LXC_DIR"
  chmod 700 "$ETC_DIR" "$GUEST_DIR" "$DISK_DIR" "$BACKUP_DIR"
  # the machines' (unprivileged) root must be able to pass through these directories
  chmod 711 "$VAR_DIR" "$MNT_DIR" "$LXC_DIR"
  touch "$DOMAIN_FILE"; chmod 600 "$DOMAIN_FILE"
  subuid_setup

  if [ ! -f "$CONF_FILE" ]; then
    fresh=1
    s_defaults
    S_SUBNET="$(pick_subnet)" || die "could not find a free private subnet for the machines"
    info "Detecting this server's public IP ..."
    S_PUBLIC_IP="$(detect_public_ip)"
    [ "$os_id" = ubuntu ] && [ "$os_ver" = 22.04 ] && S_DEF_OS="ubuntu-22.04"
    s_save
  fi
  s_load
  self_install
  write_hooks
  write_units
  write_sysctl
  systemctl daemon-reload
  systemctl enable --now lxcfs >/dev/null 2>&1 || warn "could not start lxcfs (machines will see the host's memory in 'free')"
  systemctl enable lxc >/dev/null 2>&1 || true
  systemctl enable erisbox-net.service >/dev/null 2>&1
  systemctl enable --now erisbox-tick.timer >/dev/null 2>&1
  swap_setup
  cg_supports memory.swap.max || warn "this kernel has no swap accounting - per-machine swap limits will not apply"

  take_lock
  net_apply || die "network setup failed"

  if has_flag prebuild || { [ "$fresh" = 1 ] && confirm "Download and prepare the default OS ($S_DEF_OS) now? It takes a few minutes and makes the first machine faster" y; }; then
    image_ensure "$S_DEF_OS" || warn "image build failed - it will be retried when you create a machine"
  fi

  log "installed/repaired version $SCRIPT_VER"
  echo
  ok "Eris Box $SCRIPT_VER is ready."
  printf '    Public IP : %s   (change: erisbox settings set PUBLIC_IP x.x.x.x)\n' "$(public_ip)"
  printf '    Bridge    : %s %s/16\n' "$S_BRIDGE" "$(gw_ip)"
  printf '    Swap      : %s\n' "$(human "$(host_swap)")"
  printf '    Next      : run %serisbox%s for the menu, or: erisbox create alice\n' "$C_BD" "$C_0"
}

self_install() {
  local src
  src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
  if [ -f "$src" ] && [ "$src" != "$BIN_PATH" ]; then
    install -m 755 "$src" "$BIN_PATH"
  elif [ ! -x "$BIN_PATH" ]; then
    curl -fsSL "$RAW_BASE/erisbox.sh" -o "$BIN_PATH.new" && grep -q '^# ERIS-BOX-SCRIPT' "$BIN_PATH.new" \
      && chmod 755 "$BIN_PATH.new" && mv -f "$BIN_PATH.new" "$BIN_PATH" \
      || die "could not install $BIN_PATH"
  fi
}

lxc_net_off() {
  local f
  if grep -qs '^USE_LXC_BRIDGE="false"' /etc/default/lxc-net; then
    systemctl stop lxc-net >/dev/null 2>&1 || true
    return 0
  fi
  for f in "$LXC_DIR"/*/config; do
    [ -f "$f" ] || continue
    if grep -q lxcbr0 "$f" && ! grep -q "^$LXC_MARK" "$f"; then
      info "other LXC containers use lxcbr0 - leaving lxc-net alone"
      return 0
    fi
  done
  systemctl stop lxc-net >/dev/null 2>&1 || true
  if grep -qs '^USE_LXC_BRIDGE=' /etc/default/lxc-net; then
    sed -i 's/^USE_LXC_BRIDGE=.*/USE_LXC_BRIDGE="false"/' /etc/default/lxc-net
  else
    echo 'USE_LXC_BRIDGE="false"' >> /etc/default/lxc-net
  fi
}

subuid_setup() {
  local f u
  for f in /etc/subuid /etc/subgid; do
    touch "$f"
    grep -q "^root:${SUBUID_START}:${SUBUID_COUNT}\$" "$f" || echo "root:${SUBUID_START}:${SUBUID_COUNT}" >> "$f"
    while read -r u; do
      [ -n "$u" ] && warn "$f: the range of user '$u' overlaps Eris Box ids ($SUBUID_START+)"
    done < <(awk -F: -v s="$SUBUID_START" -v c="$SUBUID_COUNT" '$1!="root" && $2+$3>s && $2<s+c {print $1}' "$f")
  done
}

subnet_free() { # "10.88" -> is 10.88.0.0/16 unused here?
  local cand net len m n mask
  cand=$(ip2int "$1.0.0")
  while read -r net; do
    [ -n "$net" ] || continue
    [[ "$net" == */* ]] || net="$net/32"
    len=${net#*/}; net=${net%/*}
    valid_ipv4 "$net" && valid_int "$len" || continue
    m=$(( len < 16 ? len : 16 ))
    [ "$m" -gt 0 ] || continue
    n=$(ip2int "$net")
    mask=$(( (0xffffffff << (32 - m)) & 0xffffffff ))
    [ $(( cand & mask )) -eq $(( n & mask )) ] && return 1
  done < <(
    ip -4 route show table main 2>/dev/null | grep -v " dev $S_BRIDGE" | awk '{print $1}'
    ip -4 -o addr show 2>/dev/null | awk -v br="$S_BRIDGE" '$2!=br {print $4}'
  )
  return 0
}
pick_subnet() {
  local c
  for c in 10.88 10.89 10.90 10.91 10.92 10.93 10.94 10.95 10.96 10.97 172.30 172.29; do
    subnet_free "$c" && { echo "$c"; return 0; }
  done
  return 1
}

write_hooks() {
  local h
  mkdir -p "$LIB_DIR"
  for h in prestart poststop netup netdown; do
    printf '#!/bin/sh\n# Eris Box LXC hook\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\nexec %s _hook %s "$@"\n' \
      "$BIN_PATH" "$h" > "$LIB_DIR/hook-$h"
    chmod 755 "$LIB_DIR/hook-$h"
  done
}

write_units() {
  cat > "$UNIT_DIR/erisbox-net.service" <<EOF
[Unit]
Description=Eris Box network (bridge, NAT and firewall rules)
Wants=network-online.target
After=network-online.target docker.service ufw.service nftables.service
Before=lxc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN_PATH apply --boot

[Install]
WantedBy=multi-user.target
EOF
  cat > "$UNIT_DIR/erisbox-tick.service" <<EOF
[Unit]
Description=Eris Box housekeeping (traffic, quotas, expiry, self-repair)

[Service]
Type=oneshot
ExecStart=$BIN_PATH _tick
EOF
  cat > "$UNIT_DIR/erisbox-tick.timer" <<'EOF'
[Unit]
Description=Run Eris Box housekeeping every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

write_sysctl() {
  local f=/etc/sysctl.d/90-erisbox.conf swap_line=0
  # with vm.swappiness=0 the kernel never swaps a cgroup, so the machines' swap would be useless
  if [ "$(cat /proc/sys/vm/swappiness 2>/dev/null)" = 0 ] || grep -qs '^vm.swappiness' "$f"; then
    swap_line=1
    [ "$(cat /proc/sys/vm/swappiness 2>/dev/null)" = 0 ] && warn "vm.swappiness was 0 (machines could never use swap) - set to 10"
  fi
  {
    printf '# Eris Box: route traffic for the machines\nnet.ipv4.ip_forward = 1\n'
    [ "$swap_line" = 1 ] && printf '# let the machines use their swap\nvm.swappiness = 10\n'
  } > "$f"
  sysctl -q -p "$f" >/dev/null 2>&1 || sysctl -qw net.ipv4.ip_forward=1
}

swap_setup() {
  local cur size bytes f=/swapfile-erisbox
  has_flag no-swap && return 0
  cur=$(host_swap)
  size="$(flag swap)"
  if [ -z "$size" ]; then
    if [ "$cur" -ge 1073741824 ]; then info "Swap: $(human "$cur") is already available"; return 0; fi
    ask size "This server has $(human "$cur") swap. Create a swap file for the machines? Size (0 = no)" 2G
  fi
  [ "$size" = 0 ] && return 0
  bytes=$(to_bytes "$size") || die "invalid swap size '$size'"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$f"; then info "swap file $f is already active"; return 0; fi
  [ "$(disk_free /)" -gt $((bytes + 1073741824)) ] || { warn "not enough free disk for a $(human "$bytes") swap file"; return 0; }
  info "Creating swap file $f ($(human "$bytes"))"
  rm -f "$f"
  fallocate -l "$bytes" "$f" 2>/dev/null || dd if=/dev/zero of="$f" bs=1M count=$((bytes / 1048576)) status=none
  chmod 600 "$f"
  mkswap "$f" >/dev/null && swapon "$f" || { warn "could not enable swap"; rm -f "$f"; return 0; }
  grep -q "^$f " /etc/fstab || echo "$f none swap sw 0 0" >> /etc/fstab
  ok "swap file enabled"
}

refresh_all() { # after an update: rewrite helpers + LXC configs, re-apply rules
  need_root; need_installed; s_load
  write_hooks; write_units; write_sysctl
  systemctl daemon-reload
  systemctl enable erisbox-net.service >/dev/null 2>&1
  systemctl enable --now erisbox-tick.timer >/dev/null 2>&1
  take_lock
  local n
  for n in $(g_names); do g_load "$n"; g_save; lxc_write_config; guest_banner_live; done
  G_NAME=""
  net_apply
}

# ================================================================= IMAGES ===
os_resolve() { # sets O_FAMILY O_SUITE O_LABEL O_MIRROR O_SEC O_SCRIPT
  [ -n "$ARCH" ] || ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  case "$1" in
    ubuntu-22.04) O_FAMILY=ubuntu; O_SUITE=jammy;    O_LABEL="Ubuntu 22.04" ;;
    ubuntu-24.04) O_FAMILY=ubuntu; O_SUITE=noble;    O_LABEL="Ubuntu 24.04" ;;
    debian-12)    O_FAMILY=debian; O_SUITE=bookworm; O_LABEL="Debian 12" ;;
    debian-13)    O_FAMILY=debian; O_SUITE=trixie;   O_LABEL="Debian 13" ;;
    *) return 1 ;;
  esac
  if [ "$O_FAMILY" = ubuntu ]; then
    O_SCRIPT=gutsy
    if [ "$ARCH" = amd64 ]; then
      O_MIRROR="${S_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"; O_SEC="http://security.ubuntu.com/ubuntu"
    else
      O_MIRROR="${S_UBUNTU_PORTS_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"; O_SEC="$O_MIRROR"
    fi
  else
    O_SCRIPT=sid
    O_MIRROR="${S_DEBIAN_MIRROR:-http://deb.debian.org/debian}"; O_SEC="http://security.debian.org/debian-security"
  fi
}
os_label() { if os_resolve "$1"; then printf '%s' "$O_LABEL"; else printf '%s' "$1"; fi; }
image_ensure() { [ -s "$CACHE_DIR/$1.tar.zst" ] || image_build "$1"; }

umount_below() { # unmount anything mounted inside a directory
  local m
  while read -r m; do umount -l "$m" 2>/dev/null; done < <(findmnt -rno TARGET | grep "^$1/" | sort -r)
}

# Older hosts (Ubuntu 22.04) ship a Debian keyring without the current release keys:
# add Debian's official archive keys (fetched over HTTPS from ftp-master.debian.org).
debian_keyring() {
  local out="$CACHE_DIR/debian-archive-keys.gpg" tmp k
  if [ -s "$out" ] && [ -n "$(find "$out" -mtime -30 2>/dev/null)" ]; then echo "$out"; return 0; fi
  tmp="$(mktemp -d)"
  [ -f /usr/share/keyrings/debian-archive-keyring.gpg ] && cp /usr/share/keyrings/debian-archive-keyring.gpg "$tmp/00-system.gpg"
  if command -v gpg >/dev/null 2>&1; then
    for k in archive-key-12 archive-key-12-security release-12 archive-key-13 archive-key-13-security release-13 \
             archive-key-14 archive-key-14-security release-14; do
      curl -fsS --max-time 20 "https://ftp-master.debian.org/keys/$k.asc" -o "$tmp/$k.asc" 2>/dev/null \
        && gpg --dearmor < "$tmp/$k.asc" > "$tmp/$k.gpg" 2>/dev/null
      rm -f "$tmp/$k.asc"
    done
  fi
  cat "$tmp"/*.gpg > "$out.tmp" 2>/dev/null && mv -f "$out.tmp" "$out"
  rm -rf "$tmp"
  [ -s "$out" ] && echo "$out"
}

image_build() {
  os_resolve "$1" || { err "unknown OS '$1'"; return 1; }
  local dir="$CACHE_DIR/build-$1" out="$CACHE_DIR/$1.tar.zst" pkgs logf="$LOG_DIR/image-$1.log" keyring="" kr
  pkgs="systemd-sysv,dbus,openssh-server,iproute2,iputils-ping,ca-certificates,curl,wget,nano,less,sudo,cron,procps,netbase,gnupg,unzip,tzdata,logrotate"
  if [ "$O_FAMILY" = debian ]; then
    kr="$(debian_keyring)" && keyring="--keyring=$kr"
  elif [ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
    keyring="--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  fi
  [ "$(disk_free "$CACHE_DIR")" -gt 1073741824 ] || { err "need at least 1G free disk to build an image"; return 1; }
  umount_below "$dir"; rm -rf --one-file-system "$dir"; mkdir -p "$dir"
  info "Building the $O_LABEL image from $O_MIRROR (first time only, a few minutes) ..."
  # shellcheck disable=SC2086
  if ! debootstrap --variant=minbase --arch="$ARCH" --components=main $keyring --include="$pkgs" \
        "$O_SUITE" "$dir" "$O_MIRROR" "/usr/share/debootstrap/scripts/$O_SCRIPT" > "$logf" 2>&1; then
    err "debootstrap failed - last lines of $logf:"
    tail -n 15 "$logf" >&2
    umount_below "$dir"; rm -rf --one-file-system "$dir"
    return 1
  fi
  umount_below "$dir"
  image_customize "$dir"
  info "Packing the image ..."
  if ! tar --numeric-owner -C "$dir" -cpf - --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' \
        --exclude='./run/*' --exclude='./tmp/*' . | zstd -q -T0 -6 > "$out.tmp"; then
    rm -f "$out.tmp"; rm -rf --one-file-system "$dir"; err "packing the image failed"; return 1
  fi
  mv -f "$out.tmp" "$out"
  rm -rf --one-file-system "$dir"
  ok "image $1 ready ($(human "$(stat -c %s "$out")"))"
}

image_customize() {
  local d="$1" u
  if [ "$O_FAMILY" = ubuntu ]; then
    rm -f "$d/etc/apt/sources.list.d/ubuntu.sources"
    cat > "$d/etc/apt/sources.list" <<EOF
deb $O_MIRROR $O_SUITE main restricted universe multiverse
deb $O_MIRROR $O_SUITE-updates main restricted universe multiverse
deb $O_SEC $O_SUITE-security main restricted universe multiverse
EOF
  else
    rm -f "$d/etc/apt/sources.list.d/debian.sources"
    cat > "$d/etc/apt/sources.list" <<EOF
deb $O_MIRROR $O_SUITE main contrib non-free non-free-firmware
deb $O_MIRROR $O_SUITE-updates main contrib non-free non-free-firmware
deb $O_SEC $O_SUITE-security main contrib non-free non-free-firmware
EOF
  fi
  rm -f "$d"/etc/ssh/ssh_host_*
  : > "$d/etc/machine-id"
  rm -f "$d/var/lib/dbus/machine-id" "$d/etc/resolv.conf"
  mkdir -p "$d/etc/ssh/sshd_config.d" "$d/etc/systemd/journald.conf.d" "$d/etc/systemd/system"
  printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$d/etc/ssh/sshd_config.d/10-erisbox.conf"
  printf '[Journal]\nSystemMaxUse=40M\n' > "$d/etc/systemd/journald.conf.d/erisbox.conf"
  for u in systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
           systemd-resolved.service systemd-timesyncd.service e2scrub_all.timer e2scrub_reap.service \
           fstrim.timer systemd-journald-audit.socket; do
    ln -sf /dev/null "$d/etc/systemd/system/$u"
  done
  : > "$d/etc/fstab"
  echo 'LANG=C.UTF-8' > "$d/etc/default/locale"
  ln -sf /usr/share/zoneinfo/Etc/UTC "$d/etc/localtime"
  echo 'Etc/UTC' > "$d/etc/timezone"
  rm -f "$d"/var/cache/apt/archives/*.deb "$d"/var/cache/apt/*.bin
  find "$d/var/lib/apt/lists" -maxdepth 1 -type f -delete 2>/dev/null
}

# ============================================================ DISK + FILES ===
guest_mount() {
  local mnt img
  mnt="$(g_mnt)"; img="$(g_img)"
  mkdir -p "$mnt"
  mountpoint -q "$mnt" && return 0
  [ -f "$img" ] || { err "disk image missing: $img"; return 1; }
  mount -o loop,noatime,nodev "$img" "$mnt" || { err "cannot mount $img"; return 1; }
}
guest_umount() {
  local mnt; mnt="$(g_mnt)"
  mountpoint -q "$mnt" || return 0
  umount "$mnt" 2>/dev/null || { sleep 2; umount "$mnt"; }
}

# write a file into a FRESHLY built disk (never used on an existing machine)
gwrite() { # relpath mode  (content on stdin)
  local f; f="$(g_mnt)/$1"
  rm -f "$f"
  cat > "$f" && chmod "$2" "$f" && chown "$(g_base):$(g_base)" "$f"
}

guest_build() { # [ssh_key]  - new disk + root filesystem for the loaded machine
  local img mnt base bytes cache
  img="$(g_img)"; mnt="$(g_mnt)"; base="$(g_base)"; bytes="$(to_bytes "$G_DISK")"
  cache="$CACHE_DIR/$G_OS.tar.zst"
  [ -s "$cache" ] || { err "image $G_OS is missing"; return 1; }
  mkdir -p "$DISK_DIR" "$mnt"
  guest_umount
  rm -f "$img"
  fallocate -l "$bytes" "$img" 2>/dev/null || truncate -s "$bytes" "$img" || { err "cannot create $img"; return 1; }
  chmod 600 "$img"
  mkfs.ext4 -q -F -m 0 -L "ebx$G_ID" -E "root_owner=$base:$base" "$img" >/dev/null 2>&1 \
    || { err "mkfs.ext4 failed"; return 1; }
  guest_mount || return 1
  [ -d "$mnt/lost+found" ] && chown "$base:$base" "$mnt/lost+found"
  info "Unpacking $(os_label "$G_OS") ..."
  if ! zstd -dc "$cache" | lxc-usernsexec -m "b:0:$base:65536" -- tar --numeric-owner -xpf - -C "$mnt"; then
    err "unpacking the image failed"; return 1
  fi
  guest_setup_files "${1:-}"
}

guest_setup_files() {
  local key="${1:-}" m b t hash tmp days
  m="$(g_mnt)"; b="$(g_base)"
  gwrite etc/hostname 644 <<<"$G_NAME" || return 1
  printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' "$G_NAME" | gwrite etc/hosts 644
  for t in $S_DNS; do echo "nameserver $t"; done | gwrite etc/resolv.conf 644
  printf '%s\n' "$(tr -d -- '-\n' </proc/sys/kernel/random/uuid)" | gwrite etc/machine-id 444
  guest_banner_fresh
  for t in rsa ecdsa ed25519; do
    rm -f "$m/etc/ssh/ssh_host_${t}_key" "$m/etc/ssh/ssh_host_${t}_key.pub"
    ssh-keygen -q -t "$t" -N '' -C "root@$G_NAME" -f "$m/etc/ssh/ssh_host_${t}_key" </dev/null >/dev/null \
      || { err "ssh-keygen failed"; return 1; }
    chown "$b:$b" "$m/etc/ssh/ssh_host_${t}_key" "$m/etc/ssh/ssh_host_${t}_key.pub"
  done
  hash="$(pw_hash "$G_PASSWORD")" && [ -n "$hash" ] || { err "openssl passwd failed"; return 1; }
  days=$(( $(date +%s) / 86400 ))
  tmp="$(mktemp)"
  awk -F: -v OFS=: -v h="$hash" -v d="$days" '$1=="root"{$2=h; $3=d} {print}' "$m/etc/shadow" > "$tmp" \
    && cat "$tmp" > "$m/etc/shadow"
  rm -f "$tmp"
  if [ -n "$key" ]; then
    rm -rf "$m/root/.ssh"; mkdir -m 700 "$m/root/.ssh"; chown "$b:$b" "$m/root/.ssh"
    printf '%s\n' "$key" | gwrite root/.ssh/authorized_keys 600
  fi
  return 0
}

# Colourful login banner shown inside the machine (pam_motd runs /etc/update-motd.d at SSH login).
# Only the machine's name, OS, uptime and date - never its RAM / CPU / disk.
BANNER_VER=2
banner_script() {
  cat <<'EOF'
#!/bin/sh
# Eris Box welcome banner - shown at SSH login
. /etc/os-release 2>/dev/null
name="$(hostname 2>/dev/null)"
os="${PRETTY_NAME:-Linux}"
up="$(uptime -p 2>/dev/null | sed 's/^up //')"
now="$(date '+%A %d %B %Y  %H:%M %Z')"
title="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | sed 's/./& /g; s/ $//')"
e="$(printf '\033')"
rule() {
  printf '  '
  for c in 201 200 199 198 163 164 129 128 93 92 57 63 69 75 81 87; do printf '%s[38;5;%sm━━━' "$e" "$c"; done
  printf '%s[0m\n' "$e"
}
echo
rule
printf '   %s[1;38;5;213m◆%s[0m  %s[1;38;5;159m%s%s[0m\n' "$e" "$e" "$e" "$title" "$e"
rule
printf '   %s[38;5;244mSystem %s[0m %s[1;38;5;120m%s%s[0m\n' "$e" "$e" "$e" "$os" "$e"
[ -n "$up" ] && printf '   %s[38;5;244mUptime %s[0m %s[38;5;222m%s%s[0m\n' "$e" "$e" "$e" "$up" "$e"
printf '   %s[38;5;244mToday  %s[0m %s[38;5;183m%s%s[0m\n' "$e" "$e" "$e" "$now" "$e"
echo
EOF
}
# fresh disk: install the banner and silence the distro's own login messages
guest_banner_fresh() {
  local m f; m="$(g_mnt)"
  if [ ! -d "$m/etc/update-motd.d" ]; then
    mkdir "$m/etc/update-motd.d" && chown "$(g_base):$(g_base)" "$m/etc/update-motd.d"
  fi
  for f in "$m"/etc/update-motd.d/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    # never follow a symlink from the host: remove it instead
    if [ -L "$f" ]; then rm -f "$f"; else chmod a-x "$f"; fi
  done
  banner_script | gwrite etc/update-motd.d/00-erisbox 755
  : | gwrite etc/motd 644
  [ -e "$m/etc/legal" ] && { : | gwrite etc/legal 644; }
  mkdir -p "$VAR_DIR/banner"; echo "$BANNER_VER" > "$VAR_DIR/banner/$G_NAME"
}
# running machine (made by an older version): same thing from inside the machine
guest_banner_live() {
  [ "$(cat "$VAR_DIR/banner/$G_NAME" 2>/dev/null)" = "$BANNER_VER" ] && return 0
  g_running "$G_NAME" || return 0
  banner_script | guest_exec "$G_NAME" sh -c '
    mkdir -p /etc/update-motd.d && cat > /etc/update-motd.d/00-erisbox.new || exit 1
    for f in /etc/update-motd.d/*; do
      case "$f" in */00-erisbox*) continue ;; esac
      if [ -L "$f" ]; then rm -f "$f"; elif [ -e "$f" ]; then chmod a-x "$f"; fi
    done
    chmod 755 /etc/update-motd.d/00-erisbox.new && mv -f /etc/update-motd.d/00-erisbox.new /etc/update-motd.d/00-erisbox
    grep -qs "an Eris Box machine" /etc/motd && : > /etc/motd
    [ -f /etc/legal ] && : > /etc/legal
    exit 0' >/dev/null 2>&1 || return 0
  mkdir -p "$VAR_DIR/banner"; echo "$BANNER_VER" > "$VAR_DIR/banner/$G_NAME"
}

guest_cleanup_failed() {
  guest_umount
  rm -f "$(g_img)"
  rmdir "$(g_mnt)" 2>/dev/null
  if [ -f "$LXC_DIR/$G_NAME/config" ] && grep -q "^$LXC_MARK" "$LXC_DIR/$G_NAME/config"; then rm -rf "${LXC_DIR:?}/$G_NAME"; fi
  rm -f "$(g_conf "$G_NAME")" "$TRAFFIC_DIR/$G_NAME" "$TRAFFIC_DIR/$G_NAME.lock"
}

disk_resize() { # new size in bytes, for the loaded machine
  local img mnt cur new dev minb
  img="$(g_img)"; mnt="$(g_mnt)"; new="$1"
  cur=$(stat -c %s "$img") || return 1
  if [ "$new" -gt "$cur" ]; then
    [ "$(disk_free "$DISK_DIR")" -gt $((new - cur + 268435456)) ] || die "not enough free disk on the server to grow to $(human "$new")"
    fallocate -l "$new" "$img" 2>/dev/null || truncate -s "$new" "$img" || die "could not grow $img"
    if mountpoint -q "$mnt"; then
      dev="$(losetup -j "$img" | head -1 | cut -d: -f1)"
      [ -n "$dev" ] || die "loop device of $img not found"
      losetup -c "$dev" && resize2fs "$dev" >/dev/null 2>&1 || die "online resize failed"
    else
      e2fsck -fp "$img" >/dev/null 2>&1
      resize2fs "$img" >/dev/null 2>&1 || die "resize failed"
    fi
    ok "disk of $G_NAME is now $(human "$new")"
  elif [ "$new" -lt "$cur" ]; then
    g_running "$G_NAME" && die "stop the machine first to make its disk smaller (erisbox stop $G_NAME)"
    guest_umount || die "cannot unmount $mnt"
    e2fsck -fy "$img" >/dev/null 2>&1
    minb=$(resize2fs -P "$img" 2>/dev/null | awk -F: '/minimum size/{gsub(/ /,"",$2); print $2}')
    [ -n "$minb" ] && [ $((minb * 4096 * 11 / 10)) -lt "$new" ] || die "the files on $G_NAME need more space than $(human "$new")"
    resize2fs "$img" "$((new / 1024))K" >/dev/null 2>&1 || die "shrink failed"
    truncate -s "$new" "$img"
    ok "disk of $G_NAME is now $(human "$new")"
  fi
}

# ================================================================ LXC CONF ===
io_dev() { # MAJ:MIN of the block device that stores the disk images
  local src pk d
  src="$(findmnt -no SOURCE -T "$DISK_DIR" 2>/dev/null | head -1)"
  src="${src%%\[*}"
  [ -b "$src" ] || return 1
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 | tr -d ' ')"
  if [ -n "$pk" ] && [ "$(lsblk -dno TYPE "$src" | tr -d ' ')" = part ]; then d="/dev/$pk"; else d="$src"; fi
  lsblk -dno MAJ:MIN "$d" 2>/dev/null | tr -d ' '
}
io_value() { # "MAJ:MIN rbps=.. wbps=.. riops=.. wiops=.." for the loaded machine
  local dev bps="max" iops="max"
  dev="$(io_dev)" || return 1
  [ -n "$dev" ] || return 1
  [ "${G_IO_MBPS:-0}" -gt 0 ] && bps=$((G_IO_MBPS * 1048576))
  [ "${G_IO_IOPS:-0}" -gt 0 ] && iops=$G_IO_IOPS
  echo "$dev rbps=$bps wbps=$bps riops=$iops wiops=$iops"
}

# soft limit at 90% of RAM: the kernel starts pushing the machine into swap before the hard limit
mem_high() { echo $(( $(to_bytes "$G_RAM") / 10 * 9 )); }

lxc_write_config() {
  local d="$LXC_DIR/$G_NAME" b wan mtu iov
  b="$(g_base)"; wan="$(wan_if)"
  mtu="$(cat "/sys/class/net/${wan:-lo}/mtu" 2>/dev/null)"
  mkdir -p "$d" "$LOG_DIR"; chmod 711 "$d"
  [ "$(stat -c %a "$LXC_DIR")" = 711 ] || chmod 711 "$LXC_DIR"
  {
    echo "$LXC_MARK - generated by Eris Box, do not edit (use: erisbox set $G_NAME ...)"
    echo "lxc.include = /usr/share/lxc/config/common.conf"
    echo "lxc.include = /usr/share/lxc/config/userns.conf"
    echo "lxc.arch = $(uname -m)"
    echo "lxc.uts.name = $G_NAME"
    echo "lxc.rootfs.path = dir:$(g_mnt)"
    echo "lxc.idmap = u 0 $b 65536"
    echo "lxc.idmap = g 0 $b 65536"
    echo "lxc.apparmor.profile = generated"
    echo "lxc.apparmor.allow_nesting = 0"
    echo "lxc.net.0.type = veth"
    echo "lxc.net.0.link = $S_BRIDGE"
    echo "lxc.net.0.veth.pair = $(g_veth)"
    echo "lxc.net.0.name = eth0"
    echo "lxc.net.0.hwaddr = $(g_mac)"
    echo "lxc.net.0.flags = up"
    if [ -n "$mtu" ] && [ "$mtu" -ge 1280 ] && [ "$mtu" -lt 1500 ]; then echo "lxc.net.0.mtu = $mtu"; fi
    echo "lxc.net.0.ipv4.address = $(g_ip)/16"
    [ "$(ips_count)" -ge 2 ] && echo "lxc.net.0.ipv4.address = $(g_ip2)/16"
    echo "lxc.net.0.ipv4.gateway = $(gw_ip)"
    echo "lxc.net.0.script.up = $LIB_DIR/hook-netup"
    echo "lxc.net.0.script.down = $LIB_DIR/hook-netdown"
    echo "lxc.hook.pre-start = $LIB_DIR/hook-prestart"
    echo "lxc.hook.post-stop = $LIB_DIR/hook-poststop"
    echo "lxc.cgroup2.cpu.max = $(cpu_quota "$G_CPU") 100000"
    echo "lxc.cgroup2.memory.max = $(to_bytes "$G_RAM")"
    echo "lxc.cgroup2.memory.high = $(mem_high)"
    cg_supports memory.swap.max && echo "lxc.cgroup2.memory.swap.max = $(to_bytes "$G_SWAP")"
    echo "lxc.cgroup2.pids.max = $G_PIDS"
    if [ "${G_IO_MBPS:-0}" -gt 0 ] || [ "${G_IO_IOPS:-0}" -gt 0 ]; then
      iov="$(io_value)" && echo "lxc.cgroup2.io.max = $iov"
    fi
    if [ "$G_TUN" = 1 ]; then
      echo "lxc.cgroup2.devices.allow = c 10:200 rwm"
      echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file 0 0"
    fi
    echo "lxc.start.auto = $(autostart_value)"
    echo "lxc.start.delay = 1"
    echo "lxc.log.file = $LOG_DIR/$G_NAME.log"
    echo "lxc.log.level = WARN"
  } > "$d/config.tmp" && mv -f "$d/config.tmp" "$d/config"
}

guest_start() {
  local n="$G_NAME"
  if g_running "$n"; then info "$n is already running"; return 0; fi
  # mount the disk here: LXC hooks run under lxc-start's AppArmor profile, which forbids loop mounts
  guest_mount || return 1
  ip link del "$(g_veth)" >/dev/null 2>&1
  # the LXC monitor lives as long as the machine: never let it inherit our lock or output pipes
  if ! lxc-start -n "$n" -l WARN -o "$LOG_DIR/$n.log" </dev/null >/dev/null 2>&1 8>&- 9>&-; then
    err "could not start $n - log: $LOG_DIR/$n.log"
    tail -n 15 "$LOG_DIR/$n.log" >&2 2>/dev/null
    return 1
  fi
  lxc-wait -n "$n" -s RUNNING -t 30 >/dev/null 2>&1 || { err "$n did not reach RUNNING"; return 1; }
  tc_apply
  guest_banner_live   # machines made by Eris Box 1.0 get the new login banner once
  log "started $n"
  ok "$n is running"
}
guest_stop() { # [timeout]
  local n="$G_NAME"
  g_running "$n" || return 0
  lxc-stop -n "$n" -t "${1:-30}" >/dev/null 2>&1 || lxc-stop -n "$n" -k >/dev/null 2>&1
  log "stopped $n"
  ok "$n stopped"
}
apply_live_limits() {
  local iov
  g_running "$G_NAME" || return 0
  lxc-cgroup -n "$G_NAME" cpu.max "$(cpu_quota "$G_CPU") 100000" || warn "could not change CPU live"
  # raise or lower in a safe order: high must never end up above max
  lxc-cgroup -n "$G_NAME" memory.high max >/dev/null 2>&1
  lxc-cgroup -n "$G_NAME" memory.max "$(to_bytes "$G_RAM")" || warn "could not change RAM live"
  lxc-cgroup -n "$G_NAME" memory.high "$(mem_high)" >/dev/null 2>&1
  if cg_supports memory.swap.max; then
    lxc-cgroup -n "$G_NAME" memory.swap.max "$(to_bytes "$G_SWAP")" || warn "could not change swap live"
  fi
  lxc-cgroup -n "$G_NAME" pids.max "$G_PIDS" || warn "could not change the process limit live"
  if iov="$(io_value)"; then lxc-cgroup -n "$G_NAME" io.max "$iov" >/dev/null 2>&1; fi
  tc_apply
}

# ================================================================ NETWORK ===
bridge_up() {
  local br="$S_BRIDGE"
  if ! ip link show dev "$br" >/dev/null 2>&1; then
    ip link add name "$br" type bridge forward_delay 0 stp_state 0 || { err "cannot create bridge $br"; return 1; }
  fi
  [ -w "/proc/sys/net/ipv6/conf/$br/disable_ipv6" ] && echo 1 > "/proc/sys/net/ipv6/conf/$br/disable_ipv6"
  ip addr replace "$(gw_ip)/16" dev "$br" || return 1
  ip link set dev "$br" up
}

net_apply() { # bridge + dedicated IP routing + nftables + iptables compat + speed limits
  local keep="$G_NAME" wan rc=0
  wan="$(wan_if)"
  [ -n "$wan" ] || warn "no default route found - is the network up?"
  sysctl -qw net.ipv4.ip_forward=1 >/dev/null 2>&1
  bridge_up || return 1
  ips_apply "$wan"
  nft_apply "$wan" || rc=1
  ipt_compat
  tc_all
  if [ -n "$keep" ] && g_exists "$keep"; then g_load "$keep"; fi
  return "$rc"
}

rp_loose() {
  local f="/proc/sys/net/ipv4/conf/$1/rp_filter"
  [ -w "$f" ] && [ "$(cat "$f")" = 1 ] && echo 2 > "$f"
  if [ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)" = 1 ]; then
    echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter
    warn "set net.ipv4.conf.all.rp_filter=2 (loose) so dedicated IPs on $1 work"
  fi
}

ips_apply() { # addresses + policy routing for dedicated IPs on extra network cards
  local wan="$1" n pub loc ifc gw added idx tbl seen=" "
  while ip rule del pref "$RULE_PREF" 2>/dev/null; do :; done
  for n in $(g_names); do
    g_load "$n"
    while IFS=, read -r pub loc ifc gw added; do
      [ -n "$pub" ] || continue
      if [ ! -e "/sys/class/net/$ifc" ]; then warn "$n: interface $ifc for $pub is missing"; continue; fi
      [ "$added" = 1 ] && ip addr replace "$loc/32" dev "$ifc" 2>/dev/null
      [ "$ifc" = "$wan" ] && continue
      idx=$(cat "/sys/class/net/$ifc/ifindex"); tbl=$((TABLE_BASE + idx))
      if [[ "$seen" != *" $tbl "* ]]; then
        seen+="$tbl "
        ip route flush table "$tbl" 2>/dev/null
        if [ -n "$gw" ]; then
          ip route replace default via "$gw" dev "$ifc" table "$tbl" onlink 2>/dev/null || warn "route via $gw on $ifc failed"
        else
          ip route replace default dev "$ifc" table "$tbl" 2>/dev/null
        fi
        ip route replace "${S_SUBNET}.0.0/16" dev "$S_BRIDGE" table "$tbl" 2>/dev/null
        ip rule add pref "$RULE_PREF" fwmark "$((MARK_BASE + idx))" lookup "$tbl" 2>/dev/null
        rp_loose "$ifc"
      fi
      ip rule add pref "$RULE_PREF" from "$loc" lookup "$tbl" 2>/dev/null
    done < <(ip_entries)
  done
}

ips_ensure() { # cheap self-repair used by the 5-minute timer
  local n pub loc ifc added need=0
  for n in $(g_names); do
    g_load "$n"
    while IFS=, read -r pub loc ifc _ added; do
      [ -n "$pub" ] || continue
      [ "$added" = 1 ] && [ -e "/sys/class/net/$ifc" ] && ip addr replace "$loc/32" dev "$ifc" 2>/dev/null
      [ "$ifc" != "$(wan_if)" ] && need=1
    done < <(ip_entries)
  done
  if [ "$need" = 1 ] && ! ip rule show | grep -q "^${RULE_PREF}:"; then ips_apply "$(wan_if)"; fi
}

nft_render() {
  local wan="$1" br="$S_BRIDGE" sub="${S_SUBNET}.0.0/16" n e pub loc ifc i priv ip ip2 mark pr veth
  local dn="" pt="" sn="" mk="" mkd="" brl="" po
  for n in $(g_names); do
    g_load "$n"
    ip="$(g_ip)"; ip2="$(g_ip2)"; veth="$(g_veth)"
    brl+="    iifname \"$veth\" ether saddr != $(g_mac) drop"$'\n'
    brl+="    iifname \"$veth\" arp saddr ip != { $ip, $ip2, 0.0.0.0 } drop"$'\n'
    brl+="    iifname \"$veth\" ip saddr != { $ip, $ip2 } drop"$'\n'
    i=0
    while IFS=, read -r pub loc ifc _ _; do
      [ -n "$pub" ] || continue
      i=$((i + 1))
      if [ "$i" = 1 ]; then priv="$ip"; else priv="$ip2"; fi
      dn+="    ip daddr $loc dnat to $priv"$'\n'
      sn+="    oifname != \"$br\" ip saddr $priv snat to $loc"$'\n'
      if [ "$ifc" != "$wan" ] && [ -r "/sys/class/net/$ifc/ifindex" ]; then
        mark=$((MARK_BASE + $(cat "/sys/class/net/$ifc/ifindex")))
        mk+="    iifname \"$br\" ip saddr $priv meta mark set $mark"$'\n'
        mkd+="    ct original ip daddr $loc meta mark set $mark"$'\n'
      fi
    done < <(ip_entries)
    [ -n "$G_SSH_PORT" ] && pt+="    fib daddr type local tcp dport $G_SSH_PORT dnat to $ip:22"$'\n'
    for e in $G_PORTS; do
      port_entry_parse "$e"
      for pr in tcp udp; do
        [ "$P_PROTO" = both ] || [ "$P_PROTO" = "$pr" ] || continue
        if [ "$P_HS" = "$P_HE" ]; then
          pt+="    fib daddr type local $pr dport $P_HS dnat to $ip:$P_GS"$'\n'
        else
          pt+="    fib daddr type local $pr dport $P_HS-$P_HE dnat to $ip"$'\n'
        fi
      done
    done
  done
  po="${pt//fib daddr type local/ip daddr != 127.0.0.0/8 fib daddr type local}"
  cat <<EOF
# Eris Box firewall and NAT rules - generated by "erisbox apply", do not edit
table inet erisbox
delete table inet erisbox
table ip erisbox_nat
delete table ip erisbox_nat
table bridge erisbox_br
delete table bridge erisbox_br

table inet erisbox {
  chain guest_input {
    type filter hook input priority -5; policy accept;
    iifname "$br" ct state established,related accept
    iifname "$br" icmp type { echo-request, destination-unreachable, time-exceeded } accept
$( [ "$S_PROXY_ENABLED" = 1 ] && printf '    iifname "%s" tcp dport { 80, 443 } accept' "$br" )
    iifname "$br" drop
  }
  chain guest_forward {
    type filter hook forward priority -5; policy accept;
    iifname "$br" oifname "$br" ct status dnat accept
    iifname "$br" oifname "$br" drop
EOF
  [ "$S_BLOCK_SMTP" = 1 ] && echo "    iifname \"$br\" tcp dport 25 drop"
  [ "$S_BLOCK_PRIVATE" = 1 ] && echo "    iifname \"$br\" ct state new ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } drop"
  cat <<EOF
    iifname "$br" accept
    oifname "$br" ct state established,related accept
    oifname "$br" ct status dnat accept
    oifname "$br" drop
  }
  chain mangle_pre {
    type filter hook prerouting priority -150; policy accept;
    iifname "$br" ct status dnat goto dnat_reply
${mk}  }
  chain dnat_reply {
${mkd}  }
}

table ip erisbox_nat {
  chain nat_pre {
    type nat hook prerouting priority -105; policy accept;
${dn}${pt}  }
  chain nat_out {
    type nat hook output priority -105; policy accept;
${dn}${po}  }
  chain nat_post {
    type nat hook postrouting priority 95; policy accept;
${sn}    oifname "$br" ip saddr $sub ct status dnat masquerade
    oifname != "$br" ip saddr $sub masquerade
  }
}

table bridge erisbox_br {
  chain br_ingress {
    type filter hook prerouting priority -200; policy accept;
${brl}    iifname "ebx*" ether type != { ip, arp } drop
  }
  chain br_forward {
    type filter hook forward priority -200; policy accept;
    iifname "ebx*" oifname "ebx*" drop
  }
}
EOF
}

nft_apply() {
  local tmp
  mkdir -p "$VAR_DIR"
  tmp="$(mktemp "$VAR_DIR/rules.XXXXXX")"
  nft_render "$1" > "$tmp"
  if nft -f "$tmp" 2>"$tmp.err"; then
    mv -f "$tmp" "$NFT_FILE"; rm -f "$tmp.err"; return 0
  fi
  err "nftables rejected the generated rules (saved in $NFT_FILE.failed):"
  cat "$tmp.err" >&2
  mv -f "$tmp" "$NFT_FILE.failed"; rm -f "$tmp.err"
  return 1
}

ipt_compat() { # let ufw / docker style iptables FORWARD policies pass our bridge
  command -v iptables >/dev/null 2>&1 || return 0
  local ch d
  for ch in FORWARD DOCKER-USER; do
    iptables -w -n -L "$ch" >/dev/null 2>&1 || continue
    for d in -i -o; do
      iptables -w -C "$ch" "$d" "$S_BRIDGE" -j ACCEPT 2>/dev/null \
        || iptables -w -I "$ch" 1 "$d" "$S_BRIDGE" -j ACCEPT 2>/dev/null
    done
  done
}
ipt_remove() {
  command -v iptables >/dev/null 2>&1 || return 0
  local ch d
  for ch in FORWARD DOCKER-USER; do
    for d in -i -o; do
      while iptables -w -D "$ch" "$d" "$S_BRIDGE" -j ACCEPT 2>/dev/null; do :; done
    done
  done
}

tc_apply() { # speed limit of the loaded machine (both directions)
  local dev rate burst
  dev="$(g_veth)"
  [ -d "/sys/class/net/$dev" ] || return 0
  rate="${G_SPEED:-0}"
  [ "$G_NOTE" = overquota ] && [ "$S_QUOTA_ACTION" = throttle ] && rate=1
  tc qdisc del dev "$dev" root >/dev/null 2>&1
  tc qdisc del dev "$dev" ingress >/dev/null 2>&1
  [ "$rate" -gt 0 ] 2>/dev/null || return 0
  burst=$(( rate * 1000000 / 8 / 100 )); [ "$burst" -lt 16000 ] && burst=16000
  tc qdisc add dev "$dev" root tbf rate "${rate}mbit" burst "$burst" latency 200ms \
    || warn "download speed limit failed for $G_NAME"
  tc qdisc add dev "$dev" handle ffff: ingress \
    && tc filter add dev "$dev" parent ffff: prio 1 matchall action police rate "${rate}mbit" burst "$burst" conform-exceed drop/ok \
    || warn "upload speed limit failed for $G_NAME"
}
tc_all() {
  local keep="$G_NAME" n
  for n in $(g_names); do g_load "$n"; g_running "$n" && tc_apply; done
  if [ -n "$keep" ] && g_exists "$keep"; then g_load "$keep"; fi
}

# ================================================================== PORTS ===
# PORTS entries look like  proto:first-last:guestfirst   (proto = tcp | udp | both)
port_entry_parse() {
  local r
  IFS=: read -r P_PROTO r P_GS <<<"$1"
  P_HS="${r%-*}"; P_HE="${r#*-}"
}
port_entry_text() {
  port_entry_parse "$1"
  local p="$P_PROTO"; [ "$p" = both ] && p="tcp+udp"
  if [ "$P_HS" = "$P_HE" ]; then
    if [ "$P_GS" = "$P_HS" ]; then printf '%s (%s)' "$P_HS" "$p"; else printf '%s -> machine port %s (%s)' "$P_HS" "$P_GS" "$p"; fi
  else
    printf '%s-%s (%s, same numbers inside)' "$P_HS" "$P_HE" "$p"
  fi
}
build_port_map() { # [machine to ignore] -> PMAP[proto:port]=owner
  declare -gA PMAP=()
  local p n e sp ports x
  while read -r p; do [ -n "$p" ] && PMAP["tcp:$p"]="this server"; done < <(ss -Hlnt 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}')
  while read -r p; do [ -n "$p" ] && PMAP["udp:$p"]="this server"; done < <(ss -Hlnu 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}')
  if [ "$S_PROXY_ENABLED" = 1 ]; then PMAP[tcp:80]="domain proxy"; PMAP[tcp:443]="domain proxy"; fi
  for n in $(g_names); do
    [ "$n" = "${1:-}" ] && continue
    sp="$(kv_get "$(g_conf "$n")" SSH_PORT)"; ports="$(kv_get "$(g_conf "$n")" PORTS)"
    [ -n "$sp" ] && PMAP["tcp:$sp"]="$n"
    for e in $ports; do
      port_entry_parse "$e"
      for ((x = P_HS; x <= P_HE; x++)); do
        [ "$P_PROTO" = udp ] || PMAP["tcp:$x"]="$n"
        [ "$P_PROTO" = tcp ] || PMAP["udp:$x"]="$n"
      done
    done
  done
}
port_free() { # proto first last
  local x
  for ((x = $2; x <= $3; x++)); do
    if [ "$1" != udp ] && [ -n "${PMAP[tcp:$x]-}" ]; then PORT_OWNER="${PMAP[tcp:$x]} (tcp $x)"; return 1; fi
    if [ "$1" != tcp ] && [ -n "${PMAP[udp:$x]-}" ]; then PORT_OWNER="${PMAP[udp:$x]} (udp $x)"; return 1; fi
  done
  return 0
}
port_take() { # proto first last owner
  local x
  for ((x = $2; x <= $3; x++)); do
    [ "$1" = udp ] || PMAP["tcp:$x"]="$4"
    [ "$1" = tcp ] || PMAP["udp:$x"]="$4"
  done
}
alloc_ssh_port() {
  local p=$S_SSH_PORT_START
  while [ "$p" -le 65000 ]; do port_free tcp "$p" "$p" && { echo "$p"; return 0; }; p=$((p + 1)); done
  return 1
}
alloc_range() { # count -> first port of a free block (tcp+udp)
  local n="$1" s=$S_PORT_RANGE_START
  while [ $((s + n - 1)) -le 65535 ]; do
    port_free both "$s" $((s + n - 1)) && { echo "$s"; return 0; }
    s=$((s + n))
  done
  return 1
}
port_spec() { # "N" | "N-M" | "N:G" -> P_HS P_HE P_GS
  if [[ "$1" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    P_HS=$((10#${BASH_REMATCH[1]})); P_HE=$((10#${BASH_REMATCH[2]})); P_GS=$P_HS
  elif [[ "$1" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
    P_HS=$((10#${BASH_REMATCH[1]})); P_HE=$P_HS; P_GS=$((10#${BASH_REMATCH[2]}))
  elif [[ "$1" =~ ^[0-9]{1,5}$ ]]; then
    P_HS=$((10#$1)); P_HE=$P_HS; P_GS=$P_HS
  else
    return 1
  fi
  valid_port "$P_HS" && valid_port "$P_HE" && valid_port "$P_GS" && [ "$P_HE" -ge "$P_HS" ] && [ $((P_HE - P_HS)) -lt 1000 ]
}

# ================================================================ TRAFFIC ===
traffic_file() { printf '%s/%s' "$TRAFFIC_DIR" "$G_NAME"; }
traffic_read() {
  T_RX=0; T_TX=0; T_RXL=0; T_TXL=0
  local f; f="$(traffic_file)"
  [ -f "$f" ] && read -r T_RX T_TX T_RXL T_TXL < "$f"
  T_RX=${T_RX:-0}; T_TX=${T_TX:-0}; T_RXL=${T_RXL:-0}; T_TXL=${T_TXL:-0}
}
traffic_write() {
  mkdir -p "$TRAFFIC_DIR"
  printf '%s %s %s %s\n' "$T_RX" "$T_TX" "$T_RXL" "$T_TXL" > "$(traffic_file).tmp" && mv -f "$(traffic_file).tmp" "$(traffic_file)"
}
traffic_account() { # [down]   host-side veth: rx = machine upload, tx = machine download
  local dev rx tx
  dev="$(g_veth)"
  mkdir -p "$TRAFFIC_DIR"
  (
    flock -w 10 9 || exit 0
    traffic_read
    if [ -r "/sys/class/net/$dev/statistics/rx_bytes" ]; then
      rx=$(cat "/sys/class/net/$dev/statistics/rx_bytes"); tx=$(cat "/sys/class/net/$dev/statistics/tx_bytes")
      if [ "$rx" -ge "$T_RXL" ]; then T_RX=$((T_RX + rx - T_RXL)); else T_RX=$((T_RX + rx)); fi
      if [ "$tx" -ge "$T_TXL" ]; then T_TX=$((T_TX + tx - T_TXL)); else T_TX=$((T_TX + tx)); fi
      T_RXL=$rx; T_TXL=$tx
    else
      T_RXL=0; T_TXL=0
    fi
    [ "${1:-}" = down ] && { T_RXL=0; T_TXL=0; }
    traffic_write
  ) 9>>"$(traffic_file).lock"
}
traffic_total() { traffic_read; echo $((T_RX + T_TX)); }
traffic_reset() {
  mkdir -p "$TRAFFIC_DIR"
  ( flock -w 10 9 || exit 0; traffic_read; T_RX=0; T_TX=0; traffic_write ) 9>>"$(traffic_file).lock"
}
traffic_text() {
  traffic_read
  local t=$((T_RX + T_TX)) s
  s="$(human "$t") (down $(human "$T_TX") / up $(human "$T_RX"))"
  if [ "${G_TRAFFIC_GB:-0}" != 0 ]; then s+=" of ${G_TRAFFIC_GB}G"; fi
  printf '%s' "$s"
}

# ======================================================= DEDICATED IPv4 ===
iface_of() { ip -4 -o addr show 2>/dev/null | awk -v ip="$1" '{split($4,a,"/"); if (a[1]==ip) {print $2; exit}}'; }
iface_addrs() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'; }
secondary_ifaces() { # physical-looking network cards other than the main one
  local p n
  for p in /sys/class/net/*; do
    n="${p##*/}"
    case "$n" in
      lo|"$1"|"$S_BRIDGE"|ebx*|veth*|docker*|br-*|virbr*|lxcbr*|lxdbr*|incusbr*|wg*|tun*|tap*|tailscale*|zt*|cni*|flannel*|cali*|kube*|dummy*) continue ;;
    esac
    [ -e "$p/device" ] && echo "$n"
  done
}
iface_gw() {
  local ifc="$1" gw idx cidr nn mm
  gw=$(ip -4 route show default dev "$ifc" 2>/dev/null | awk '/via/{print $3; exit}')
  [ -z "$gw" ] && gw=$(ip -4 route show table all default dev "$ifc" 2>/dev/null | awk '/via/{print $3; exit}')
  if [ -z "$gw" ]; then
    idx=$(cat "/sys/class/net/$ifc/ifindex" 2>/dev/null)
    [ -f "/run/systemd/netif/leases/$idx" ] && gw=$(awk -F= '$1=="ROUTER"{split($2,a," "); print a[1]; exit}' "/run/systemd/netif/leases/$idx")
  fi
  if [ -z "$gw" ]; then # guess: first address of the card's subnet
    cidr=$(ip -4 -o addr show dev "$ifc" scope global 2>/dev/null | awk '{print $4; exit}')
    if [ -n "$cidr" ] && [ "${cidr#*/}" -lt 31 ]; then
      nn=$(ip2int "${cidr%/*}"); mm=$(( (0xffffffff << (32 - ${cidr#*/})) & 0xffffffff ))
      gw=$(int2ip $(( (nn & mm) + 1 )))
    fi
  fi
  echo "$gw"
}
iface_dhcp() { # bring up an unconfigured network card with DHCP (netplan)
  local ifc="$1" f="/etc/netplan/60-erisbox-$1.yaml" i
  command -v netplan >/dev/null 2>&1 || { warn "netplan not found - configure $ifc yourself"; return 1; }
  cat > "$f" <<EOF
# Eris Box: extra network card for dedicated IPs
network:
  version: 2
  ethernets:
    $ifc:
      dhcp4: true
      dhcp6: false
      optional: true
      dhcp4-overrides:
        use-routes: false
        use-dns: false
EOF
  chmod 600 "$f"
  netplan apply >/dev/null 2>&1 || { warn "netplan apply failed"; return 1; }
  for i in $(seq 1 20); do [ -n "$(iface_addrs "$ifc")" ] && return 0; sleep 1; done
  warn "$ifc did not get an address by DHCP"
  return 1
}
addr_in_use() { # local address already used by a machine?
  local n
  for n in $(g_names); do
    kv_get "$(g_conf "$n")" IPS | tr ';' '\n' | awk -F, -v ip="$1" '$1==ip || $2==ip {f=1} END{exit !f}' && return 0
  done
  return 1
}
ip_test() { curl -4 -fsS --max-time 8 --interface "$1" https://api.ipify.org 2>/dev/null | tr -d ' \r\n'; }

ip_locate() { # public IP -> L_LOCAL L_IFACE L_GW L_ADDED
  local pub="$1" wan ifc a gw seen cands
  L_LOCAL=""; L_IFACE=""; L_GW=""; L_ADDED=0
  wan="$(wan_if)"
  ifc="$(iface_of "$pub")"
  if [ -n "$ifc" ]; then # 1) the IP is already on a network card
    L_LOCAL="$pub"; L_IFACE="$ifc"
    [ "$ifc" != "$wan" ] && L_GW="$(iface_gw "$ifc")"
    return 0
  fi
  cands="$(secondary_ifaces "$wan")"
  for ifc in $cands; do # 2) a new network card without an address -> DHCP
    if [ -z "$(iface_addrs "$ifc")" ]; then
      if confirm "Network card $ifc has no IPv4 address. Configure it with DHCP now?" y; then
        info "Configuring $ifc with DHCP ..."
        iface_dhcp "$ifc"
      fi
    fi
  done
  for ifc in $cands; do
    for a in $(iface_addrs "$ifc"); do
      if [ "$a" = "$pub" ]; then L_LOCAL="$a"; L_IFACE="$ifc"; L_GW="$(iface_gw "$ifc")"; return 0; fi
      addr_in_use "$a" && continue
      gw="$(iface_gw "$ifc")"
      [ -n "$gw" ] || continue
      # 3) floating IP: the card has a private address that the cloud maps to the public IP
      info "Testing whether $a on $ifc goes out as $pub ..."
      ip route replace default via "$gw" dev "$ifc" table 30999 onlink 2>/dev/null
      ip rule add pref 30998 from "$a" lookup 30999 2>/dev/null
      seen="$(ip_test "$a")"
      ip rule del pref 30998 2>/dev/null; ip route flush table 30999 2>/dev/null
      if [ "$seen" = "$pub" ]; then L_LOCAL="$a"; L_IFACE="$ifc"; L_GW="$gw"; return 0; fi
    done
  done
  # 4) not configured anywhere: a routed extra IP -> add it to the main card
  L_LOCAL="$pub"; L_IFACE="$wan"; L_ADDED=1
}

cmd_ip() {
  local sub="${1:-list}"; [ $# -gt 0 ] && shift
  case "$sub" in
    list|ls) ip_list "$@" ;;
    add) ip_add "$@" ;;
    del|delete|rm|remove) ip_del "$@" ;;
    *) die "usage: erisbox ip list | ip add MACHINE IP | ip del MACHINE IP" ;;
  esac
}
ip_list() {
  need_root; need_installed; s_load
  local n pub loc ifc i any=0
  printf '%s%-16s %-14s %-16s %-10s %s%s\n' "$C_BD" "PUBLIC IP" MACHINE "LOCAL ADDRESS" CARD "MACHINE ADDR" "$C_0"
  for n in $(g_names); do
    g_load "$n"; i=0
    while IFS=, read -r pub loc ifc _ _; do
      [ -n "$pub" ] || continue
      i=$((i + 1)); any=1
      printf '%-16s %-14s %-16s %-10s %s\n' "$pub" "$n" "$loc" "$ifc" "$( [ $i = 1 ] && g_ip || g_ip2 )"
    done < <(ip_entries)
  done
  [ "$any" = 1 ] || echo "  (no dedicated IPs yet - add one with: erisbox ip add MACHINE IP)"
}
ip_rollback() { # remove the last entry again (loaded machine)
  local e="$1" loc ifc added
  IFS=, read -r _ loc ifc _ added <<<"$e"
  G_IPS="${G_IPS%"$e"}"; G_IPS="${G_IPS%;}"
  [ "$added" = 1 ] && ip addr del "$loc/32" dev "$ifc" 2>/dev/null
  g_save; lxc_write_config; net_apply
}
ip_add() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" pub="${POS[1]:-}" n cnt e seen
  [ -n "$name" ] && [ -n "$pub" ] || die "usage: erisbox ip add MACHINE IP [--iface CARD] [--gw GATEWAY] [--local ADDRESS] [--force]"
  g_exists "$name" || die "machine '$name' not found"
  valid_ipv4 "$pub" || die "'$pub' is not an IPv4 address"
  take_lock
  g_load "$name"
  cnt="$(ips_count)"
  [ "$cnt" -lt "$MAX_IPS" ] || die "$name already has $MAX_IPS dedicated IPs (the maximum)"
  for n in $(g_names); do
    if kv_get "$(g_conf "$n")" IPS | tr ';' '\n' | awk -F, -v ip="$pub" '$1==ip || $2==ip {f=1} END{exit !f}'; then
      die "$pub is already used by machine $n"
    fi
  done
  if [ "$pub" = "$(public_ip)" ] || [ "$pub" = "$(wan_src)" ]; then die "$pub is this server's main IP - use an extra IP"; fi

  if has_flag local; then
    L_LOCAL="$(flag local)"; valid_ipv4 "$L_LOCAL" || die "invalid --local address"
    L_IFACE="$(flag iface "$(iface_of "$L_LOCAL")")"
    [ -n "$L_IFACE" ] || die "$L_LOCAL is not on any network card (add --iface CARD)"
    L_ADDED=0; [ -z "$(iface_of "$L_LOCAL")" ] && L_ADDED=1
    L_GW=""; [ "$L_IFACE" != "$(wan_if)" ] && L_GW="$(iface_gw "$L_IFACE")"
  else
    ip_locate "$pub"
    if has_flag iface; then
      L_IFACE="$(flag iface)"; [ "$L_IFACE" != "$(wan_if)" ] && L_GW="$(iface_gw "$L_IFACE")"
    fi
  fi
  has_flag gw && L_GW="$(flag gw)"
  valid_iface "$L_IFACE" && [ -e "/sys/class/net/$L_IFACE" ] || die "network card '$L_IFACE' does not exist"
  [ -z "$L_GW" ] || valid_ipv4 "$L_GW" || die "invalid gateway '$L_GW'"
  if [ "$L_ADDED" = 1 ]; then
    info "$pub is not configured on this server - adding it to $L_IFACE"
  else
    info "found $pub: local address $L_LOCAL on $L_IFACE${L_GW:+ (gateway $L_GW)}"
  fi

  e="$pub,$L_LOCAL,$L_IFACE,$L_GW,$L_ADDED"
  if [ -n "$G_IPS" ]; then G_IPS="$G_IPS;$e"; else G_IPS="$e"; fi
  g_save; lxc_write_config
  if ! net_apply; then ip_rollback "$e"; die "could not set up $pub"; fi
  if [ "$((cnt + 1))" -ge 2 ] && g_running "$name"; then
    nsenter -t "$(g_pid "$name")" -n ip addr replace "$(g_ip2)/16" dev eth0 2>/dev/null
  fi

  seen="$(ip_test "$L_LOCAL")"
  if [ "$seen" = "$pub" ]; then
    ok "check: traffic from this IP really leaves the server as $pub"
  else
    warn "check: traffic from $L_LOCAL leaves as '${seen:-no answer}', expected $pub"
    if ! has_flag force && ! confirm "Your provider may not have attached $pub to this server yet. Keep it anyway?" n; then
      ip_rollback "$e"
      die "removed $pub again - attach it to this server in your provider's panel, then try again"
    fi
  fi
  if g_running "$name" && [ "$cnt" = 0 ]; then
    seen="$(guest_exec "$name" curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null)"
    info "machine $name now reaches the internet as: ${seen:-unknown}"
  fi
  log "ip add $pub -> $name ($L_LOCAL on $L_IFACE)"
  ok "dedicated IP $pub -> $name (all ports, inbound and outbound)"
  if [ "$((cnt + 1))" -ge 2 ]; then
    info "inside $name, programs that bind to $(g_ip2) use $pub; everything else uses the first IP"
  fi
}
ip_del() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" pub="${POS[1]:-}" e found="" new="" loc ifc added
  [ -n "$name" ] && [ -n "$pub" ] || die "usage: erisbox ip del MACHINE IP"
  take_lock
  g_load "$name"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if [ "${e%%,*}" = "$pub" ]; then found="$e"; else new="${new:+$new;}$e"; fi
  done < <(ip_entries)
  [ -n "$found" ] || die "$name has no dedicated IP $pub"
  IFS=, read -r _ loc ifc _ added <<<"$found"
  [ "$added" = 1 ] && ip addr del "$loc/32" dev "$ifc" 2>/dev/null
  G_IPS="$new"
  g_save; lxc_write_config; net_apply
  if [ "$(ips_count)" -lt 2 ] && g_running "$name"; then
    nsenter -t "$(g_pid "$name")" -n ip addr del "$(g_ip2)/16" dev eth0 2>/dev/null
  fi
  log "ip del $pub from $name"
  ok "removed $pub from $name"
}

# =========================================================== DOMAIN PROXY ===
proxy_render() {
  [ "$S_PROXY_ENABLED" = 1 ] || return 0
  local d n w ip v6=0 htmp stmp
  [ -f /proc/net/if_inet6 ] && v6=1
  htmp="$(mktemp)"; stmp="$(mktemp)"
  {
    echo "# Eris Box domain proxy (HTTP) - generated, do not edit"
    echo 'map $http_upgrade $erisbox_conn { default upgrade; "" close; }'
    echo 'map $host $erisbox_http {'
    echo '    hostnames;'
    if [ -n "$S_PROXY_DEFAULT_HTTP" ]; then echo "    default $S_PROXY_DEFAULT_HTTP;"; else echo '    default "";'; fi
    while read -r d n w; do
      [ -n "$d" ] && g_exists "$n" || continue
      ip="$(guest_ip_of "$n")"
      if [ "$w" = 1 ]; then echo "    .$d $ip:80;"; else echo "    $d $ip:80;"; fi
    done < "$DOMAIN_FILE"
    echo '}'
    echo 'server {'
    echo '    listen 80 default_server;'
    [ "$v6" = 1 ] && echo '    listen [::]:80 default_server;'
    echo '    server_name _;'
    echo '    client_max_body_size 200m;'
    echo '    if ($erisbox_http = "") { return 404; }'
    echo '    location / {'
    echo '        proxy_pass http://$erisbox_http;'
    echo '        proxy_http_version 1.1;'
    echo '        proxy_set_header Host $host;'
    echo '        proxy_set_header X-Real-IP $remote_addr;'
    echo '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
    echo '        proxy_set_header X-Forwarded-Proto $scheme;'
    echo '        proxy_set_header Upgrade $http_upgrade;'
    echo '        proxy_set_header Connection $erisbox_conn;'
    echo '        proxy_read_timeout 600s;'
    echo '    }'
    echo '}'
  } > "$htmp"
  {
    echo "# Eris Box domain proxy (TLS passthrough by SNI) - generated, do not edit"
    echo 'stream {'
    echo '    map $ssl_preread_server_name $erisbox_tls {'
    echo '        hostnames;'
    if [ -n "$S_PROXY_DEFAULT_TLS" ]; then echo "        default $S_PROXY_DEFAULT_TLS;"; else echo '        default 127.0.0.1:9;'; fi
    while read -r d n w; do
      [ -n "$d" ] && g_exists "$n" || continue
      ip="$(guest_ip_of "$n")"
      if [ "$w" = 1 ]; then echo "        .$d $ip:443;"; else echo "        $d $ip:443;"; fi
    done < "$DOMAIN_FILE"
    echo '    }'
    echo '    server {'
    echo '        listen 443;'
    [ "$v6" = 1 ] && echo '        listen [::]:443;'
    echo '        ssl_preread on;'
    echo '        proxy_pass $erisbox_tls;'
    echo '        proxy_connect_timeout 5s;'
    echo '        proxy_timeout 1h;'
    echo '    }'
    echo '}'
  } > "$stmp"
  [ -f "$NGINX_HTTP_CONF" ] && cp -f "$NGINX_HTTP_CONF" "$NGINX_HTTP_CONF.bak"
  [ -f "$NGINX_STREAM_CONF" ] && cp -f "$NGINX_STREAM_CONF" "$NGINX_STREAM_CONF.bak"
  install -m 644 "$htmp" "$NGINX_HTTP_CONF"; install -m 644 "$stmp" "$NGINX_STREAM_CONF"
  rm -f "$htmp" "$stmp"
  grep -qF "include $NGINX_STREAM_CONF;" /etc/nginx/nginx.conf \
    || printf '\n# Eris Box (TLS passthrough by domain name)\ninclude %s;\n' "$NGINX_STREAM_CONF" >> /etc/nginx/nginx.conf
  if ! nginx -t >/dev/null 2>&1; then
    err "nginx rejected the new configuration:"; nginx -t 2>&1 | tail -n 5 >&2
    [ -f "$NGINX_HTTP_CONF.bak" ] && mv -f "$NGINX_HTTP_CONF.bak" "$NGINX_HTTP_CONF"
    [ -f "$NGINX_STREAM_CONF.bak" ] && mv -f "$NGINX_STREAM_CONF.bak" "$NGINX_STREAM_CONF"
    return 1
  fi
  rm -f "$NGINX_HTTP_CONF.bak" "$NGINX_STREAM_CONF.bak"
  systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
}
proxy_enable() {
  local p busy
  [ "$S_PROXY_ENABLED" = 1 ] && { info "the domain proxy is already enabled"; return 0; }
  for p in 80 443; do
    busy="$(ss -Hltnp "sport = :$p" 2>/dev/null | grep -v '"nginx"' | head -1)"
    if [ -n "$busy" ]; then
      die "port $p is already used on this server: ${busy##* } - move that program to another port first (unknown domains can then be sent to it: erisbox domain default-tls 127.0.0.1:NEWPORT)"
    fi
  done
  for p in 80 443; do
    port_free_any_guest "$p" || die "port $p is forwarded to machine $PORT_OWNER - remove that forward first"
  done
  info "Installing nginx ..."
  apt_install nginx libnginx-mod-stream || die "could not install nginx"
  [ -L /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
  S_PROXY_ENABLED=1; s_save
  if ! proxy_render; then S_PROXY_ENABLED=0; s_save; die "domain proxy setup failed"; fi
  systemctl enable --now nginx >/dev/null 2>&1; systemctl reload nginx >/dev/null 2>&1
  net_apply   # machines may now reach ports 80/443 of the host (other machines' sites)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  fi
  log "domain proxy enabled"
  ok "domain proxy enabled on ports 80 and 443 - now add domains: erisbox domain add MACHINE example.com"
}
port_free_any_guest() { # port -> fails if a machine forwards this tcp port
  local n sp e
  for n in $(g_names); do
    sp="$(kv_get "$(g_conf "$n")" SSH_PORT)"
    [ "$sp" = "$1" ] && { PORT_OWNER="$n"; return 1; }
    for e in $(kv_get "$(g_conf "$n")" PORTS); do
      port_entry_parse "$e"
      [ "$P_PROTO" != udp ] && [ "$1" -ge "$P_HS" ] && [ "$1" -le "$P_HE" ] && { PORT_OWNER="$n"; return 1; }
    done
  done
  return 0
}
proxy_disable() {
  [ "$S_PROXY_ENABLED" = 1 ] || { info "the domain proxy is not enabled"; return 0; }
  rm -f "$NGINX_HTTP_CONF" "$NGINX_STREAM_CONF"
  sed -i "\#include $NGINX_STREAM_CONF;#d; /^\# Eris Box (TLS passthrough by domain name)\$/d" /etc/nginx/nginx.conf
  S_PROXY_ENABLED=0; s_save
  systemctl reload nginx >/dev/null 2>&1
  net_apply
  log "domain proxy disabled"
  ok "domain proxy disabled (nginx itself is still installed)"
}
cmd_domain() {
  parse_flags "$@"; need_root; need_installed; s_load
  local sub="${POS[0]:-list}" a="${POS[1]:-}" b="${POS[2]:-}" d n w tmp
  touch "$DOMAIN_FILE"
  case "$sub" in
    list|ls)
      printf '  Domain proxy: %s\n' "$( [ "$S_PROXY_ENABLED" = 1 ] && echo "enabled (ports 80 + 443)" || echo "disabled (enable: erisbox domain enable)")"
      [ -n "$S_PROXY_DEFAULT_HTTP" ] && printf '  Unknown HTTP domains -> %s\n' "$S_PROXY_DEFAULT_HTTP"
      [ -n "$S_PROXY_DEFAULT_TLS" ] && printf '  Unknown TLS domains  -> %s\n' "$S_PROXY_DEFAULT_TLS"
      if [ -s "$DOMAIN_FILE" ]; then
        while read -r d n w; do
          [ -n "$d" ] && printf '  %-40s -> %s%s\n' "$d" "$n" "$( [ "$w" = 1 ] && echo '  (+ all subdomains)')"
        done < "$DOMAIN_FILE"
      else
        echo "  (no domains yet)"
      fi ;;
    enable|on) take_lock; proxy_enable ;;
    disable|off) take_lock; proxy_disable ;;
    add)
      n="$a"; d="${b,,}"
      [ -n "$n" ] && [ -n "$d" ] || die "usage: erisbox domain add MACHINE DOMAIN [--wildcard]"
      [ "$S_PROXY_ENABLED" = 1 ] || die "enable the domain proxy first: erisbox domain enable"
      g_exists "$n" || die "machine '$n' not found"
      d="${d#\*.}"
      valid_domain "$d" || die "'$d' is not a valid domain name"
      take_lock
      awk -v d="$d" '$1==d {f=1} END{exit !f}' "$DOMAIN_FILE" && die "$d is already added"
      w=0; has_flag wildcard && w=1
      echo "$d $n $w" >> "$DOMAIN_FILE"
      if ! proxy_render; then sed -i "/^$(printf '%s' "$d" | sed 's/\./\\./g') /d" "$DOMAIN_FILE"; proxy_render; die "could not add $d"; fi
      log "domain add $d -> $n"
      ok "$d -> $n  (point the domain's DNS A record to $(public_ip); the machine serves ports 80/443 itself)" ;;
    del|delete|rm|remove)
      d="${a,,}"; [ -n "$d" ] || die "usage: erisbox domain del DOMAIN"
      take_lock
      awk -v d="$d" '$1==d {f=1} END{exit !f}' "$DOMAIN_FILE" || die "$d is not in the list"
      tmp="$(mktemp)"; awk -v d="$d" '$1!=d' "$DOMAIN_FILE" > "$tmp" && cat "$tmp" > "$DOMAIN_FILE"; rm -f "$tmp"
      proxy_render
      ok "removed $d" ;;
    default-http|default-tls)
      [ -n "$a" ] || die "usage: erisbox domain $sub HOST:PORT|none"
      [ "$a" = none ] && a=""
      [ -z "$a" ] || valid_hostport "$a" || die "use IP:PORT, for example 127.0.0.1:8443"
      take_lock
      if [ "$sub" = default-http ]; then S_PROXY_DEFAULT_HTTP="$a"; else S_PROXY_DEFAULT_TLS="$a"; fi
      s_save; proxy_render
      ok "unknown domains on $( [ "$sub" = default-http ] && echo 80 || echo 443 ) -> ${a:-rejected}" ;;
    *) die "usage: erisbox domain list|enable|disable|add MACHINE DOMAIN [--wildcard]|del DOMAIN|default-http|default-tls" ;;
  esac
}

# ================================================================ CREATE ===
used_field() { local n; for n in $(g_names); do kv_get "$(g_conf "$n")" "$1"; echo; done; }
alloc_id() {
  local used i
  used=" $(used_field ID | tr '\n' ' ') "
  for ((i = 1; i <= MAX_ID; i++)); do [[ "$used" == *" $i "* ]] || { echo "$i"; return 0; }; done
  return 1
}
alloc_base() { # [preferred]
  local used b i
  used=" $(used_field UIDBASE | tr '\n' ' ') "
  if valid_int "${1:-}" && [ "$1" -ge $((SUBUID_START + 65536)) ] && [ $(($1 + 65536)) -le $((SUBUID_START + SUBUID_COUNT)) ] \
     && [ $(( ($1 - SUBUID_START) % 65536 )) = 0 ] && [[ "$used" != *" $1 "* ]]; then
    echo "$1"; return 0
  fi
  for ((i = 1; i <= MAX_ID; i++)); do
    b=$((SUBUID_START + i * 65536))
    [[ "$used" == *" $b "* ]] || { echo "$b"; return 0; }
  done
  return 1
}

create_wizard() { # fills F[] and W_NAME
  local v i ddef dmax
  W_NAME=""
  printf '\n%sCreate a new machine%s  (press Enter to accept the value in [brackets])\n\n' "$C_BD" "$C_0"
  res_compute; res_show; echo
  while :; do
    ask W_NAME "Name (a-z, 0-9 and -)" ""
    if valid_name "$W_NAME" && ! g_exists "$W_NAME"; then break; fi
    err "invalid name or already used"
  done
  echo "  Operating system:"
  i=1; for v in $OS_LIST; do printf '    %d) %s\n' "$i" "$(os_label "$v")"; i=$((i + 1)); done
  ask v "OS (number or name)" "$S_DEF_OS"
  if valid_int "$v"; then v="$(echo "$OS_LIST" | awk -v i="$v" '{print $i}')"; fi
  F[os]="${v:-$S_DEF_OS}"
  while :; do
    ask v "CPU cores - server has $R_CPUS, free $R_CPU_LEFT (0.2 = 20% of one core)" "$S_DEF_CPU"
    cpu_ok "$v" && break; err "use a number between 0.01 and $R_CPUS"
  done; F[cpu]="$v"
  while :; do
    ask v "RAM - free $(human "$(( R_MEM_LEFT > 0 ? R_MEM_LEFT : 0 ))") of $(human "$R_MEM")" "$S_DEF_RAM"
    size_ok "$v" 64M && break; err "use a size like 200M or 1G (at least 64M)"
  done; F[ram]="$v"
  while :; do
    ask v "Swap - free $(human "$(( R_SWAP_LEFT > 0 ? R_SWAP_LEFT : 0 ))") of $(human "$R_SWAP")" "$S_DEF_SWAP"
    size_ok "$v" 0 && break; err "use a size like 512M or 1G (0 = none)"
  done; F[swap]="$v"
  # suggest a disk that really fits (keep 512M for the server)
  ddef="$S_DEF_DISK"; dmax=$(( (R_DFREE - 536870912) / 1073741824 ))
  if [ "$(to_bytes "$ddef")" -gt $((R_DFREE - 536870912)) ] && [ "$dmax" -ge 1 ]; then ddef="${dmax}G"; fi
  while :; do
    ask v "Disk - $(human "$R_DFREE") really free on the server" "$ddef"
    if size_ok "$v" 1G; then
      [ "$(to_bytes "$v")" -lt $((R_DFREE - 314572800)) ] && break
      err "not enough free disk for $v"
    else
      err "use a size like 2G (at least 1G)"
    fi
  done; F[disk]="$v"
  oversell_warn "${F[cpu]}" "${F[ram]}" "${F[swap]}"
  ask v "SSH port on this server's IP" auto; F[ssh-port]="$v"
  ask v "How many extra ports to forward (0 = none)" "$S_PORTS_PER_GUEST"; F[ports]="$v"
  ask v "Speed limit in Mbit/s (0 = no limit)" 0; F[speed]="$v"
  ask v "Monthly traffic limit in GB (0 = no limit)" 0; F[traffic]="$v"
  ask v "Expires after how many days (0 = never)" 0; F[expire]="$v"
  while :; do
    ask v "Root password - anything you like (empty = random)" ""
    [ -z "$v" ] && break
    valid_password "$v" && { F[password]="$v"; break; }
    err "$PW_RULE"
  done
  printf '\n  %s%s%s: %s | CPU %s | RAM %s | swap %s | disk %s\n' "$C_BD" "$W_NAME" "$C_0" "$(os_label "${F[os]}")" "${F[cpu]}" "${F[ram]^^}" "${F[swap]^^}" "${F[disk]^^}"
  confirm "Create machine '$W_NAME' now?" y
}

cmd_create() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" os cpu ram swap disk pids speed traffic expire rday pw key tun iom ioi sshp ports first free need allr allc
  W_NAME=""
  if [ -z "$name" ]; then
    interactive || die "usage: erisbox create NAME [options] (see: erisbox help)"
    create_wizard || die "cancelled"
    name="$W_NAME"
  fi
  valid_name "$name" || die "invalid name '$name' (2-32 chars: a-z, 0-9 and -, starting with a letter)"
  os="$(flag os "$S_DEF_OS")"; os_resolve "$os" || die "unknown OS '$os' (choose: $OS_LIST)"
  cpu="$(flag cpu "$S_DEF_CPU")"; check_cpu "$cpu"; cpu="$(norm_cpu "$cpu")"
  ram="$(flag ram "$S_DEF_RAM")"; check_size RAM "$ram" 64M
  swap="$(flag swap "$S_DEF_SWAP")"; check_size swap "$swap" 0
  disk="$(flag disk "$S_DEF_DISK")"; check_size disk "$disk" 1G
  pids="$(flag pids "$S_DEF_PIDS")"; valid_int "$pids" && [ "$pids" -ge 64 ] || die "--pids must be a number of at least 64"
  speed="$(flag speed 0)"; valid_int "$speed" || die "--speed is in Mbit/s (0 = no limit)"
  traffic="$(flag traffic 0)"; valid_num "$traffic" || die "--traffic is in GB per month (0 = no limit)"
  traffic="$(norm_cpu "$traffic")"
  rday="$(flag reset-day "$(date +%-d)")"; valid_int "$rday" || die "--reset-day must be 1-28"
  [ "$rday" -gt 28 ] && rday=28; [ "$rday" -lt 1 ] && rday=1
  expire="$(expire_value "$(flag expire "")")" || die "--expire takes a number of days or a date like 2026-12-31"
  pw="$(flag password "")"; [ -n "$pw" ] || pw="$(gen_password)"
  valid_password "$pw" || die "$PW_RULE"
  key="$(flag ssh-key "")"; [ -z "$key" ] || valid_sshkey "$key" || die "--ssh-key does not look like an SSH public key"
  case "$(flag tun off)" in on|1|yes) tun=1 ;; off|0|no) tun=0 ;; *) die "--tun on|off" ;; esac
  iom="$(flag io-mbps 0)"; ioi="$(flag io-iops 0)"
  valid_int "$iom" && valid_int "$ioi" || die "--io-mbps / --io-iops must be numbers"

  take_lock
  g_exists "$name" && die "machine '$name' already exists"
  [ -e "$LXC_DIR/$name" ] && die "an LXC container called '$name' already exists on this server"
  if [ "$iom" -gt 0 ] || [ "$ioi" -gt 0 ]; then
    cg_supports io.max && io_dev >/dev/null || die "disk speed limits are not supported on this server"
  fi

  build_port_map ""
  sshp="$(flag ssh-port auto)"
  if [ "$sshp" = auto ]; then
    sshp="$(alloc_ssh_port)" || die "no free SSH port"
  else
    valid_port "$sshp" || die "invalid --ssh-port"
    sshp=$((10#$sshp))
    port_free tcp "$sshp" "$sshp" || die "port $sshp is already used by $PORT_OWNER"
  fi
  port_take tcp "$sshp" "$sshp" "$name"
  allr="$(flag ports "$S_PORTS_PER_GUEST")"; ports=""
  case "$allr" in
    0|none|"") ;;
    *)
      if valid_int "$allr"; then
        allc=$((10#$allr)); [ "$allc" -le 1000 ] || die "at most 1000 ports per machine"
        first="$(alloc_range "$allc")" || die "no free block of $allc ports"
        ports="both:$first-$((first + allc - 1)):$first"
      else
        port_spec "$allr" || die "--ports takes a count (10), a range (20001-20010) or none"
        port_free both "$P_HS" "$P_HE" || die "port(s) $allr already used by $PORT_OWNER"
        ports="both:$P_HS-$P_HE:$P_GS"
      fi ;;
  esac

  need=$(( $(to_bytes "$disk") + 314572800 ))
  [ -s "$CACHE_DIR/$os.tar.zst" ] || need=$((need + 1073741824))
  free="$(disk_free "$VAR_DIR")"
  [ "$free" -gt "$need" ] || die "not enough free disk: need about $(human "$need"), have $(human "$free")"
  # the wizard already showed these warnings
  [ -n "${W_NAME:-}" ] || { res_compute; oversell_warn "$cpu" "$ram" "$swap"; }

  g_reset
  G_NAME="$name"; G_ID="$(alloc_id)" || die "no free machine slots (max $MAX_ID)"
  G_UIDBASE="$(alloc_base $((SUBUID_START + G_ID * 65536)))" || die "no free uid range"
  G_OS="$os"; G_CPU="$cpu"; G_RAM="${ram^^}"; G_SWAP="${swap^^}"; G_DISK="${disk^^}"; G_PIDS="$pids"
  G_IO_MBPS="$iom"; G_IO_IOPS="$ioi"; G_TUN="$tun"; G_SPEED="$speed"; G_TRAFFIC_GB="$traffic"
  G_RESET_DAY="$rday"; G_RESET_TAG="$(date +%Y-%m)"; G_EXPIRE="$expire"
  G_SSH_PORT="$sshp"; G_PORTS="$ports"; G_PASSWORD="$pw"; G_AUTOSTART=1; G_CREATED="$(date +%F)"

  image_ensure "$os" || die "could not prepare the $os image"
  info "Creating machine $name ..."
  if ! guest_build "$key"; then guest_cleanup_failed; die "could not create $name"; fi
  g_save
  lxc_write_config
  traffic_write_zero
  net_apply || warn "network rules could not be applied (run: erisbox apply)"
  log "created $name ($os, cpu $cpu, ram $ram, swap $swap, disk $disk)"
  ok "machine $name created"
  if ! has_flag no-start; then guest_start || warn "the machine was created but did not start"; fi
  show_info
}
traffic_write_zero() { T_RX=0; T_TX=0; T_RXL=0; T_TXL=0; traffic_write; }

# ================================================================== INFO ===
show_info() {
  local pip e pub i=0 d n w
  pip="$(public_ip)"
  printf '\n%s%s=== %s ===%s  %s\n' "$C_M" "$C_BD" "$G_NAME" "$C_0" "$(g_state "$G_NAME")${G_NOTE:+  ($G_NOTE)}"
  printf '  OS         : %s\n' "$(os_label "$G_OS")"
  printf '  Resources  : CPU %s core | RAM %s | swap %s | disk %s | max %s processes\n' "$G_CPU" "$G_RAM" "$G_SWAP" "$G_DISK" "$G_PIDS"
  printf '  SSH        : %sssh root@%s -p %s%s\n' "$C_BD" "$pip" "$G_SSH_PORT" "$C_0"
  printf '  Password   : %s\n' "$G_PASSWORD"
  for e in $G_PORTS; do printf '  Ports      : %s:%s\n' "$pip" "$(port_entry_text "$e")"; done
  while IFS=, read -r pub _; do
    [ -n "$pub" ] || continue
    i=$((i + 1))
    if [ "$i" = 1 ]; then
      printf '  Own IP     : %s (all ports, also its outgoing IP)  ssh root@%s\n' "$pub" "$pub"
    else
      printf '  Own IP 2   : %s (all ports; bind to %s to send from it)\n' "$pub" "$(g_ip2)"
    fi
  done < <(ip_entries)
  if [ -s "$DOMAIN_FILE" ]; then
    while read -r d n w; do [ "$n" = "$G_NAME" ] && printf '  Domain     : %s%s -> ports 80/443\n' "$d" "$( [ "$w" = 1 ] && echo ' (+subdomains)')"; done < "$DOMAIN_FILE"
  fi
  [ "${G_SPEED:-0}" != 0 ] && printf '  Speed      : %s Mbit/s\n' "$G_SPEED"
  printf '  Traffic    : %s\n' "$(traffic_text)"
  [ -n "$G_EXPIRE" ] && printf '  Expires    : %s\n' "$G_EXPIRE"
  [ "$G_TUN" = 1 ] && printf '  TUN device : enabled\n'
  return 0
}

cmd_info() {
  parse_flags "$@"; need_root; need_installed; s_load
  g_load "${POS[0]:-}"
  show_info
  g_usage
  printf '  Using now  : RAM %s | swap %s | disk %s of %s\n' "$(human "$U_MEM")" "$(human "$U_SWAP")" "$(human "$U_DUSED")" "$(human "$U_DSIZE")"
  printf '  Private IP : %s   Created: %s\n' "$(g_ip)" "${G_CREATED:-?}"
}

cmd_list() {
  parse_flags "$@"; need_root; need_installed; s_load
  local n ips any=0
  if has_flag json; then list_json; return; fi
  printf '%s%-14s %-8s %-13s %-5s %-14s %-14s %-14s %-6s %-16s %s%s\n' "$C_BD" NAME STATE OS CPU "RAM used/max" "SWAP used/max" "DISK used/max" SSH "OWN IP" EXPIRES "$C_0"
  for n in $(g_names); do
    any=1
    g_load "$n"; g_usage
    ips="$(ip_entries | cut -d, -f1 | paste -sd' ' -)"
    printf '%-14s %-8s %-13s %-5s %-14s %-14s %-14s %-6s %-16s %s\n' "$n" "$(g_state "$n")" "$(os_label "$G_OS")" "$G_CPU" \
      "$(human "$U_MEM")/$G_RAM" "$(human "$U_SWAP")/$G_SWAP" "$(human "$U_DUSED")/$G_DISK" "$G_SSH_PORT" "${ips:--}" "${G_EXPIRE:-never}${G_NOTE:+ ($G_NOTE)}"
  done
  [ "$any" = 1 ] || echo "  (no machines yet - create one with: erisbox create NAME)"
}
list_json() {
  local n first=1 ips
  printf '['
  for n in $(g_names); do
    g_load "$n"; g_usage; traffic_read
    ips="$(ip_entries | cut -d, -f1 | paste -sd' ' -)"
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"name":"%s","state":"%s","os":"%s","cpu":%s,"ram":%s,"swap":%s,"disk":%s,"pids":%s,"ram_used":%s,"swap_used":%s,"disk_used":%s,"ssh_port":%s,"ports":"%s","ips":"%s","private_ip":"%s","speed_mbit":%s,"traffic_limit_gb":%s,"traffic_down":%s,"traffic_up":%s,"expire":"%s","note":"%s"}' \
      "$n" "$(g_state "$n")" "$G_OS" "$G_CPU" "$(to_bytes "$G_RAM")" "$(to_bytes "$G_SWAP")" "$(to_bytes "$G_DISK")" "$G_PIDS" \
      "$U_MEM" "$U_SWAP" "$U_DUSED" "${G_SSH_PORT:-0}" "$G_PORTS" "$ips" "$(g_ip)" "${G_SPEED:-0}" "$(norm_cpu "${G_TRAFFIC_GB:-0}")" \
      "$T_TX" "$T_RX" "$G_EXPIRE" "$G_NOTE"
  done
  printf ']\n'
}

# ============================================================ LIFE CYCLE ===
cmd_power() {
  local act="$1" n names rc=0; shift
  parse_flags "$@"; need_root; need_installed; s_load
  if has_flag all; then names="$(g_names)"; else names="${POS[0]:-}"; fi
  [ -n "$names" ] || die "usage: erisbox $act NAME (or --all)"
  for n in $names; do
    g_load "$n"
    case "$act" in
      start)
        if [ -n "$G_NOTE" ] && ! has_flag force; then err "$n is $G_NOTE - renew it or reset its traffic first (or add --force)"; rc=1; continue; fi
        guest_start || rc=1 ;;
      stop) guest_stop || rc=1 ;;
      restart) guest_stop; guest_start || rc=1 ;;
    esac
  done
  return "$rc"
}

cmd_set() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" v restart=0 start=0 changed=0
  g_load "$name"
  take_lock
  g_load "$name"
  if has_flag cpu; then v="$(flag cpu)"; check_cpu "$v"; G_CPU="$(norm_cpu "$v")"; changed=1; fi
  if has_flag ram; then v="$(flag ram)"; check_size RAM "$v" 64M; G_RAM="${v^^}"; changed=1; fi
  if has_flag swap; then v="$(flag swap)"; check_size swap "$v" 0; G_SWAP="${v^^}"; changed=1; fi
  if has_flag pids; then v="$(flag pids)"; valid_int "$v" && [ "$v" -ge 64 ] || die "--pids must be >= 64"; G_PIDS="$v"; changed=1; fi
  if has_flag io-mbps || has_flag io-iops; then
    v="$(flag io-mbps "$G_IO_MBPS")"; valid_int "$v" || die "--io-mbps must be a number"; G_IO_MBPS="$v"
    v="$(flag io-iops "$G_IO_IOPS")"; valid_int "$v" || die "--io-iops must be a number"; G_IO_IOPS="$v"
    if [ "$G_IO_MBPS" -gt 0 ] || [ "$G_IO_IOPS" -gt 0 ]; then cg_supports io.max && io_dev >/dev/null || die "disk speed limits are not supported here"; fi
    changed=1
  fi
  if has_flag disk; then
    v="$(flag disk)"; check_size disk "$v" 1G
    guest_mount_if_running
    disk_resize "$(to_bytes "$v")"; G_DISK="${v^^}"; changed=1
  fi
  if has_flag speed; then v="$(flag speed)"; valid_int "$v" || die "--speed is in Mbit/s"; G_SPEED="$v"; changed=1; fi
  if has_flag traffic; then
    v="$(flag traffic)"; valid_num "$v" || die "--traffic is in GB"; v="$(norm_cpu "$v")"; G_TRAFFIC_GB="$v"; changed=1
    if [ "$G_NOTE" = overquota ] && { [ "$v" = 0 ] || [ "$(traffic_total)" -lt "$(gb_to_bytes "$v")" ]; }; then G_NOTE=""; start=1; fi
  fi
  if has_flag reset-day; then v="$(flag reset-day)"; valid_int "$v" && [ "$v" -ge 0 ] && [ "$v" -le 28 ] || die "--reset-day 0-28 (0 = never)"; G_RESET_DAY="$v"; changed=1; fi
  if has_flag expire; then
    v="$(expire_value "$(flag expire)")" || die "--expire takes days, a date (2026-12-31) or never"
    G_EXPIRE="$v"; changed=1
    if [ "$G_NOTE" = expired ] && { [ -z "$v" ] || [[ ! "$(date +%F)" > "$v" ]]; }; then G_NOTE=""; start=1; fi
  fi
  if has_flag autostart; then case "$(flag autostart)" in on|1|yes) G_AUTOSTART=1 ;; off|0|no) G_AUTOSTART=0 ;; *) die "--autostart on|off" ;; esac; changed=1; fi
  if has_flag tun; then case "$(flag tun)" in on|1|yes) v=1 ;; off|0|no) v=0 ;; *) die "--tun on|off" ;; esac; [ "$v" != "$G_TUN" ] && restart=1; G_TUN="$v"; changed=1; fi
  [ "$changed" = 1 ] || die "nothing to change (see: erisbox help)"
  if has_flag cpu || has_flag ram || has_flag swap; then res_compute "$name"; oversell_warn "$G_CPU" "$G_RAM" "$G_SWAP"; fi
  g_save
  lxc_write_config
  apply_live_limits
  if [ -n "$G_NOTE" ]; then enforce_note
  elif [ "$start" = 1 ] && [ "$G_AUTOSTART" = 1 ]; then guest_start
  fi
  log "set $name $*"
  ok "updated $name"
  [ "$restart" = 1 ] && g_running "$name" && warn "restart $name to apply the TUN change: erisbox restart $name"
  return 0
}
guest_mount_if_running() { g_running "$G_NAME" || return 0; mountpoint -q "$(g_mnt)" || guest_mount; }

cmd_renew() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" v="${POS[1]:-}" base today
  [ -n "$v" ] || die "usage: erisbox renew NAME DAYS|YYYY-MM-DD [--reset-traffic]"
  take_lock
  g_load "$name"
  today="$(date +%F)"
  if valid_int "$v"; then
    base="$today"; [ -n "$G_EXPIRE" ] && [[ "$G_EXPIRE" > "$today" ]] && base="$G_EXPIRE"
    G_EXPIRE="$(date -d "$base +$((10#$v)) days" +%F)"
  elif valid_date "$v"; then
    G_EXPIRE="$v"
  else
    die "use a number of days or a date like 2026-12-31"
  fi
  [ "$G_NOTE" = expired ] && G_NOTE=""
  if has_flag reset-traffic; then traffic_reset; [ "$G_NOTE" = overquota ] && G_NOTE=""; fi
  g_save; lxc_write_config
  [ -z "$G_NOTE" ] && [ "$G_AUTOSTART" = 1 ] && guest_start
  tc_apply
  log "renew $name until $G_EXPIRE"
  ok "$name is valid until $G_EXPIRE"
}

cmd_traffic() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}"
  g_load "$name"
  if has_flag reset; then
    take_lock; g_load "$name"
    traffic_reset
    if [ "$G_NOTE" = overquota ]; then G_NOTE=""; g_save; lxc_write_config; [ "$G_AUTOSTART" = 1 ] && guest_start; tc_apply; fi
    ok "traffic counter of $name reset"
    return 0
  fi
  traffic_account
  printf '  %s: %s\n' "$name" "$(traffic_text)"
  [ "${G_RESET_DAY:-0}" -gt 0 ] && [ "${G_TRAFFIC_GB:-0}" != 0 ] && printf '  resets on day %s of every month\n' "$G_RESET_DAY"
  return 0
}

cmd_passwd() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" pw hash
  pw="$(flag password "${POS[1]:-}")"
  g_load "$name"
  if [ -z "$pw" ]; then ask pw "New root password for $name (anything you like, empty = random)" ""; fi
  [ -n "$pw" ] || pw="$(gen_password)"
  valid_password "$pw" || die "$PW_RULE"
  take_lock; g_load "$name"
  g_running "$name" || die "start the machine first: erisbox start $name"
  # set a ready hash: no shell quoting issues and no password-strength rules inside the machine
  hash="$(pw_hash "$pw")" && [ -n "$hash" ] || die "could not hash the password"
  printf 'root:%s\n' "$hash" | guest_exec "$name" chpasswd -e || die "could not change the password"
  G_PASSWORD="$pw"; g_save
  log "passwd $name"
  ok "new root password of $name: $pw"
}

cmd_sshkey() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" key="${POS[1]:-}"
  [ -n "$key" ] || die "usage: erisbox sshkey NAME \"ssh-ed25519 AAAA... comment\""
  valid_sshkey "$key" || die "that does not look like an SSH public key"
  g_load "$name"
  g_running "$name" || die "start the machine first: erisbox start $name"
  printf '%s\n' "$key" | guest_exec "$name" sh -c 'umask 077; mkdir -p /root/.ssh; cat >> /root/.ssh/authorized_keys' \
    || die "could not add the key"
  ok "SSH key added to root@$name"
}

cmd_console() {
  need_root; need_installed; s_load
  local name="${1:-}"
  g_load "$name"
  g_running "$name" || die "$name is not running (erisbox start $name)"
  info "root shell inside $name - type 'exit' to leave"
  if guest_exec "$name" test -x /bin/bash; then guest_exec "$name" /bin/bash -l; else guest_exec "$name" /bin/sh -l; fi
}
cmd_exec() {
  need_root; need_installed
  local name="${1:-}"
  [ $# -gt 0 ] && shift
  [ "${1:-}" = "--" ] && shift
  g_exists "$name" || die "usage: erisbox exec NAME -- COMMAND..."
  [ $# -gt 0 ] || die "usage: erisbox exec NAME -- COMMAND..."
  g_running "$name" || die "$name is not running"
  guest_exec "$name" "$@"
}

cmd_reinstall() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" os pw key
  g_load "$name"
  os="$(flag os "$G_OS")"; os_resolve "$os" || die "unknown OS '$os' (choose: $OS_LIST)"
  pw="$(flag password "")"; [ -n "$pw" ] || pw="$(gen_password)"
  valid_password "$pw" || die "$PW_RULE"
  key="$(flag ssh-key "")"; [ -z "$key" ] || valid_sshkey "$key" || die "invalid --ssh-key"
  confirm "ALL files on $name will be erased and $(os_label "$os") installed fresh. Continue?" n || die "cancelled"
  take_lock; g_load "$name"
  image_ensure "$os" || die "could not prepare the $os image"
  guest_stop 20
  guest_umount || die "cannot unmount the disk of $name"
  G_OS="$os"; G_PASSWORD="$pw"
  guest_build "$key" || die "reinstall failed"
  g_save; lxc_write_config
  log "reinstall $name with $os"
  guest_start
  show_info
}

cmd_backup() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" was=0 out used
  g_load "$name"
  take_lock; g_load "$name"
  mkdir -p "$BACKUP_DIR"
  used="$(stat -c %b "$(g_img)")"; used=$((used * 512))
  [ "$(disk_free "$BACKUP_DIR")" -gt "$used" ] || die "not enough free disk for a backup of $(human "$used")"
  if g_running "$name"; then
    confirm "$name must stop for a moment during the backup. Continue?" y || die "cancelled"
    was=1; guest_stop 30
  fi
  guest_umount
  traffic_account
  out="$BACKUP_DIR/$name-$(date +%Y%m%d-%H%M%S).tar.zst"
  info "Writing $out ..."
  if ! tar --sparse -cf - -C "$DISK_DIR" "$name.img" -C "$GUEST_DIR" "$name.conf" | zstd -q -T0 -3 > "$out.tmp"; then
    rm -f "$out.tmp"; [ "$was" = 1 ] && guest_start; die "backup failed"
  fi
  mv -f "$out.tmp" "$out"; chmod 600 "$out"
  [ "$was" = 1 ] && guest_start
  log "backup $name -> $out"
  ok "backup saved: $out ($(human "$(stat -c %s "$out")"))"
  info "restore it here or on another Eris Box server with: erisbox restore $out [NEW_NAME]"
}

shift_uids() { # dir old_base new_base
  command -v python3 >/dev/null || die "python3 is needed to restore this backup"
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys
root, old, new = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = new - old
def fix(p):
    st = os.lstat(p)
    u = st.st_uid + d if old <= st.st_uid < old + 65536 else st.st_uid
    g = st.st_gid + d if old <= st.st_gid < old + 65536 else st.st_gid
    if (u, g) != (st.st_uid, st.st_gid):
        os.lchown(p, u, g)
        if not os.path.islink(p):
            os.chmod(p, st.st_mode & 0o7777)
fix(root)
for dp, dns, fns in os.walk(root):
    for n in dns + fns:
        fix(os.path.join(dp, n))
PY
}

cmd_restore() {
  parse_flags "$@"; need_root; need_installed; s_load
  local file="${POS[0]:-}" newname="${POS[1]:-}" tmpd conf img old name oldbase e v keep="" cnt members
  [ -f "$file" ] || die "usage: erisbox restore BACKUP_FILE [NEW_NAME]   (backups are in $BACKUP_DIR)"
  take_lock
  # a backup may come from somebody else: accept exactly NAME.img + NAME.conf as plain files
  members="$(zstd -dc "$file" | tar -tf - 2>/dev/null)" || die "cannot read $file"
  if [ "$(printf '%s\n' "$members" | grep -c .)" != 2 ] \
     || printf '%s\n' "$members" | grep -qvE '^[a-z][a-z0-9-]{0,30}[a-z0-9]\.(img|conf)$'; then
    die "$file is not an Eris Box backup"
  fi
  tmpd="$(mktemp -d "$VAR_DIR/restore.XXXXXX")"
  info "Unpacking $file ..."
  if ! zstd -dc "$file" | tar --sparse --no-same-owner -xf - -C "$tmpd"; then rm -rf "$tmpd"; die "cannot read $file"; fi
  conf="$(find "$tmpd" -maxdepth 1 -type f -name '*.conf' | head -1)"; img="$(find "$tmpd" -maxdepth 1 -type f -name '*.img' | head -1)"
  if [ ! -f "$conf" ] || [ ! -f "$img" ] || [ -L "$conf" ] || [ -L "$img" ] || [ -n "$(find "$tmpd" -mindepth 1 ! -type f)" ]; then
    rm -rf "$tmpd"; die "$file is not an Eris Box backup"
  fi
  old="$(basename "$conf" .conf)"; name="${newname:-$old}"
  if ! valid_name "$name" || g_exists "$name" || [ -e "$LXC_DIR/$name" ]; then
    rm -rf "$tmpd"; die "a machine called '$name' already exists here - give a new name: erisbox restore $file NEWNAME"
  fi
  g_reset; kv_load "$conf" G_; g_pw_decode; G_NAME="$name"
  if ! os_resolve "$G_OS" || ! valid_num "$G_CPU" || ! to_bytes "$G_RAM" >/dev/null || ! to_bytes "$G_SWAP" >/dev/null \
     || ! to_bytes "$G_DISK" >/dev/null || ! valid_int "$G_PIDS" || ! valid_password "$G_PASSWORD"; then
    rm -rf "$tmpd"; die "the settings inside this backup are damaged"
  fi
  if [ "$(cpu_quota "$G_CPU")" -gt $(( $(host_cpus) * 100000 )) ]; then
    warn "the backup asks for $G_CPU CPU - limited to this server's $(host_cpus)"; G_CPU="$(host_cpus)"
  fi
  [ "$(cpu_quota "$G_CPU")" -ge 1000 ] || G_CPU=0.01
  [ "$G_PIDS" -ge 64 ] || G_PIDS=64
  for e in IO_MBPS IO_IOPS SPEED RESET_DAY; do v="G_$e"; valid_int "${!v}" || printf -v "$v" '%s' 0; done
  valid_num "$G_TRAFFIC_GB" || G_TRAFFIC_GB=0
  [ "$G_TUN" = 1 ] || G_TUN=0
  [ "$G_AUTOSTART" = 0 ] || G_AUTOSTART=1
  [ -z "$G_EXPIRE" ] || valid_date "$G_EXPIRE" || G_EXPIRE=""
  oldbase="$G_UIDBASE"; valid_int "$oldbase" || { valid_int "$G_ID" && oldbase=$((SUBUID_START + G_ID * 65536)); }
  valid_int "$oldbase" || { rm -rf "$tmpd"; die "the backup has no uid information"; }
  G_ID="$(alloc_id)" || { rm -rf "$tmpd"; die "no free machine slots"; }
  G_UIDBASE="$(alloc_base "$oldbase")" || { rm -rf "$tmpd"; die "no free uid range"; }
  build_port_map ""
  if ! valid_port "$G_SSH_PORT" || ! port_free tcp "$G_SSH_PORT" "$G_SSH_PORT"; then G_SSH_PORT="$(alloc_ssh_port)"; fi
  port_take tcp "$G_SSH_PORT" "$G_SSH_PORT" "$name"
  for e in $G_PORTS; do
    port_entry_parse "$e"
    case "$P_PROTO" in tcp|udp|both) ;; *) continue ;; esac
    valid_port "$P_HS" && valid_port "$P_HE" && valid_port "$P_GS" && [ "$P_HE" -ge "$P_HS" ] || continue
    if port_free "$P_PROTO" "$P_HS" "$P_HE"; then
      keep="${keep:+$keep }$e"; port_take "$P_PROTO" "$P_HS" "$P_HE" "$name"
    else
      cnt=$((P_HE - P_HS + 1)); P_HS="$(alloc_range "$cnt")" || continue
      keep="${keep:+$keep }both:$P_HS-$((P_HS + cnt - 1)):$P_HS"; port_take both "$P_HS" $((P_HS + cnt - 1)) "$name"
      warn "ports changed to $P_HS-$((P_HS + cnt - 1)) (the old ones are used here)"
    fi
  done
  G_PORTS="$keep"
  [ -n "$G_IPS" ] && warn "dedicated IPs from the backup are not restored (add them again with: erisbox ip add $name IP)"
  G_IPS=""; G_NOTE=""
  mkdir -p "$DISK_DIR"
  mv -f "$img" "$DISK_DIR/$name.img"; chmod 600 "$DISK_DIR/$name.img"
  rm -rf "$tmpd"
  if [ "$G_UIDBASE" != "$oldbase" ]; then
    info "Moving the machine's files to a new uid range ..."
    guest_mount || die "cannot mount the restored disk"
    shift_uids "$(g_mnt)" "$oldbase" "$G_UIDBASE" || { guest_umount; die "uid shifting failed"; }
    guest_umount
  fi
  g_save; lxc_write_config; traffic_write_zero
  net_apply
  log "restore $file as $name"
  ok "restored $name"
  guest_start
  show_info
}

cmd_delete() {
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" a loc ifc added tmp
  g_load "$name"
  if ! has_flag force && [ "$YES" != 1 ]; then
    tty_ok || die "add -y to delete without a question"
    ask a "Type the name '$name' to delete it with ALL its files" ""
    [ "$a" = "$name" ] || die "cancelled"
  fi
  take_lock; g_load "$name"
  guest_stop 15
  while IFS=, read -r _ loc ifc _ added; do
    [ "$added" = 1 ] && ip addr del "$loc/32" dev "$ifc" 2>/dev/null
  done < <(ip_entries)
  guest_umount
  rm -f "$(g_img)"; rmdir "$(g_mnt)" 2>/dev/null
  if [ -f "$LXC_DIR/$name/config" ] && grep -q "^$LXC_MARK" "$LXC_DIR/$name/config"; then rm -rf "${LXC_DIR:?}/$name"; fi
  rm -f "$TRAFFIC_DIR/$name" "$TRAFFIC_DIR/$name.lock" "$LOG_DIR/$name.log" "$VAR_DIR/banner/$name"
  if [ -s "$DOMAIN_FILE" ] && awk -v n="$name" '$2==n {f=1} END{exit !f}' "$DOMAIN_FILE"; then
    tmp="$(mktemp)"; awk -v n="$name" '$2!=n' "$DOMAIN_FILE" > "$tmp" && cat "$tmp" > "$DOMAIN_FILE"; rm -f "$tmp"
    proxy_render
  fi
  rm -f "$(g_conf "$name")"
  G_NAME=""
  net_apply
  log "deleted $name"
  ok "machine $name deleted"
}

# ============================================================= RESOURCES ===
HOST_RESERVE=268435456   # RAM kept for the server itself (256M)
# totals of the server and what the machines already got (optionally leaving one machine out)
res_compute() {
  local n c
  R_CPUS="$(host_cpus)"; R_MEM="$(host_mem)"; R_SWAP="$(host_swap)"
  read -r R_DTOT R_DFREE < <(df -B1 --output=size,avail "$VAR_DIR" | tail -1)
  R_CPU_GIVEN=0; R_MEM_GIVEN=0; R_SWAP_GIVEN=0; R_DISK_GIVEN=0; R_COUNT=0
  for n in $(g_names); do
    [ "$n" = "${1:-}" ] && continue
    c="$(g_conf "$n")"; R_COUNT=$((R_COUNT + 1))
    R_CPU_GIVEN="$(awk -v a="$R_CPU_GIVEN" -v b="$(kv_get "$c" CPU)" 'BEGIN{printf "%g", a+b}')"
    R_MEM_GIVEN=$((R_MEM_GIVEN + $(to_bytes "$(kv_get "$c" RAM)" || echo 0)))
    R_SWAP_GIVEN=$((R_SWAP_GIVEN + $(to_bytes "$(kv_get "$c" SWAP)" || echo 0)))
    R_DISK_GIVEN=$((R_DISK_GIVEN + $(to_bytes "$(kv_get "$c" DISK)" || echo 0)))
  done
  R_CPU_LEFT="$(awk -v t="$R_CPUS" -v g="$R_CPU_GIVEN" 'BEGIN{printf "%g", t-g}')"
  R_MEM_LEFT=$((R_MEM - HOST_RESERVE - R_MEM_GIVEN))
  R_SWAP_LEFT=$((R_SWAP - R_SWAP_GIVEN))
}
pct() { awk -v g="$1" -v t="$2" 'BEGIN{ if (t > 0) printf "%d%%", g * 100 / t + 0.5; else print "-" }'; }
left_text() { # value-is-number "text if positive" "amount over" -> green / yellow text
  if [ "$1" = ok ]; then printf '%s%s%s' "$C_G" "$2" "$C_0"; else printf '%soversold by %s%s' "$C_Y" "$2" "$C_0"; fi
}
res_show() {
  local cpu_l mem_l swap_l disk_l
  if awk -v l="$R_CPU_LEFT" 'BEGIN{exit !(l >= 0)}'; then cpu_l="$(left_text ok "$R_CPU_LEFT")"
  else cpu_l="$(left_text over "$(awk -v l="$R_CPU_LEFT" 'BEGIN{printf "%g", -l}')")"; fi
  if [ "$R_MEM_LEFT" -ge 0 ]; then mem_l="$(left_text ok "$(human "$R_MEM_LEFT")")"; else mem_l="$(left_text over "$(human $((-R_MEM_LEFT)))")"; fi
  if [ "$R_SWAP_LEFT" -ge 0 ]; then swap_l="$(left_text ok "$(human "$R_SWAP_LEFT")")"; else swap_l="$(left_text over "$(human $((-R_SWAP_LEFT)))")"; fi
  if [ "$R_DFREE" -gt 1073741824 ]; then disk_l="$(left_text ok "$(human "$R_DFREE")")"; else disk_l="${C_R}$(human "$R_DFREE")${C_0}"; fi
  printf '  %s%-11s %-10s %-24s %s%s\n' "$C_BD" "" "SERVER" "GIVEN TO $R_COUNT MACHINE(S)" "FREE FOR NEW ONES" "$C_0"
  printf '  %-11s %-10s %-24s %s\n' "CPU cores" "$R_CPUS" "$R_CPU_GIVEN ($(pct "$R_CPU_GIVEN" "$R_CPUS"))" "$cpu_l"
  printf '  %-11s %-10s %-24s %s\n' "RAM" "$(human "$R_MEM")" "$(human "$R_MEM_GIVEN") ($(pct "$R_MEM_GIVEN" "$R_MEM"))" "$mem_l  ${C_D}(256M kept for the server)${C_0}"
  printf '  %-11s %-10s %-24s %s\n' "Swap" "$(human "$R_SWAP")" "$(human "$R_SWAP_GIVEN") ($(pct "$R_SWAP_GIVEN" "$R_SWAP"))" "$swap_l"
  printf '  %-11s %-10s %-24s %s\n' "Disk" "$(human "$R_DTOT")" "$(human "$R_DISK_GIVEN") ($(pct "$R_DISK_GIVEN" "$R_DTOT"))" "$disk_l  ${C_D}(really free now)${C_0}"
  printf '  %sCPU, RAM and swap may be oversold (machines are rarely all busy); disk space cannot.%s\n' "$C_D" "$C_0"
}
cmd_resources() {
  parse_flags "$@"; need_root; need_installed; s_load
  printf '\n%sServer resources%s  (%s)\n' "$C_BD" "$C_0" "$(. /etc/os-release; echo "$PRETTY_NAME")"
  res_compute; res_show
}
# warnings when a new or changed machine would oversell the server (needs res_compute without it)
oversell_warn() { # cpu ram swap
  local c m s
  c="$(awk -v a="$R_CPU_GIVEN" -v b="$1" 'BEGIN{printf "%g", a+b}')"
  m=$((R_MEM_GIVEN + $(to_bytes "$2" || echo 0))); s=$((R_SWAP_GIVEN + $(to_bytes "$3" || echo 0)))
  awk -v c="$c" -v t="$R_CPUS" 'BEGIN{exit !(c > t)}' \
    && warn "CPU oversold: machines get $c cores in total, the server has $R_CPUS"
  [ "$m" -gt $((R_MEM - HOST_RESERVE)) ] \
    && warn "RAM oversold: machines get $(human "$m"), the server has $(human "$R_MEM") (256M kept for itself)"
  [ "$s" -gt "$R_SWAP" ] \
    && warn "swap oversold: machines get $(human "$s"), the server has $(human "$R_SWAP") swap"
  return 0
}
size_ok() { local b m; b="$(to_bytes "$1")" && m="$(to_bytes "$2")" && [ "$b" -ge "$m" ]; }
cpu_ok() { valid_num "$1" && [ "$(cpu_quota "$1")" -ge 1000 ] && [ "$(cpu_quota "$1")" -le $(( $(host_cpus) * 100000 )) ]; }

# ================================================================ STATUS ===
cmd_status() {
  parse_flags "$@"; need_root; need_installed; s_load
  local n cpus mem avail sw swf dtot dfree cnt=0 run=0 u1 pct
  declare -A U0=()
  cpus="$(host_cpus)"; mem="$(host_mem)"; avail="$(host_memavail)"; sw="$(host_swap)"
  swf="$(awk '/^SwapFree:/{printf "%.0f\n", $2*1024}' /proc/meminfo)"
  read -r dtot dfree < <(df -B1 --output=size,avail "$VAR_DIR" | tail -1)
  for n in $(g_names); do
    cnt=$((cnt + 1))
    if g_running "$n"; then run=$((run + 1)); U0[$n]="$(cg_read "$n" cpu.stat | awk '/^usage_usec/{print $2}')"; fi
  done
  printf '%sServer%s\n' "$C_BD" "$C_0"
  printf '  System     : %s, kernel %s, Eris Box %s\n' "$(. /etc/os-release; echo "$PRETTY_NAME")" "$(uname -r)" "$SCRIPT_VER"
  printf '  CPU        : %s core(s), load %s\n' "$cpus" "$(cut -d' ' -f1-3 /proc/loadavg)"
  printf '  RAM        : %s used of %s (%s available)\n' "$(human $((mem - avail)))" "$(human "$mem")" "$(human "$avail")"
  printf '  Swap       : %s used of %s\n' "$(human $((sw - swf)))" "$(human "$sw")"
  printf '  Disk       : %s free of %s\n' "$(human "$dfree")" "$(human "$dtot")"
  printf '  Network    : public IP %s, main card %s, bridge %s %s/16\n' "$(public_ip)" "$(wan_if)" "$S_BRIDGE" "$(gw_ip)"
  printf '\n%sResources%s\n' "$C_BD" "$C_0"
  res_compute; res_show
  printf '\n%sMachines%s: %s (%s running)\n' "$C_BD" "$C_0" "$cnt" "$run"
  [ "$cnt" -gt 0 ] || return 0
  sleep 1
  printf '\n%s%-14s %-8s %-12s %-15s %-15s %-15s %s%s\n' "$C_BD" NAME STATE "CPU now/max" "RAM" "SWAP" "DISK" TRAFFIC "$C_0"
  for n in $(g_names); do
    g_load "$n"; g_usage
    pct="-"
    if [ -n "${U0[$n]-}" ]; then
      u1="$(cg_read "$n" cpu.stat | awk '/^usage_usec/{print $2}')"
      [ -n "$u1" ] && pct="$(( (u1 - ${U0[$n]}) / 10000 ))%"
    fi
    traffic_read
    printf '%-14s %-8s %-12s %-15s %-15s %-15s %s\n' "$n" "$(g_state "$n")" "$pct/$(cpu_quota "$G_CPU" | awk '{printf "%d%%", $1/1000}')" \
      "$(human "$U_MEM")/$G_RAM" "$(human "$U_SWAP")/$G_SWAP" "$(human "$U_DUSED")/$G_DISK" "$(human $((T_RX + T_TX)))"
  done
}

cmd_image() {
  parse_flags "$@"; need_root; need_installed; s_load
  local sub="${POS[0]:-list}" os="${POS[1]:-}" f
  case "$sub" in
    list|ls)
      for os in $OS_LIST; do
        f="$CACHE_DIR/$os.tar.zst"
        if [ -f "$f" ]; then printf '  %-14s %-8s ready, built %s\n' "$os" "$(human "$(stat -c %s "$f")")" "$(date -r "$f" +%F)"
        else printf '  %-14s %s\n' "$os" "not downloaded yet (built on first use)"; fi
      done ;;
    build|rebuild|update) os_resolve "$os" || die "usage: erisbox image build OS   ($OS_LIST)"; take_lock; image_build "$os" ;;
    delete|rm) os_resolve "$os" || die "usage: erisbox image delete OS"; rm -f "$CACHE_DIR/$os.tar.zst"; ok "removed the cached $os image" ;;
    *) die "usage: erisbox image list | build OS | delete OS" ;;
  esac
}

cmd_settings() {
  need_root; need_installed; s_load
  local sub="${1:-show}" k v
  case "$sub" in
    show|list)
      for k in $S_KEYS; do v="S_$k"; printf '  %-20s %s\n' "$k" "${!v}"; done ;;
    set)
      [ $# -ge 3 ] || die "usage: erisbox settings set KEY VALUE"
      setting_set "$2" "$3" ;;
    *) die "usage: erisbox settings [show | set KEY VALUE]" ;;
  esac
}
setting_set() {
  local k="$1" v="$2" x
  case "$k" in
    PUBLIC_IP) [ "$v" = auto ] && v="$(detect_public_ip)"; valid_ipv4 "$v" || die "invalid IP" ;;
    DNS) [ -n "$v" ] || die "give one or more IPs, e.g. \"1.1.1.1 8.8.8.8\""; for x in $v; do valid_ipv4 "$x" || die "DNS servers must be IPv4 addresses"; done ;;
    SSH_PORT_START|PORT_RANGE_START) valid_port "$v" || die "invalid port" ;;
    PORTS_PER_GUEST) valid_int "$v" && [ "$v" -le 1000 ] || die "0-1000" ;;
    DEF_OS) os_resolve "$v" || die "choose: $OS_LIST" ;;
    DEF_CPU) check_cpu "$v"; v="$(norm_cpu "$v")" ;;
    DEF_RAM|DEF_SWAP|DEF_DISK) to_bytes "$v" >/dev/null || die "invalid size"; v="${v^^}" ;;
    DEF_PIDS) valid_int "$v" && [ "$v" -ge 64 ] || die "at least 64" ;;
    BLOCK_SMTP|BLOCK_PRIVATE) [[ "$v" =~ ^[01]$ ]] || die "0 or 1" ;;
    QUOTA_ACTION) [ "$v" = stop ] || [ "$v" = throttle ] || die "stop or throttle" ;;
    UBUNTU_MIRROR|UBUNTU_PORTS_MIRROR|DEBIAN_MIRROR) valid_url "$v" || die "invalid URL" ;;
    *) die "unknown or read-only setting '$k'" ;;
  esac
  printf -v "S_$k" '%s' "$v"
  s_save
  ok "$k = $v"
  case "$k" in
    BLOCK_SMTP|BLOCK_PRIVATE) take_lock; net_apply ;;
    DNS) info "new machines get this DNS; existing ones keep theirs (/etc/resolv.conf inside)" ;;
  esac
  return 0
}

cmd_apply() {
  parse_flags "$@"; need_root; need_installed; s_load
  take_lock
  if net_apply; then has_flag boot || ok "network rules applied"; else die "network rules failed"; fi
  proxy_render >/dev/null 2>&1 || true
}

cmd_update() {
  need_root
  local tmp newver
  tmp="$(mktemp)"
  info "Downloading the latest Eris Box ..."
  curl -fsSL "$RAW_BASE/erisbox.sh" -o "$tmp" || { rm -f "$tmp"; die "download failed"; }
  grep -q '^# ERIS-BOX-SCRIPT' "$tmp" || { rm -f "$tmp"; die "the downloaded file is not Eris Box"; }
  bash -n "$tmp" || { rm -f "$tmp"; die "the downloaded script has syntax errors - not installed"; }
  newver="$(grep -m1 '^SCRIPT_VER=' "$tmp" | cut -d'"' -f2)"
  install -m 755 "$tmp" "$BIN_PATH.new" && mv -f "$BIN_PATH.new" "$BIN_PATH"
  rm -f "$tmp"
  is_installed && "$BIN_PATH" _refresh
  ok "Eris Box $SCRIPT_VER -> ${newver:-?}"
}

cmd_uninstall() {
  parse_flags "$@"; need_root
  local n loc ifc added purge=0
  confirm "Stop all machines and remove Eris Box from this server?" n || die "cancelled"
  if has_flag purge; then purge=1
  elif interactive && confirm "Also DELETE all machines, their disks and backups?" n; then purge=1
  fi
  s_load
  take_lock
  G_NAME=""
  # first, because it re-applies the network rules (which would re-add the extra IPs)
  [ "$S_PROXY_ENABLED" = 1 ] && proxy_disable
  for n in $(g_names); do
    g_load "$n"; guest_stop 15
    while IFS=, read -r _ loc ifc _ added; do
      [ "$added" = 1 ] && ip addr del "$loc/32" dev "$ifc" 2>/dev/null
    done < <(ip_entries)
    guest_umount
    if [ "$purge" = 1 ] && [ -f "$LXC_DIR/$n/config" ] && grep -q "^$LXC_MARK" "$LXC_DIR/$n/config"; then rm -rf "${LXC_DIR:?}/$n"; fi
  done
  G_NAME=""
  systemctl disable --now erisbox-tick.timer >/dev/null 2>&1
  systemctl disable erisbox-net.service >/dev/null 2>&1
  rm -f "$UNIT_DIR/erisbox-net.service" "$UNIT_DIR/erisbox-tick.service" "$UNIT_DIR/erisbox-tick.timer"
  systemctl daemon-reload
  nft delete table inet erisbox 2>/dev/null; nft delete table ip erisbox_nat 2>/dev/null; nft delete table bridge erisbox_br 2>/dev/null
  while ip rule del pref "$RULE_PREF" 2>/dev/null; do :; done
  ipt_remove
  ip link del "$S_BRIDGE" 2>/dev/null
  rm -rf "$LIB_DIR"
  rm -f /etc/sysctl.d/90-erisbox.conf
  if [ "$purge" = 1 ]; then
    umount_below "$VAR_DIR"
    rm -rf --one-file-system "$ETC_DIR" "$VAR_DIR"
    sed -i "/^root:${SUBUID_START}:${SUBUID_COUNT}\$/d" /etc/subuid /etc/subgid
    ok "Eris Box and all machines were removed"
  else
    ok "Eris Box was removed - machine disks and settings are kept in $VAR_DIR and $ETC_DIR (reinstall to use them again)"
  fi
  rm -f "$BIN_PATH"
  [ -f /swapfile-erisbox ] && info "the swap file /swapfile-erisbox was kept (remove: swapoff /swapfile-erisbox; rm /swapfile-erisbox; and its /etc/fstab line)"
  return 0
}

# ============================================================= HOOKS/TICK ===
cmd_hook() {
  local type="${1:-}" name
  [ $# -gt 0 ] && shift
  name="${LXC_NAME:-${1:-}}"
  g_exists "$name" || exit 0
  exec 2>>"$LOG_DIR/$name.log" || true
  s_load
  case "$type" in
    prestart)
      if ! ip link show dev "$S_BRIDGE" >/dev/null 2>&1 || ! nft list table ip erisbox_nat >/dev/null 2>&1; then
        net_apply >/dev/null 2>&1 || bridge_up || exit 1
      fi
      g_load "$name"
      ip link del "$(g_veth)" >/dev/null 2>&1
      guest_mount || exit 1 ;;
    poststop) g_load "$name"; guest_umount; exit 0 ;;
    netup) g_load "$name"; tc_apply; exit 0 ;;
    netdown) g_load "$name"; traffic_account down; exit 0 ;;
  esac
}

enforce_note() {
  case "$G_NOTE" in
    expired) log "$G_NAME expired"; guest_stop 20 ;;
    overquota)
      log "$G_NAME reached its traffic limit"
      if [ "$S_QUOTA_ACTION" = throttle ]; then tc_apply; else guest_stop 20; fi ;;
    *) tc_apply ;;
  esac
}

cmd_tick() {
  need_root
  [ -f "$CONF_FILE" ] || exit 0
  exec 8>"$LOCK_FILE"
  flock -n 8 || exit 0
  s_load
  local n today month dom changed total st
  if ! ip link show dev "$S_BRIDGE" >/dev/null 2>&1 || ! nft list table ip erisbox_nat >/dev/null 2>&1; then
    log "network rules missing - re-applying"
    net_apply >/dev/null 2>&1
  else
    ipt_compat; ips_ensure
  fi
  today="$(date +%F)"; month="$(date +%Y-%m)"; dom="$(date +%-d)"
  for n in $(g_names); do
    g_load "$n"; changed=0; st=0
    traffic_account
    if [ "${G_RESET_DAY:-0}" -gt 0 ] && [ "$dom" -ge "$G_RESET_DAY" ] && [ "$G_RESET_TAG" != "$month" ]; then
      traffic_reset; G_RESET_TAG="$month"; changed=1
      if [ "$G_NOTE" = overquota ]; then G_NOTE=""; [ "$G_AUTOSTART" = 1 ] && st=1; fi
    fi
    if [ "${G_TRAFFIC_GB:-0}" != 0 ] && [ -z "$G_NOTE" ]; then
      total="$(traffic_total)"
      if [ "$total" -ge "$(gb_to_bytes "$G_TRAFFIC_GB")" ]; then G_NOTE=overquota; changed=1; fi
    fi
    if [ -n "$G_EXPIRE" ] && [[ "$today" > "$G_EXPIRE" ]] && [ "$G_NOTE" != expired ]; then G_NOTE=expired; changed=1; fi
    if [ "$changed" = 1 ]; then
      g_save; lxc_write_config
      if [ -n "$G_NOTE" ]; then enforce_note
      elif [ "$st" = 1 ]; then guest_start >/dev/null; tc_apply
      fi
    fi
  done
}

# ================================================================== MENU ===
menu_header() {
  local n run=0 tot=0
  [ -t 1 ] && clear 2>/dev/null
  for n in $(g_names); do tot=$((tot + 1)); g_running "$n" && run=$((run + 1)); done
  printf '%s%s' "$C_M" "$C_BD"
  cat <<'EOF'
   ___      _         ___
  | __|_ _ (_)___    | _ ) _____ __
  | _|| '_|| (_-<    | _ \/ _ \ \ /
  |___|_|  |_/__/    |___/\___/_\_\
EOF
  printf '%s  %sv%s - small isolated machines on one server%s\n' "$C_0" "$C_D" "$SCRIPT_VER" "$C_0"
  if is_installed; then
    printf '  %s%s CPU | RAM %s free of %s | swap %s | disk %s free | IP %s | machines %s/%s running%s\n' "$C_C" \
      "$(host_cpus)" "$(human "$(host_memavail)")" "$(human "$(host_mem)")" "$(human "$(host_swap)")" \
      "$(human "$(disk_free "$VAR_DIR")")" "$(public_ip)" "$run" "$tot" "$C_0"
  fi
}
run_action() { ( "$@" ); local rc=$?; pause; return "$rc"; }

pick_machine() { # -> PICKED
  local names=() n i=1 c
  mapfile -t names < <(g_names)
  [ "${#names[@]}" -gt 0 ] || { warn "no machines yet - create one first"; return 1; }
  echo
  for n in "${names[@]}"; do printf '   %2d) %-16s %s\n' "$i" "$n" "$(g_state "$n")"; i=$((i + 1)); done
  echo
  ask c "Machine (number or name, empty = back)" ""
  [ -n "$c" ] || return 1
  if valid_int "$c" && [ "$c" -ge 1 ] && [ "$c" -le "${#names[@]}" ]; then PICKED="${names[$((c - 1))]}"
  elif g_exists "$c"; then PICKED="$c"
  else err "no such machine"; return 1
  fi
}

menu_main() {
  need_root
  trap 'printf "\n"' INT
  local c
  while true; do
    menu_header
    if ! is_installed; then
      printf '\n  %sEris Box is not installed on this server yet.%s\n\n   1) Install now\n   0) Exit\n\n' "$C_Y" "$C_0"
      ask c "Choose" ""
      case "$c" in 1) run_action cmd_install ;; 0|q) exit 0 ;; esac
      continue
    fi
    s_load
    cat <<EOF

   ${C_BD}Machines${C_0}
     1) Create a machine
     2) List machines
     3) Manage a machine
   ${C_BD}Network${C_0}
     4) Dedicated IPs
     5) Domain proxy (websites on ports 80/443)
   ${C_BD}Server${C_0}
     6) Server resources and usage (cores, RAM, disk: total / given / free)
     7) Backups
     8) Settings
     9) Install / repair
    10) Update Eris Box
    11) Uninstall
     0) Exit

EOF
    ask c "Choose" ""
    case "$c" in
      1) run_action cmd_create ;;
      2) run_action cmd_list ;;
      3) PICKED=""; pick_machine && menu_machine "$PICKED" ;;
      4) menu_ips "" ;;
      5) menu_domains ;;
      6) run_action cmd_status ;;
      7) menu_backups ;;
      8) menu_settings ;;
      9) run_action cmd_install ;;
      10) ( cmd_update ) && exec "$BIN_PATH" menu; pause ;;
      11) run_action cmd_uninstall; [ -x "$BIN_PATH" ] || exit 0 ;;
      0|q|exit) exit 0 ;;
    esac
  done
}

menu_machine() {
  local n="$1" c
  while g_exists "$n"; do
    menu_header
    ( s_load; g_load "$n"; show_info )
    cat <<EOF

     1) Start              2) Stop              3) Restart
     4) Change CPU / RAM / swap / disk / process and disk-speed limits
     5) Port forwards
     6) Dedicated IPs
     7) Speed limit, traffic limit, expiry
     8) Reset root password
     9) Open a root shell inside
    10) Reinstall the OS (erases its files)
    11) Backup now
    12) Delete this machine
     0) Back

EOF
    ask c "Choose" ""
    case "$c" in
      1) run_action cmd_power start "$n" ;;
      2) run_action cmd_power stop "$n" ;;
      3) run_action cmd_power restart "$n" ;;
      4) menu_resources "$n" ;;
      5) menu_ports "$n" ;;
      6) menu_ips "$n" ;;
      7) menu_plan "$n" ;;
      8) run_action cmd_passwd "$n" ;;
      9) ( cmd_console "$n" ); pause ;;
      10) run_action cmd_reinstall "$n" ;;
      11) run_action cmd_backup "$n" ;;
      12) run_action cmd_delete "$n" ;;
      0|b|q|"") return 0 ;;
    esac
  done
}

menu_resources() {
  (
    s_load; g_load "$1"
    local cpu ram swap disk pids iom ioi args=()
    printf '\n%sServer resources%s (without %s):\n' "$C_BD" "$C_0" "$1"
    res_compute "$1"; res_show
    printf '\n  %s now has: CPU %s | RAM %s | swap %s | disk %s\n\n' "$1" "$G_CPU" "$G_RAM" "$G_SWAP" "$G_DISK"
    ask cpu "CPU cores (free without $1: $R_CPU_LEFT)" "$G_CPU"
    ask ram "RAM (free without $1: $(human "$(( R_MEM_LEFT > 0 ? R_MEM_LEFT : 0 ))"))" "$G_RAM"
    ask swap "Swap (free without $1: $(human "$(( R_SWAP_LEFT > 0 ? R_SWAP_LEFT : 0 ))"))" "$G_SWAP"
    ask disk "Disk ($(human "$R_DFREE") free; growing works live, shrinking needs the machine stopped)" "$G_DISK"
    oversell_warn "$cpu" "$ram" "$swap"
    ask pids "Max processes" "$G_PIDS"
    ask iom "Disk speed limit in MB/s (0 = none)" "$G_IO_MBPS"; ask ioi "Disk IOPS limit (0 = none)" "$G_IO_IOPS"
    [ "$cpu" != "$G_CPU" ] && args+=(--cpu "$cpu")
    [ "${ram^^}" != "$G_RAM" ] && args+=(--ram "$ram")
    [ "${swap^^}" != "$G_SWAP" ] && args+=(--swap "$swap")
    [ "${disk^^}" != "$G_DISK" ] && args+=(--disk "$disk")
    [ "$pids" != "$G_PIDS" ] && args+=(--pids "$pids")
    { [ "$iom" != "$G_IO_MBPS" ] || [ "$ioi" != "$G_IO_IOPS" ]; } && args+=(--io-mbps "$iom" --io-iops "$ioi")
    [ "${#args[@]}" -gt 0 ] || { info "nothing changed"; exit 0; }
    cmd_set "$1" "${args[@]}"
  )
  pause
}

menu_plan() {
  (
    s_load; g_load "$1"
    local sp tr rd ex rn args=()
    echo
    printf '  Traffic used: %s\n\n' "$(traffic_text)"
    ask sp "Speed limit in Mbit/s (0 = none)" "$G_SPEED"
    ask tr "Monthly traffic limit in GB (0 = none)" "$G_TRAFFIC_GB"
    ask rd "Reset the traffic counter on day (1-28, 0 = never)" "$G_RESET_DAY"
    ask ex "Expiry date (YYYY-MM-DD, never, or a number of days from today)" "${G_EXPIRE:-never}"
    [ "$sp" != "$G_SPEED" ] && args+=(--speed "$sp")
    [ "$tr" != "$G_TRAFFIC_GB" ] && args+=(--traffic "$tr")
    [ "$rd" != "$G_RESET_DAY" ] && args+=(--reset-day "$rd")
    [ "$ex" != "${G_EXPIRE:-never}" ] && args+=(--expire "$ex")
    if [ "${#args[@]}" -gt 0 ]; then cmd_set "$1" "${args[@]}"; fi
    ask rn "Reset the traffic counter now? (y/n)" n
    if [[ "$rn" =~ ^[Yy] ]]; then cmd_traffic "$1" --reset; fi
  )
  pause
}

menu_ports() {
  local n="$1" c
  while true; do
    (
      s_load; g_load "$n"
      printf '\n  %sPort forwards of %s%s (on %s)\n' "$C_BD" "$n" "$C_0" "$(public_ip)"
      printf '    SSH   : %s -> port 22 inside\n' "$G_SSH_PORT"
      for e in $G_PORTS; do printf '    Ports : %s\n' "$(port_entry_text "$e")"; done
    )
    printf '\n     1) Add a port or range\n     2) Remove a port or range\n     3) Change the SSH port\n     0) Back\n\n'
    ask c "Choose" ""
    case "$c" in
      1) (
           local spec proto
           echo "  Examples: 25565   |   30000-30010   |   8080:80 (server port 8080 -> machine port 80)"
           ask spec "Port(s)" ""; ask proto "Protocol (tcp / udp / both)" both
           cmd_port add "$n" "$spec" --proto "$proto"
         ); pause ;;
      2) ( local p; ask p "Server port to remove (any port of the range)" ""; cmd_port del "$n" "$p" ); pause ;;
      3) ( local p; ask p "New SSH port (or auto)" auto; cmd_port ssh "$n" "$p" ); pause ;;
      *) return 0 ;;
    esac
  done
}

cmd_port() {
  local sub="${1:-list}"; [ $# -gt 0 ] && shift
  parse_flags "$@"; need_root; need_installed; s_load
  local name="${POS[0]:-}" spec="${POS[1]:-}" proto e new="" found=0 p
  g_load "$name"
  case "$sub" in
    list|ls)
      printf '  SSH: %s:%s -> 22\n' "$(public_ip)" "$G_SSH_PORT"
      for e in $G_PORTS; do printf '  %s:%s\n' "$(public_ip)" "$(port_entry_text "$e")"; done ;;
    add)
      proto="$(flag proto both)"
      case "$proto" in tcp|udp|both) ;; *) die "--proto tcp|udp|both" ;; esac
      take_lock; g_load "$name"
      build_port_map ""   # (re-parses every entry, so parse the new spec only afterwards)
      port_spec "$spec" || die "use a port (8080), a range (30000-30010) or server:machine (8080:80)"
      port_free "$proto" "$P_HS" "$P_HE" || die "already used by $PORT_OWNER"
      G_PORTS="${G_PORTS:+$G_PORTS }$proto:$P_HS-$P_HE:$P_GS"
      g_save; net_apply
      log "port add $name $spec $proto"
      ok "forwarded $(public_ip):$(port_entry_text "$proto:$P_HS-$P_HE:$P_GS") to $name" ;;
    del|delete|rm|remove)
      valid_port "$spec" || die "usage: erisbox port del NAME SERVER_PORT"
      take_lock; g_load "$name"
      p=$((10#$spec))
      for e in $G_PORTS; do
        port_entry_parse "$e"
        if [ "$p" -ge "$P_HS" ] && [ "$p" -le "$P_HE" ]; then found=1; else new="${new:+$new }$e"; fi
      done
      [ "$found" = 1 ] || die "$name has no forward that includes port $p"
      G_PORTS="$new"; g_save; net_apply
      log "port del $name $p"
      ok "removed the forward containing port $p" ;;
    ssh)
      take_lock; g_load "$name"
      build_port_map "$name"
      if [ "$spec" = auto ] || [ -z "$spec" ]; then p="$(alloc_ssh_port)" || die "no free port"
      else valid_port "$spec" || die "invalid port"; p=$((10#$spec)); port_free tcp "$p" "$p" || die "already used by $PORT_OWNER"
      fi
      for e in $G_PORTS; do port_entry_parse "$e"; [ "$P_PROTO" != udp ] && [ "$p" -ge "$P_HS" ] && [ "$p" -le "$P_HE" ] && die "port $p is inside this machine's own forward $P_HS-$P_HE"; done
      G_SSH_PORT="$p"; g_save; net_apply
      ok "SSH of $name is now: ssh root@$(public_ip) -p $p" ;;
    *) die "usage: erisbox port list NAME | add NAME SPEC [--proto tcp|udp|both] | del NAME PORT | ssh NAME PORT|auto" ;;
  esac
}

menu_ips() {
  local only="$1" c
  while true; do
    ( ip_list )
    printf '\n     1) Add a dedicated IP to a machine\n     2) Remove a dedicated IP\n     0) Back\n\n'
    ask c "Choose" ""
    case "$c" in
      1) (
           local m="$only" ip
           if [ -z "$m" ]; then PICKED=""; pick_machine || exit 0; m="$PICKED"; fi
           echo "  First buy an extra IPv4 from your server provider and attach it to THIS server."
           ask ip "Extra public IPv4 for $m" ""
           [ -n "$ip" ] && ip_add "$m" "$ip"
         ); pause ;;
      2) (
           local m="$only" ip
           if [ -z "$m" ]; then PICKED=""; pick_machine || exit 0; m="$PICKED"; fi
           ask ip "IP to remove from $m" ""
           [ -n "$ip" ] && ip_del "$m" "$ip"
         ); pause ;;
      *) return 0 ;;
    esac
  done
}

menu_domains() {
  local c
  while true; do
    ( cmd_domain list )
    printf '\n     1) Enable the domain proxy\n     2) Add a domain to a machine\n     3) Remove a domain\n     4) Send unknown HTTPS domains to a port on this server\n     5) Send unknown HTTP domains to a port on this server\n     6) Disable the domain proxy\n     0) Back\n\n'
    ask c "Choose" ""
    case "$c" in
      1) run_action cmd_domain enable ;;
      2) (
           local d w
           PICKED=""; pick_machine || exit 0
           ask d "Domain (example.com)" ""
           ask w "Also all its subdomains? (y/n)" n
           if [[ "$w" =~ ^[Yy] ]]; then cmd_domain add "$PICKED" "$d" --wildcard; else cmd_domain add "$PICKED" "$d"; fi
         ); pause ;;
      3) ( local d; ask d "Domain to remove" ""; cmd_domain del "$d" ); pause ;;
      4) ( local h; ask h "IP:PORT for unknown TLS names (none = reject)" "none"; cmd_domain default-tls "$h" ); pause ;;
      5) ( local h; ask h "IP:PORT for unknown HTTP names (none = 404)" "none"; cmd_domain default-http "$h" ); pause ;;
      6) run_action cmd_domain disable ;;
      *) return 0 ;;
    esac
  done
}

menu_backups() {
  local c
  while true; do
    printf '\n  %sBackups in %s%s\n' "$C_BD" "$BACKUP_DIR" "$C_0"
    find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.zst' -printf '    %f  (%s bytes)\n' 2>/dev/null | sort || true
    printf '\n     1) Back up a machine\n     2) Restore a backup\n     0) Back\n\n'
    ask c "Choose" ""
    case "$c" in
      1) ( PICKED=""; pick_machine || exit 0; cmd_backup "$PICKED" ); pause ;;
      2) (
           local f nn
           ask f "Backup file (full path or file name in $BACKUP_DIR)" ""
           [ -f "$f" ] || f="$BACKUP_DIR/$f"
           ask nn "Name for the restored machine (empty = original name)" ""
           if [ -n "$nn" ]; then cmd_restore "$f" "$nn"; else cmd_restore "$f"; fi
         ); pause ;;
      *) return 0 ;;
    esac
  done
}

menu_settings() {
  local c k v
  while true; do
    printf '\n  %sSettings%s\n' "$C_BD" "$C_0"
    ( cmd_settings show )
    printf '\n  Type a setting name to change it (SUBNET and BRIDGE are fixed), or Enter to go back.\n'
    ask k "Setting" ""
    [ -n "$k" ] || return 0
    k="${k^^}"
    ( s_load; local cur="S_$k"; ask v "New value for $k" "${!cur-}"; setting_set "$k" "$v" ); pause
  done
}

# ================================================================== HELP ===
usage() {
  cat <<EOF
Eris Box $SCRIPT_VER - small isolated machines (LXC) on one server

Usage: erisbox [command] [options]        (no command = interactive menu)

Machines
  create NAME [--os OS] [--cpu 0.2] [--ram 200M] [--swap 1G] [--disk 2G]
              [--pids 512] [--ssh-port N|auto] [--ports N|FIRST-LAST|none]
              [--password P] [--ssh-key "KEY"] [--speed MBIT] [--traffic GB]
              [--reset-day 1-28] [--expire DAYS|YYYY-MM-DD] [--tun on]
              [--io-mbps N] [--io-iops N] [--no-start]
  list [--json]                       info NAME
  start | stop | restart NAME (or --all)
  set NAME [--cpu] [--ram] [--swap] [--disk] [--pids] [--io-mbps] [--io-iops]
           [--speed] [--traffic] [--reset-day] [--expire DAYS|DATE|never]
           [--autostart on|off] [--tun on|off]
  renew NAME DAYS|YYYY-MM-DD [--reset-traffic]
  traffic NAME [--reset]
  passwd NAME ['ANY PASSWORD']        (any characters; or --password '...')
  sshkey NAME "ssh-ed25519 AAAA..."
  console NAME                        exec NAME -- COMMAND...
  reinstall NAME [--os OS] [--password P]
  backup NAME                         restore FILE [NEW_NAME]
  delete NAME

Network
  port list NAME | port add NAME 8080:80|30000-30010 [--proto tcp|udp|both]
  port del NAME PORT | port ssh NAME PORT|auto
  ip list | ip add NAME IP [--iface CARD --gw GATEWAY --local ADDRESS --force]
  ip del NAME IP                      (max $MAX_IPS dedicated IPs per machine)
  domain list | enable | disable | add NAME DOMAIN [--wildcard] | del DOMAIN
  domain default-http|default-tls IP:PORT|none
  apply                               rebuild bridge, NAT and firewall rules

Server
  install [--swap SIZE | --no-swap] [--prebuild]
  resources                           server cores / RAM / swap / disk: total, given, free
  status                              image list | build OS | delete OS
  settings [show | set KEY VALUE]     update | uninstall [--purge]

OS: $OS_LIST
Add -y to answer yes to every question.
EOF
}

# ================================================================== MAIN ===
main() {
  local cmd="${1:-menu}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    -y|--yes) YES=1; main "$@"; return ;;
    menu) menu_main ;;
    install|repair) cmd_install "$@" ;;
    create|new|add) cmd_create "$@" ;;
    list|ls) cmd_list "$@" ;;
    info|show) cmd_info "$@" ;;
    start|stop|restart) cmd_power "$cmd" "$@" ;;
    set|resize|limit) cmd_set "$@" ;;
    renew) cmd_renew "$@" ;;
    traffic) cmd_traffic "$@" ;;
    port|ports) cmd_port "$@" ;;
    ip|ips) cmd_ip "$@" ;;
    domain|domains|proxy) cmd_domain "$@" ;;
    passwd|password) cmd_passwd "$@" ;;
    sshkey|ssh-key) cmd_sshkey "$@" ;;
    console|shell|enter) cmd_console "$@" ;;
    exec) cmd_exec "$@" ;;
    reinstall|rebuild) cmd_reinstall "$@" ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    delete|remove|rm|destroy) cmd_delete "$@" ;;
    status|host|stats) cmd_status "$@" ;;
    resources|res|free) cmd_resources "$@" ;;
    image|images) cmd_image "$@" ;;
    settings|config) cmd_settings "$@" ;;
    apply) cmd_apply "$@" ;;
    update|upgrade) cmd_update "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    _hook) cmd_hook "$@" ;;
    _tick) cmd_tick "$@" ;;
    _refresh) refresh_all ;;
    version|-v|--version) echo "Eris Box $SCRIPT_VER" ;;
    help|-h|--help) usage ;;
    *) err "unknown command: $cmd"; usage; exit 1 ;;
  esac
}

# tests source this file with ERISBOX_SOURCE_ONLY=1 to reach the functions
[ "${ERISBOX_SOURCE_ONLY:-0}" = 1 ] || main "$@"
