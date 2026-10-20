#!/usr/bin/env bash
# shellcheck disable=SC2034  # the globals set here are read by the sourced erisbox.sh functions
# Fast unit tests for the helper functions of erisbox.sh.
# Run: bash tests/unit.sh   (as root it also syntax-checks the generated nftables rules)
cd "$(dirname "$0")/.." || exit 1
export ERISBOX_SOURCE_ONLY=1
# shellcheck source=../erisbox.sh
. ./erisbox.sh

T=0; FAILS=0
eq()  { T=$((T + 1)); [ "$2" = "$3" ] || { echo "FAIL: $1: expected '$3', got '$2'"; FAILS=$((FAILS + 1)); }; }
yes() { T=$((T + 1)); "$@" >/dev/null 2>&1 || { echo "FAIL: expected success: $*"; FAILS=$((FAILS + 1)); }; }
no()  { T=$((T + 1)); ! "$@" >/dev/null 2>&1 || { echo "FAIL: expected failure: $*"; FAILS=$((FAILS + 1)); }; }

# sizes
eq "to_bytes 200M" "$(to_bytes 200M)" 209715200
eq "to_bytes 1G" "$(to_bytes 1G)" 1073741824
eq "to_bytes 1.5g" "$(to_bytes 1.5g)" 1610612736
eq "to_bytes 512 (MB)" "$(to_bytes 512)" 536870912
eq "to_bytes 2GB" "$(to_bytes 2GB)" 2147483648
eq "to_bytes 0" "$(to_bytes 0)" 0
no to_bytes abc
no to_bytes -1
no to_bytes 1X
eq "human 200M" "$(human 209715200)" 200M
eq "human 1.5G" "$(human 1610612736)" 1.5G
eq "human 1G" "$(human 1073741824)" 1G
eq "human 0" "$(human 0)" 0B

# cpu + numbers
eq "cpu_quota 0.2" "$(cpu_quota 0.2)" 20000
eq "cpu_quota 1" "$(cpu_quota 1)" 100000
eq "cpu_quota 0.05" "$(cpu_quota 0.05)" 5000
eq "norm_num 0.20" "$(norm_num 0.20)" 0.2
eq "norm_num 1.0" "$(norm_num 1.0)" 1
eq "norm_num 100" "$(norm_num 100)" 100
eq "norm_num 0.000001" "$(norm_num 0.000001)" 0.000001
eq "gb_to_bytes 1" "$(gb_to_bytes 1)" 1073741824

# names, addresses, ports
for v in alice web-1 a1 abcdefghijklmnopqrstuvwxyz012345; do yes valid_name "$v"; done
for v in 1abc -abc a Alice a_b abc- abcdefghijklmnopqrstuvwxyz0123456; do no valid_name "$v"; done
yes valid_ipv4 1.2.3.4
yes valid_ipv4 255.255.255.255
for v in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d ""; do no valid_ipv4 "$v"; done
yes valid_port 1
yes valid_port 65535
for v in 0 65536 abc ""; do no valid_port "$v"; done
yes valid_hostport 127.0.0.1:8443
no valid_hostport localhost:80
yes valid_domain example.com
yes valid_domain sub.example.co.uk
yes valid_domain site1.test
for v in -bad.com "ex ample.com" com Example.com; do no valid_domain "$v"; done
for v in Test-Pass-1234 x "has space" "quote'x" 'dq"x' "colon:x" 'dollar$x' 'back\slash' 'رمز عبور ۱۲۳' " lead and trail "; do
  yes valid_password "$v"
done
no valid_password ""
no valid_password $'two\nlines'
no valid_password "$(printf 'a%.0s' {1..257})"
yes valid_sshkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKey user@host"
no valid_sshkey "not a key"
yes valid_url http://archive.ubuntu.com/ubuntu
no valid_url "ftp://x"
for v in eth0 ens4 enp0s3 eth0.100 veth@if2; do yes valid_iface "$v"; done
for v in ../../etc "a/b" "" .. "eth 0" abcdefghijklmnop; do no valid_iface "$v"; done

