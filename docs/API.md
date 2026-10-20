# Eris Box API (for selling bots)

A small JSON API over HTTPS. Your Telegram bot (or website) can sell machines directly:
the customer pays, the bot calls `POST /machines` with a plan, and the reply already contains
the SSH address, port and password, plus a ready-made message (English and Persian).

Everything the API does goes through the `erisbox` command with the same checks, the same
lock and the same logs, so the API and the menu never get in each other's way.

## 1. Set it up (on the server)

```bash
# what you sell: one or more plans
erisbox plan add small  --title "Small VPS"  --cpu 0.2 --ram 200M --swap 1G --disk 2G --days 30 --traffic 100
erisbox plan add medium --title "Medium VPS" --cpu 0.5 --ram 512M --swap 1G --disk 5G --days 30

# start the API (HTTPS on port 9443, a first token called "bot" is printed)
erisbox api enable

# recommended: only your bot's server may call it
erisbox api allow 203.0.113.50

erisbox api status      # URL, allowed IPs, tokens, certificate pin, a test command
erisbox api pin         # the certificate pin for your bot (see "TLS" below)
erisbox api token add shop             # more tokens (each shown once)
erisbox api token add viewer --read-only
erisbox api token list | erisbox api token del NAME
```

Everything is also in the menu: **12) Sales plans** and **13) API for selling bots**.

**TLS.** `erisbox api enable` creates a self-signed certificate. Your bot accepts exactly
this server's key by *pinning* it (`erisbox api pin`, e.g. `sha256//r1Xq...=`). With curl:
`--pinnedpubkey`, with PHP: `CURLOPT_PINNEDPUBLICKEY`. If you have a domain and a real
certificate, use it instead: `erisbox api enable --cert /path/fullchain.pem --key /path/key.pem`.

**Sale limits.** The API never oversells past `SELL_MAX_RAM_PCT` (default 150 % of the RAM
minus 256M for the server) and `SELL_MAX_CPU_PCT` (default 300 % of the cores), and never
past the real free disk. When a plan does not fit any more, `GET /plans` shows
`"available": false` and `POST /machines` answers `409 server_full`. Change the limits with
`erisbox settings set SELL_MAX_RAM_PCT 200` (0 = no limit).

## 2. Calling it

- Base URL: `https://SERVER_IP:9443/api/v1`
- Header: `Authorization: Bearer eb_...` (or `X-API-Key: eb_...`)
- Bodies are JSON. Every answer is JSON with `"ok": true|false`.
- Errors look like `{"ok": false, "error": "human readable text", "code": "server_full"}`.

| HTTP | code | meaning |
|---|---|---|
| 400 | `failed`, `bad_value`, `bad_json` | wrong input (the text says what) |
| 401 | `unauthorized` | missing or wrong token |
| 403 | `forbidden`, `read_only` | IP not allowed, or a read-only token tried to change something |
| 404 | `not_found` | no such machine, plan, job or path |
| 405 | `method_not_allowed` | wrong HTTP method for the path |
| 409 | `server_full` | the plan does not fit on the server any more |
| 409 | `conflict`, `not_running`, `blocked` | name taken, machine stopped, machine expired / over its traffic |
| 429 | `too_many_attempts` | 10 wrong tokens from one IP: blocked for 15 minutes |

## 3. Endpoints

| Method | Path | Body | Answer |
|---|---|---|---|
| GET | `/ping` | (no token needed) | `{"ok":true}` |
| GET | `/plans` | | `plans`: name, title, os, cpu, ram, swap, disk, days, traffic_gb, **available** |
| GET | `/resources` | | server cores / RAM / swap / disk: total, given, free |
| GET | `/os` | | operating systems and whether their image is ready |
| GET | `/machines` | | `machines`: list of machine objects |
| POST | `/machines` | `{"plan":"small"}` (+ optional fields below) | **201** `machine` |
| GET | `/machines/NAME` | | `machine` |
| PATCH | `/machines/NAME` | `{"ram":"512M","cpu":0.5,"disk":"4G","speed":20,"traffic":200,"expire":"2027-01-31"}` | `machine` |
| DELETE | `/machines/NAME` | | `{"deleted":"NAME"}` |
| POST | `/machines/NAME/renew` | `{"days":30}` or `{"until":"2027-01-31"}` or `{}` (one period of its plan), optional `"reset_traffic":true` | `machine` |
| POST | `/machines/NAME/password` | `{"password":"anything"}` or `{}` for a random one | `machine` (with the new password) |
| POST | `/machines/NAME/start` · `/stop` · `/restart` | | `machine` |
| POST | `/machines/NAME/reinstall` | `{"os":"debian-12","password":"..."}` (erases the machine) | `machine` |
| POST | `/machines/NAME/traffic/reset` | | `machine` |
| POST | `/machines/NAME/ips` | `{"ip":"5.6.7.8"}` (an extra IPv4 already attached to the server) | `machine` |
| DELETE | `/machines/NAME/ips/5.6.7.8` | | `machine` |
| POST | `/machines/NAME/ports` | `{"port":"25565","proto":"tcp"}` (`8080`, `"30000-30010"`, `"8080:80"`) | `machine` |
| DELETE | `/machines/NAME/ports/25565` | | `machine` |
| GET | `/jobs/JOB` | | state of an `async` create |