port_spec 8080;        eq "port_spec 8080" "$P_HS $P_HE $P_GS" "8080 8080 8080"
port_spec 30000-30010; eq "port_spec range" "$P_HS $P_HE $P_GS" "30000 30010 30000"
port_spec 8080:80;     eq "port_spec map" "$P_HS $P_HE $P_GS" "8080 8080 80"
for v in 70000 10-5 1-2000 80:0 abc; do no port_spec "$v"; done
port_entry_parse both:20001-20010:20001
eq "port_entry_parse" "$P_PROTO $P_HS $P_HE $P_GS" "both 20001 20010 20001"
eq "port_entry_text range" "$(port_entry_text both:20001-20010:20001)" "20001-20010 (tcp+udp, same numbers inside)"
eq "port_entry_text map" "$(port_entry_text tcp:8080-8080:80)" "8080 -> machine port 80 (tcp)"

# dates
eq "expire 0" "$(expire_value 0)" ""
eq "expire never" "$(expire_value never)" ""
eq "expire date" "$(expire_value 2030-12-31)" 2030-12-31
eq "expire days" "$(expire_value 30)" "$(date -d '+30 days' +%F)"
no expire_value 2026-02-30
no expire_value abc

# ip math
eq "ip2int/int2ip" "$(int2ip "$(ip2int 10.88.0.1)")" 10.88.0.1
eq "ip2int" "$(ip2int 0.0.1.2)" 258

# derived machine values
s_defaults; S_SUBNET=10.88; g_reset; G_ID=5; G_NAME=t
eq "gw_ip" "$(gw_ip)" 10.88.0.1
eq "g_ip" "$(g_ip)" 10.88.0.15
eq "g_ip2" "$(g_ip2)" 10.88.1.15
eq "g_mac" "$(g_mac)" 02:eb:00:00:00:05
eq "g_veth" "$(g_veth)" ebx5
eq "g_base" "$(g_base)" $((1000000 + 5 * 65536))

# conf files round trip
TMPD="$(mktemp -d)"
CONF_FILE="$TMPD/erisbox.conf"; GUEST_DIR="$TMPD/guests"; DOMAIN_FILE="$TMPD/domains"
TRAFFIC_DIR="$TMPD/traffic"; LOG_DIR="$TMPD/logs"; VAR_DIR="$TMPD"; mkdir -p "$GUEST_DIR"
s_defaults; S_DNS="9.9.9.9 1.0.0.1"; S_PUBLIC_IP=203.0.113.9; s_save
s_defaults; s_load
eq "settings round trip DNS" "$S_DNS" "9.9.9.9 1.0.0.1"
eq "settings round trip IP" "$S_PUBLIC_IP" 203.0.113.9
eq "kv_get" "$(kv_get "$CONF_FILE" PUBLIC_IP)" 203.0.113.9
( S_DNS="bad'quote"; s_save ) >/dev/null 2>&1 && { echo "FAIL: s_save accepted a quote"; FAILS=$((FAILS + 1)); }
T=$((T + 1))

# two fake machines for allocation + rule generation
g_reset; G_NAME=alpha; G_ID=1; G_UIDBASE=1065536; G_OS=ubuntu-24.04; G_CPU=0.2; G_RAM=200M; G_SWAP=1G; G_DISK=2G
G_SSH_PORT=2201; G_PORTS="both:20001-20010:20001 tcp:8080-8080:80"; G_IPS="198.51.100.7,198.51.100.7,eth0,,1"; g_save
g_reset; G_NAME=beta; G_ID=2; G_UIDBASE=1131072; G_OS=debian-12; G_CPU=0.5; G_RAM=300M; G_SWAP=0; G_DISK=3G
G_SSH_PORT=2202; G_PORTS=""; G_IPS="192.0.2.10,192.0.2.10,lo,192.0.2.1,0;198.51.100.8,198.51.100.8,eth0,,1"; g_save
eq "g_names" "$(g_names | paste -sd, -)" "alpha,beta"

# root password with any characters: stored base64, never in plain text
WEIRD=$'p a$s:w"o\'rd \\ ü رمز'
g_load alpha; G_PASSWORD="$WEIRD"; g_save
T=$((T + 1)); grep -q "^PASSWORD64='" "$GUEST_DIR/alpha.conf" && ! grep -q "^PASSWORD=" "$GUEST_DIR/alpha.conf" \
  || { echo "FAIL: password not stored as PASSWORD64"; FAILS=$((FAILS + 1)); }
g_load alpha; eq "password round trip" "$G_PASSWORD" "$WEIRD"
printf "PASSWORD='old-plain-pass'\nID='9'\n" > "$GUEST_DIR/legacy.conf"
g_load legacy; eq "1.0 conf with a plain PASSWORD still loads" "$G_PASSWORD" old-plain-pass
rm -f "$GUEST_DIR/legacy.conf"
T=$((T + 1)); [ "$(pw_hash "$WEIRD" | cut -c1-3)" = '$6$' ] || { echo "FAIL: pw_hash is not SHA-512 crypt"; FAILS=$((FAILS + 1)); }

# JSON for the API stays valid with any password
if command -v python3 >/dev/null 2>&1; then
  g_load alpha
  T=$((T + 1))
  info_json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["password"]==sys.argv[1], d["password"]; assert d["name"]=="alpha"; assert d["ports"][0]["from"]==20001' "$WEIRD" \
    || { echo "FAIL: info_json is not valid JSON or loses the password"; FAILS=$((FAILS + 1)); }
  T=$((T + 1))
  list_json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert [m["name"] for m in d]==["alpha","beta"]' \
    || { echo "FAIL: list_json"; FAILS=$((FAILS + 1)); }
  T=$((T + 1))
  [ "$(json_str $'a"b\\c\nd')" = '"a\"b\\c\nd"' ] || { echo "FAIL: json_str escaping"; FAILS=$((FAILS + 1)); }
fi
no valid_password $'tab\there'

# login banner: valid sh, shows name + OS, never resource numbers
banner_script > "$TMPD/banner.sh"
yes sh -n "$TMPD/banner.sh"
BANNER_OUT="$(sh "$TMPD/banner.sh" 2>&1)"
T=$((T + 1)); grep -q "System" <<<"$BANNER_OUT" || { echo "FAIL: banner has no System line"; FAILS=$((FAILS + 1)); }
T=$((T + 1)); grep -qiwE 'ram|swap|disk|cpu|memory' "$TMPD/banner.sh" && { echo "FAIL: banner mentions resources"; FAILS=$((FAILS + 1)); }
T=$((T + 1)); [ "$(hostname | tr '[:lower:]' '[:upper:]' | cut -c1)" = "$(grep -o '◆.*' <<<"$BANNER_OUT" | sed 's/\x1b\[[0-9;]*m//g; s/◆ *//' | cut -c1)" ] \
  || { echo "FAIL: banner title is not the machine name"; FAILS=$((FAILS + 1)); }
eq "alloc_id" "$(alloc_id)" 3
eq "alloc_base keeps a free preferred base" "$(alloc_base $((1000000 + 7 * 65536)))" $((1000000 + 7 * 65536))
eq "alloc_base skips a used base" "$(alloc_base 1065536)" $((1000000 + 3 * 65536))
g_load beta
eq "ips_count" "$(ips_count)" 2
g_load alpha
eq "ips_count alpha" "$(ips_count)" 1
build_port_map ""
no port_free tcp 2201 2201
no port_free udp 20005 20005
yes port_free udp 8080 8080
no port_free tcp 8080 8080
eq "alloc_ssh_port skips used" "$(S_SSH_PORT_START=2201; alloc_ssh_port)" "$( p=2203; while ss -Hlnt "sport = :$p" 2>/dev/null | grep -q .; do p=$((p + 1)); done; echo $p)"

# server resources: totals vs what the machines got
res_compute
eq "res count" "$R_COUNT" 2
eq "res cpu given" "$R_CPU_GIVEN" 0.7
eq "res ram given" "$R_MEM_GIVEN" $((500 * 1048576))
eq "res swap given" "$R_SWAP_GIVEN" 1073741824
eq "res disk given" "$R_DISK_GIVEN" $((5 * 1073741824))
res_compute alpha
eq "res without alpha" "$R_COUNT $R_CPU_GIVEN" "1 0.5"
yes res_show
# (capture first: with pipefail, "grep -q" closing the pipe early would fail the producer)
OUT="$(res_show)"
T=$((T + 1)); grep -q "CPU cores" <<<"$OUT" || { echo "FAIL: res_show has no CPU line"; FAILS=$((FAILS + 1)); }
res_compute; R_CPUS=1
OUT="$(oversell_warn 0.5 100M 0 2>&1)"
T=$((T + 1)); grep -q "CPU oversold" <<<"$OUT" || { echo "FAIL: no CPU oversell warning"; FAILS=$((FAILS + 1)); }
OUT="$(oversell_warn 0.1 1M 0 2>&1)"
T=$((T + 1)); grep -q "CPU oversold" <<<"$OUT" && { echo "FAIL: false CPU oversell warning"; FAILS=$((FAILS + 1)); }
yes cpu_ok 0.2
no cpu_ok 0
no cpu_ok abc
yes size_ok 200M 64M
no size_ok 10M 64M
no size_ok lots 64M

# API server against a fake erisbox: auth, read-only tokens, routing, errors, lockout
if command -v python3 >/dev/null 2>&1; then
  api_py > "$TMPD/api.py"
  T=$((T + 1)); python3 -m py_compile "$TMPD/api.py" || { echo "FAIL: api.py does not compile"; FAILS=$((FAILS + 1)); }
  cat > "$TMPD/fake-erisbox" <<'EOF'
#!/bin/bash
case "$1" in
  list) echo '[{"name":"alpha"}]' ;;
  plan) echo '[{"name":"small","available":true}]' ;;
  resources) echo '{"cpus":1}' ;;
  info) if [ "$2" = nope ]; then echo "[x] machine 'nope' not found (see: erisbox list)" >&2; exit 1; fi
        printf '{"name":"%s","password":"x"}\n' "$2" ;;
  create) printf '%s\n' "$@" > "$(dirname "$0")/create-args"   # (the API passes a clean environment)
          [ "$2" = full ] && { echo "[x] server is full: RAM sale limit reached" >&2; exit 1; }
          exit 0 ;;
  *) echo "[x] unsupported in the fake" >&2; exit 1 ;;