**`POST /machines` fields** (all optional except that you give a plan or sizes):
`plan`, `name` (a-z 0-9 -, otherwise one like `u7k2m9xq` is made), `password` (anything,
otherwise random), `ssh_key`, `os`, `cpu`, `ram`, `swap`, `disk`, `days` or `expire`,
`traffic` (GB/month), `speed` (Mbit/s), `ports` (count or `"none"`), `ssh_port`, `pids`,
`tun` (true/false), `async` (true/false). Fields you give override the plan.

**Async create.** Creating a machine takes about 10-60 seconds (several minutes for the very
first machine of an OS, while its image is downloaded; `erisbox image build OS` prepares it
in advance). If your bot can't wait that long, send `"async": true`. You get
`202 {"job":"3f9a..."}` at once, then poll `GET /jobs/3f9a...` until `"status"` is `done`
(with `machine`) or `failed` (with `error`).

### The machine object

```json
{
  "name": "u7k2m9xq", "state": "RUNNING", "note": "", "plan": "small",
  "os": "ubuntu-24.04", "os_label": "Ubuntu 24.04",
  "cpu": 0.2, "ram": "200M", "ram_bytes": 209715200, "swap": "1G", "disk": "2G", "pids": 512,
  "host": "1.2.3.4", "ssh_port": 2203, "username": "root", "password": "q8XbT2mRk0aLz7Vc",
  "ssh": "ssh root@1.2.3.4 -p 2203",
  "ports": [{"proto": "both", "from": 20021, "to": 20030, "machine_port": 20021,
             "text": "1.2.3.4:20021-20030 (tcp+udp, same numbers inside)"}],
  "ips": [], "domains": [],
  "speed_mbit": 0, "traffic_limit_gb": 100, "traffic_used_bytes": 1048576,
  "expire": "2026-11-20", "created": "2026-10-21", "autostart": true, "private_ip": "10.88.0.13",
  "usage": {"ram_bytes": 52428800, "swap_bytes": 0, "disk_bytes": 431001600},
  "text": "Your server is ready\nName: u7k2m9xq\n...",
  "text_fa": "سرور شما آماده است\nنام: u7k2m9xq\n..."
}
```

`note` is `""`, `"expired"` or `"overquota"`. Expired or over-quota machines are stopped
automatically. `renew` (or `traffic/reset`) brings them back. `text` and `text_fa` hold the
connection details only (no RAM / CPU / disk), ready to send to the customer.

## 4. Examples

```bash
API=https://1.2.3.4:9443/api/v1
TOKEN=eb_xxxxxxxx
PIN='sha256//r1Xq...='        # erisbox api pin
ask() { curl -sk --pinnedpubkey "$PIN" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }

ask "$API/plans"
ask -X POST "$API/machines" -d '{"plan":"small"}'
ask -X POST "$API/machines/u7k2m9xq/renew" -d '{}'
ask -X POST "$API/machines/u7k2m9xq/password" -d '{"password":"my new pass"}'
ask -X DELETE "$API/machines/u7k2m9xq"
```

### PHP (for a Telegram bot)

```php
<?php
const ERIS_API   = 'https://1.2.3.4:9443/api/v1';
const ERIS_TOKEN = 'eb_xxxxxxxx';
const ERIS_PIN   = 'sha256//r1Xq...=';    // erisbox api pin

function eris(string $method, string $path, ?array $body = null): array
{
    $ch = curl_init(ERIS_API . $path);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST   => $method,
        CURLOPT_RETURNTRANSFER  => true,
        CURLOPT_HTTPHEADER      => ['Authorization: Bearer ' . ERIS_TOKEN, 'Content-Type: application/json'],
        CURLOPT_SSL_VERIFYPEER  => false,      // self-signed certificate ...
        CURLOPT_SSL_VERIFYHOST  => 0,
        CURLOPT_PINNEDPUBLICKEY => ERIS_PIN,   // ... but only this server's key is accepted
        CURLOPT_TIMEOUT         => 300,
    ]);
    if ($body !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body, JSON_UNESCAPED_UNICODE));
    }
    $raw = curl_exec($ch);
    curl_close($ch);
    return $raw === false ? ['ok' => false, 'code' => 'network', 'error' => 'API unreachable'] : json_decode($raw, true);
}

// the customer paid for "small":
$r = eris('POST', '/machines', ['plan' => 'small']);
if ($r['ok']) {
    $machine = $r['machine']['name'];          // store it with the customer (for renewals)
    sendMessage($chatId, $r['machine']['text_fa']);
} elseif ($r['code'] === 'server_full') {
    sendMessage($chatId, 'این پلن فعلاً موجود نیست');
} else {
    sendMessage($adminId, 'Eris Box: ' . $r['error']);
}

// next month:
eris('POST', "/machines/$machine/renew", ['reset_traffic' => true]);
```

## 5. Notes

- The API runs as `erisbox-api.service` (Python 3 standard library, ~15 MB RAM) and writes
  `/var/lib/erisbox/logs/api.log` (time, IP, token name, method, path, status, never bodies).
- Tokens are stored as SHA-256 hashes in `/etc/erisbox/api-tokens`. A lost token can't be
  shown again: delete it and add a new one.
- Machines can't reach the API (traffic from machines to the server itself is blocked).
- `erisbox api disable` stops it. Tokens, certificate and plans are kept.