esac
EOF
  chmod +x "$TMPD/fake-erisbox"
  APORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  printf "PORT='%s'\nTLS='0'\nBIND='127.0.0.1'\nALLOW=''\n" "$APORT" > "$TMPD/api.conf"
  printf 'bot:%s:full:2026-01-01\nro:%s:read:2026-01-01\n' \
    "$(printf 'eb_full' | sha256sum | cut -d' ' -f1)" "$(printf 'eb_read' | sha256sum | cut -d' ' -f1)" > "$TMPD/api-tokens"
  ERISBOX_API_CONF="$TMPD/api.conf" ERISBOX_API_TOKENS="$TMPD/api-tokens" ERISBOX_API_LOG="$TMPD/api.log" \
    ERISBOX_BIN="$TMPD/fake-erisbox" python3 "$TMPD/api.py" &
  APID=$!
  for _ in $(seq 1 50); do python3 -c "import socket; socket.create_connection(('127.0.0.1',$APORT),1)" 2>/dev/null && break; sleep 0.1; done
  cat > "$TMPD/client.py" <<'EOF'
import json, sys, urllib.request, urllib.error
base = "http://127.0.0.1:%s/api/v1" % sys.argv[1]
argfile = sys.argv[2]
fails = 0
def req(method, path, body=None, token="eb_full", raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    r = urllib.request.Request(base + path, data=data, method=method)
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())
def check(name, got, want_status, test=lambda d: True):
    global fails
    st, d = got
    if st != want_status or not test(d):
        fails += 1
        print("FAIL: api %s: got %s %s" % (name, st, d))
check("ping", req("GET", "/ping", token=None), 200, lambda d: d["ok"])
check("no token", req("GET", "/machines", token=None), 401, lambda d: d["code"] == "unauthorized")
check("list", req("GET", "/machines"), 200, lambda d: d["machines"][0]["name"] == "alpha")
check("plans", req("GET", "/plans"), 200, lambda d: d["plans"][0]["name"] == "small")
check("info", req("GET", "/machines/alpha"), 200, lambda d: d["machine"]["password"] == "x")
check("not found", req("GET", "/machines/nope"), 404, lambda d: d["code"] == "not_found")
check("read-only create", req("POST", "/machines", {"plan": "small"}, token="eb_read"), 403, lambda d: d["code"] == "read_only")
check("create", req("POST", "/machines", {"plan": "small", "name": "newbox", "password": 'a b"c', "cpu": 0.25, "tun": True}), 201,
      lambda d: d["machine"]["name"] == "newbox")
args = open(argfile).read().split("\n")
for want in (["--plan", "small"], ["--password", 'a b"c'], ["--cpu", "0.25"], ["--tun", "on"], ["--strict"]):
    if not all(w in args for w in want):
        fails += 1
        print("FAIL: api create args miss %s: %s" % (want, args))
check("server full", req("POST", "/machines", {"name": "full"}), 409, lambda d: d["code"] == "server_full")
check("bad value", req("POST", "/machines", {"cpu": {"x": 1}}), 400, lambda d: d["code"] == "bad_value")
check("newline value", req("POST", "/machines", {"password": "a\nb"}), 400, lambda d: d["code"] == "bad_value")
check("bad json", req("POST", "/machines", raw=b"{nope"), 400, lambda d: d["code"] == "bad_json")
check("wrong method", req("PUT", "/machines"), 405, lambda d: d["code"] == "method_not_allowed")
check("unknown path", req("GET", "/nothing"), 404)
check("bad name in path", req("GET", "/machines/../etc"), 404)
for _ in range(10):
    req("GET", "/machines", token="wrong")
check("lockout after 10 wrong tokens", req("GET", "/machines", token="eb_full"), 429, lambda d: d["code"] == "too_many_attempts")
sys.exit(1 if fails else 0)
EOF
  T=$((T + 1))
  python3 "$TMPD/client.py" "$APORT" "$TMPD/create-args" || { echo "FAIL: API checks (see above)"; FAILS=$((FAILS + 1)); }
  kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
fi

RULES="$(S_PROXY_ENABLED=1; nft_render eth0)"
for want in 'tcp dport 2201 dnat to 10.88.0.11:22' 'tcp dport 20001-20010 dnat to 10.88.0.11' \
            'udp dport 20001-20010 dnat to 10.88.0.11' 'tcp dport 8080 dnat to 10.88.0.11:80' \
            'ip daddr 198.51.100.7 dnat to 10.88.0.11' 'ip saddr 10.88.0.11 snat to 198.51.100.7' \
            'ip daddr 192.0.2.10 dnat to 10.88.0.12' 'ip daddr 198.51.100.8 dnat to 10.88.1.12' \
            'ct original ip daddr 192.0.2.10 meta mark set' 'ether saddr != 02:eb:00:00:00:02 drop' \
            'tcp dport { 80, 443 } accept' 'tcp dport 25 drop'; do
  T=$((T + 1))
  grep -qF -- "$want" <<<"$RULES" || { echo "FAIL: generated rules lack: $want"; FAILS=$((FAILS + 1)); }
done
if [ "$(id -u)" = 0 ] && command -v nft >/dev/null 2>&1; then
  T=$((T + 1))
  printf '%s\n' "$RULES" > "$TMPD/rules.nft"
  if ! nft -c -f "$TMPD/rules.nft"; then echo "FAIL: nft rejects the generated rules"; cat -n "$TMPD/rules.nft"; FAILS=$((FAILS + 1)); fi
else
  echo "(skipping the nft syntax check - needs root and nftables)"
fi
rm -rf "$TMPD"

echo "unit tests: $((T - FAILS))/$T passed"
[ "$FAILS" = 0 ]
