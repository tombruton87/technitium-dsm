# Technitium DNS Server's hooks for the chassis core (sourced by run-core.sh).
# The core gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, fresh, now, wait_ready, make_backup, record_backup, MSG, VAR,
# APP, LOG, PKG_NAME, PKG_TITLE, and the tls_* helpers (chassis tls.sh).
#
# The first start: the package writes a throwaway password into the config
# volume (DNS_SERVER_ADMIN_PASSWORD_FILE, read by Technitium only when it has
# no config yet), signs in with it once, makes itself a non-expiring API token
# (kept in the root-only .env), sets your password (shown once, never stored)
# and deletes the throwaway file. Everything after goes through Technitium's
# HTTP API with that token, on the container's own address inside Docker's
# network (always plain HTTP on 5380 there, whatever the console's HTTPS).

TN=""
TN_REPO=technitium/dns-server
TN_PINNED=technitium/dns-server:15.6.1
TN_DEFAULT_LIST=https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    DNS_PORT)   [[ "$2" =~ ^[0-9]{2,5}$ ]] && (( 10#$2 >= 1 && 10#$2 <= 65535 )) ;;
    TLS)        [[ "$2" =~ ^(dsm|self|off)$ ]] ;;
    NET_MODE)   [[ "$2" =~ ^(host|bridge)$ ]] ;;
    PAUSE_MIN)  [[ "$2" =~ ^(5|30|60)$ ]] ;;
    URL_B64)    [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 700 )) ;;
    KIND)       [[ "$2" =~ ^(allow|block)$ ]] ;;
    DOMAIN)     [[ "$2" =~ ^[a-z0-9_]([a-z0-9_-]{0,62}\.)+[a-z0-9]([a-z0-9-]{0,62})$ ]] && (( ${#2} <= 253 )) ;;
    ZONE)       [[ "$2" =~ ^[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62}))*$ ]] && (( ${#2} <= 253 )) ;;
    REC_TYPE)   [[ "$2" =~ ^(A|AAAA|CNAME)$ ]] ;;
    REC_VALUE)  [[ "$2" =~ ^[A-Za-z0-9.:-]+$ ]] && (( ${#2} <= 253 )) ;;
    RESOLVER)   [[ "$2" =~ ^(forward|recursive)$ ]] ;;
    UPSTREAM)   [[ "$2" =~ ^(cloudflare|quad9|google|custom)$ ]] ;;
    DNS_PROTO)  [[ "$2" =~ ^(https|tls|udp)$ ]] ;;
    CUSTOM_DNS) [[ "$2" =~ ^[0-9.]{7,15}(\+[0-9.]{7,15})?$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ talking to Technitium
b64d() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }   # is version $1 newer than $2?
tn_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$TN" 2>/dev/null | awk '{print $1}'; }
tn_base() {   # Technitium's API: the container's own address on Docker's network; on the NAS itself in host mode
  if [[ "$(env_get NET_MODE)" == host ]]; then echo "http://127.0.0.1:$(env_get HTTP_PORT)/api"; return 0; fi
  local ip; ip=$(tn_ip); [[ -n "$ip" ]] && echo "http://$ip:5380/api"
}
# Network mode. "bridge": Docker's network, ports published on the NAS's LAN address; every device shows up as
# Docker's gateway. "host": Technitium on the NAS's own network, so it sees each device's address; it is told to
# answer DNS on the LAN address only (DSM keeps 127.0.0.1:53 on many models) and to serve its console on the
# package's port. The core always runs compose.yaml; in host mode this extra file is added on top of it.
compose() {
  local f=(-f "$APP/compose.yaml")
  if [[ "$(env_get NET_MODE)" == host ]]; then write_host_compose; f+=(-f "$APP/compose.host.yaml"); fi
  docker compose "${f[@]}" --project-directory "$APP" "$@"
}
write_host_compose() {
  cat > "$APP/compose.host.yaml.tmp" <<'YAML'
# Written by the package in host mode, on top of compose.yaml: Technitium on the NAS's own network.
services:
  server:
    network_mode: host
    ports: !reset []
    sysctls: !reset []
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://127.0.0.1:${HTTP_PORT:-5380}/ >/dev/null"]
YAML
  mv "$APP/compose.host.yaml.tmp" "$APP/compose.host.yaml"
}
sync_net() {   # [mode] — tell Technitium where to listen for DNS and its console, for that network mode
  local m=${1:-$(env_get NET_MODE)}
  if [[ "$m" == host ]]; then
    tn settings/set "dnsServerLocalEndPoints=$(env_get DNS_BIND):$(env_get DNS_PORT)" "webServiceHttpPort=$(env_get HTTP_PORT)" >/dev/null
  else
    tn settings/set "dnsServerLocalEndPoints=0.0.0.0:53,[::]:53" webServiceHttpPort=5380 >/dev/null
  fi
}
net_ok() {   # does Technitium already listen where this mode needs it?
  local s; s=$(tn settings/get) || return 1
  if [[ "$(env_get NET_MODE)" == host ]]; then
    jq -e --arg e "$(env_get DNS_BIND):$(env_get DNS_PORT)" --argjson p "$(env_get HTTP_PORT)" \
      '(.dnsServerLocalEndPoints == [$e]) and (.webServiceHttpPort == $p)' <<< "$s" >/dev/null
  else jq -e '(.webServiceHttpPort == 5380) and ((.dnsServerLocalEndPoints | index("0.0.0.0:53")) != null)' <<< "$s" >/dev/null; fi
}
tn_raw() {   # path token [name=value…] → Technitium's whole JSON answer; 0 when its status is ok
  local base out; base=$(tn_base) || return 1; [[ -n "$base" ]] || return 1
  local args=(); local kv; for kv in "${@:3}"; do args+=(--data-urlencode "$kv"); done
  out=$(curl -s --max-time "${TN_TIMEOUT:-30}" -X POST "$base/$1" --data-urlencode "token=$2" "${args[@]}" 2>/dev/null)
  printf '%s' "$out"; [[ "$(jq -r '.status // empty' <<< "$out" 2>/dev/null)" == ok ]]
}
tn() {   # path [name=value…] → .response on stdout with the package's token; the error message in TN_WHY
  local out; TN_WHY=""
  if out=$(tn_raw "$1" "$(env_get TN_TOKEN)" "${@:2}"); then jq -c '.response // {}' <<< "$out"; return 0; fi
  TN_WHY=$(jq -r '.errorMessage // .status // empty' <<< "$out" 2>/dev/null | head -c 200); [[ -n "$TN_WHY" ]] || TN_WHY="Technitium isn't answering"
  return 1
}
forwarders_for() {   # upstream protocol [custom] → FW (comma-separated, Technitium's form) and FWP
  local c=$3
  case "$2" in https) FWP=Https ;; tls) FWP=Tls ;; *) FWP=Udp ;; esac
  case "$1:$2" in
    cloudflare:https) FW="https://cloudflare-dns.com/dns-query (1.1.1.1),https://cloudflare-dns.com/dns-query (1.0.0.1)" ;;
    cloudflare:tls)   FW="cloudflare-dns.com (1.1.1.1:853),cloudflare-dns.com (1.0.0.1:853)" ;;
    cloudflare:*)     FW="1.1.1.1,1.0.0.1" ;;
    quad9:https)      FW="https://dns.quad9.net/dns-query (9.9.9.9),https://dns.quad9.net/dns-query (149.112.112.112)" ;;
    quad9:tls)        FW="dns.quad9.net (9.9.9.9:853),dns.quad9.net (149.112.112.112:853)" ;;
    quad9:*)          FW="9.9.9.9,149.112.112.112" ;;
    google:https)     FW="https://dns.google/dns-query (8.8.8.8),https://dns.google/dns-query (8.8.4.4)" ;;
    google:tls)       FW="dns.google (8.8.8.8:853),dns.google (8.8.4.4:853)" ;;
    google:*)         FW="8.8.8.8,8.8.4.4" ;;
    custom:*)         FW=${c//+/,}; FWP=Udp ;;   # your own servers: plain DNS (an encrypted one needs its name, which the window doesn't ask)
  esac
}
apply_resolver() {   # from .env → Technitium's forwarders (or none: it resolves by itself)
  if [[ "$(env_get RESOLVER)" == recursive ]]; then tn settings/set forwarders=false forwarderProtocol=Udp >/dev/null; return; fi
  forwarders_for "$(env_get UPSTREAM)" "$(env_get DNS_PROTO)" "$(env_get CUSTOM_DNS)"
  [[ -n "$FW" ]] || { TN_WHY="no upstream servers given"; return 1; }
  tn settings/set "forwarders=$FW" "forwarderProtocol=$FWP" >/dev/null
}
dns_port_taken() {   # → what else holds the DNS port where Technitium wants it (empty when free, or ours)
  local p b; p=$(env_get DNS_PORT); p=${p:-53}; b=$(env_get DNS_BIND); b=${b:-0.0.0.0}
  svc_up server && return 0
  # TCP and UDP, every address: another listener clashes when it's on our address or on all of them, and
  # when we want all addresses (0.0.0.0), anything on the port clashes — 127.0.0.1 included.
  ss -lntupH 2>/dev/null | awk -v p="$p" -v b="$b" '{ split($5, a, ":"); port = a[length(a)]; host = substr($5, 1, length($5) - length(port) - 1)
      gsub(/[\[\]]/, "", host); sub(/%.*/, "", host)
      if (port != p) next
      if (b != "0.0.0.0" && host != b && host != "0.0.0.0" && host != "*" && host != "::") next
      who = ($NF ~ /users:/) ? $NF : ""; sub(/^users:\(\("/, "", who); sub(/".*/, "", who)
      print $1 " " $5 (who != "" ? " (" who ")" : ""); exit }'
}
dns_holder_hint() {   # the usual Synology suspects, from the process name when ss could see it
  case "$1" in
    *named*)   echo "DSM's DNS Server package — Package Center → DNS Server → Stop" ;;
    *dnsmasq*) echo "DSM's own dnsmasq, used by its DHCP Server or VPN Server — turn off the one you don't need, or keep Technitium on the LAN address" ;;
    *samba*)   echo "Synology Directory Server, which runs its own DNS" ;;
    *docker-proxy*) echo "another container that publishes port $(env_get DNS_PORT) — see Container Manager" ;;
    *)         echo "another service — DSM's DNS Server package is the usual one (Package Center → DNS Server → Stop)" ;;
  esac
}
zone_for() {   # name → the zone (one of Technitium's own, not built-in) that holds it, or nothing
  tn zones/list | jq -r --arg d "$1" '[.zones[]? | select(.internal != true and (.type == "Primary" or .type == "Forwarder")) | .name
    | select(. as $z | $d == $z or ($d | endswith("." + $z)))] | sort_by(length) | last // empty' 2>/dev/null
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  env_set TN_IMAGE "$TN_PINNED"
  env_set NET_MODE "${NET_MODE:-host}"   # new installs: each device's own address in Technitium's logs
  env_set DNS_PORT "${DNS_PORT:-53}"
  env_set RESOLVER forward; env_set UPSTREAM cloudflare; env_set DNS_PROTO https; env_set CUSTOM_DNS ""
  env_set TN_FIRST_PW "$(rand 32)"; env_set TN_PFX_PW "$(rand 24)"
  env_set TLS "${TLS:-off}"; env_set INNER_PORT 5380
  tls_fix_scheme || true
  touch "$VAR/.needs-admin"
}
app_load_env() {
  TN=$(cname server)
  [[ -n "$(env_get NET_MODE)" ]] || env_set NET_MODE bridge   # installs from before the setting: as they were
  [[ -n "$(env_get DNS_BIND)" ]] || env_set DNS_BIND "$(env_get LAN_IP)"
  # A newer package brings a newer tested Technitium: move the pin forward (never back), with a backup first.
  local cur pin=${TN_PINNED##*:}
  cur=$(tn_tag)
  if [[ -n "$cur" ]] && newer "$pin" "$cur"; then
    say "this package brings Technitium $pin (installed: $cur) — a backup first"
    if make_backup pre-update; then record_backup true "$MADE"; env_set TN_IMAGE "$TN_PINNED"; say "Technitium moves to $pin; the state from before is in $MADE"
    else say "✗ couldn't back up first, so Technitium stays at $cur for now"; fi
  fi
  return 0
}
app_before_up() {
  local who
  [[ -n "$(env_get TLS)" ]] || env_set TLS off
  [[ -n "$(env_get TN_PFX_PW)" ]] || env_set TN_PFX_PW "$(rand 24)"
  # DNS listens on the NAS's LAN address, not every address: DSM keeps 127.0.0.1:53 for itself on many models.
  [[ -n "$(env_get DNS_BIND)" ]] || env_set DNS_BIND "$(env_get LAN_IP)"
  who=$(dns_port_taken)
  # Stop here with one sentence rather than letting Docker fail and the start be retried.
  [[ -z "$who" ]] || failed "DNS port $(env_get DNS_PORT) on $(env_get DNS_BIND) is already in use ($who). That's usually $(dns_holder_hint "$who"). Free it, then Package Center → $PKG_TITLE → Run."
  if [[ -f "$VAR/.needs-admin" && -n "$(env_get TN_FIRST_PW)" ]]; then   # only read by Technitium while it has no config yet
    printf '%s' "$(env_get TN_FIRST_PW)" | in_volume config rw -- '[ -f /vol/dns.config ] || { umask 077; cat > /vol/first-password; }' 2>>"$LOG" || true
  fi
  setup_tls || say "✗ HTTPS couldn't be set up: $MSG"
}
setup_tls() {   # Technitium reads a PKCS#12 file: made from DSM's (or a self-signed) certificate, in the config volume
  tls_fix_scheme || true
  tls_prepare config || return 1
  if [[ "$(env_get TLS_SOURCE)" =~ ^(dsm|self)$ ]]; then
    in_volume config rw -- "openssl pkcs12 -export -out /vol/tls.pfx.tmp -inkey /vol/tls/privkey.pem -in /vol/tls/fullchain.pem -passout pass:$(env_get TN_PFX_PW) && chmod 600 /vol/tls.pfx.tmp && mv /vol/tls.pfx.tmp /vol/tls.pfx" </dev/null 2>>"$LOG" \
      || { MSG="The certificate couldn't be put in place for Technitium."; return 1; }
    env_set INNER_PORT 53443
  else env_set INNER_PORT 5380; fi
  return 0
}
sync_web() {   # Technitium's console serves HTTPS on 53443 exactly when the package's setting says so
  local s want; s=$(tn settings/get) || return 1
  [[ "$(env_get TLS_SOURCE)" =~ ^(dsm|self)$ ]] && want=true || want=false
  if [[ "$want" == true ]]; then
    tn settings/set webServiceEnableTls=true webServiceTlsPort=53443 webServiceHttpToTlsRedirect=false webServiceUseSelfSignedTlsCertificate=false \
      webServiceTlsCertificatePath=/etc/dns/tls.pfx "webServiceTlsCertificatePassword=$(env_get TN_PFX_PW)" >/dev/null || return 1
  elif [[ "$(jq -r '.webServiceEnableTls' <<< "$s")" == true ]]; then
    tn settings/set webServiceEnableTls=false >/dev/null || return 1
  fi
  touch "$VAR/.web-check"
}
app_health() { local b; b=$(tn_base) || return 1; [[ -n "$b" ]] && [[ -n "$(curl -s --max-time 5 "$b/user/session/get" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)" ]]; }
tn_tag() { local i=${1:-$(env_get TN_IMAGE)}; [[ "$i" =~ ^technitium/dns-server:([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]] && echo "${BASH_REMATCH[1]}"; true; }
app_version() {
  local v; v=$(tn settings/get 2>/dev/null | jq -r '.version // empty' 2>/dev/null) || true
  [[ -n "$v" ]] || v=$(tn_tag)
  printf '%s' "$v" | tr -cd '0-9A-Za-z.-' | head -c 30
}
app_after_up() {
  make_admin 90
  [[ -n "$(env_get TN_TOKEN)" ]] || return 0
  sync_web || say "✗ the console's HTTPS setting didn't apply: $TN_WHY"
  if ! net_ok; then
    say "telling Technitium where to listen for the $(env_get NET_MODE) network"
    sync_net || say "✗ Technitium didn't take the listening addresses: $TN_WHY"
  fi
  true
}
make_admin() {   # [tries] — the first time: the package's token, then your password (shown once)
  [[ -f "$VAR/.needs-admin" ]] || return 0
  local i first out sess token pw
  for i in $(seq 1 "${1:-1}"); do app_health && break; sleep 2; done
  app_health || { say "Technitium isn't answering yet — its admin password is set when it does"; return 0; }
  first=$(env_get TN_FIRST_PW)
  out=$(TN_TIMEOUT=15 tn_raw user/login "" user=admin "pass=$first") && sess=$(jq -r '.token // empty' <<< "$out")
  if [[ -z "${sess:-}" ]]; then
    say "✗ Technitium didn't take the package's first password — its config volume is from before (an earlier install?). Its own admin password still applies; the window can't manage it. Removing the package with its data and installing again starts over."
    rm -f "$VAR/.needs-admin"; return 0
  fi
  out=$(tn_raw user/createToken "" user=admin "pass=$first" tokenName=dsm-package) && token=$(jq -r '.token // empty' <<< "$out")
  [[ -n "${token:-}" ]] || { say "✗ Technitium didn't make the package's API token: $(jq -r '.errorMessage // empty' <<< "$out")"; return 0; }
  env_set TN_TOKEN "$token"
  pw=$(strong_password)
  tn admin/users/set user=admin "newPass=$pw" >/dev/null || { say "✗ your Technitium password couldn't be set: $TN_WHY — trying again shortly"; return 0; }
  tn_raw user/logout "$sess" >/dev/null || true
  # Sensible defaults: one well-known blocklist, blocking on, Cloudflare over DNS-over-HTTPS.
  tn settings/set "blockListUrls=$TN_DEFAULT_LIST" enableBlocking=true blockListUpdateIntervalHours=24 >/dev/null || say "✗ the default blocklist wasn't set: $TN_WHY"
  apply_resolver || say "✗ the upstream DNS wasn't set: $TN_WHY"
  tn settings/forceUpdateBlockLists >/dev/null || true
  docker exec "$TN" rm -f /etc/dns/first-password >> "$LOG" 2>&1 || in_volume config rw -- 'rm -f /vol/first-password' </dev/null 2>>"$LOG" || true
  env_set TN_FIRST_PW ""
  # Technitium writes its users and tokens to disk only when it stops cleanly: a restart now keeps both.
  docker restart -t 30 "$TN" >> "$LOG" 2>&1 || true
  for i in $(seq 1 60); do app_health && break; sleep 1; done
  leave_secret "Technitium (user admin)" "$pw" setup; rm -f "$VAR/.needs-admin"
  say "first start: Technitium's admin password was set (shown once in the window); the package uses an API token of its own"
}

# ------------------------------------------------------------ what the window shows
app_status() {
  svc_up server || { echo '{"up": false}'; return 0; }
  local set='{}' stats='{}' top='[]' blocked='[]' allowed='[]' zones='[]' api=1 z recs
  set=$(tn settings/get) || { set='{}'; api=0; }
  stats=$(tn dashboard/stats/get type=LastDay | jq -c '.stats // {}') || stats='{}'
  if (( api )) && { fresh "$VAR/watching" 30 || [[ ! -s "$VAR/tn-detail.json" ]]; }; then   # the lists only while the window is open
    top=$(tn dashboard/stats/getTop type=LastDay statsType=TopBlockedDomains limit=10 | jq -c '[.topBlockedDomains[]? | {domain: .name, count: .hits}]') || top='[]'
    blocked=$(tn_export blocked) || blocked='[]'
    allowed=$(tn_export allowed) || allowed='[]'
    local zl; zl=$(tn zones/list | jq -c '[.zones[]? | select(.internal != true) | {name, type, disabled}] | .[:20]') || zl='[]'
    zones='[]'
    for z in $(jq -r '.[].name' <<< "$zl"); do
      recs=$(tn zones/records/get "zone=$z" "domain=$z" listZone=true | jq -c '[.records[]? | select(.type != "SOA" and .type != "NS")
        | {name, type, ttl, disabled, value: (.rData.ipAddress // .rData.cname // .rData.value // .rData.text // "")}] | .[:100]') || recs='[]'
      zones=$(jq -c --arg z "$z" --argjson r "${recs:-[]}" --argjson zl "$zl" '. + [($zl[] | select(.name == $z)) + {records: $r}]' <<< "$zones") || true
    done
    jq -n -c --argjson top "${top:-[]}" --argjson blocked "${blocked:-[]}" --argjson allowed "${allowed:-[]}" --argjson zones "${zones:-[]}" \
      '{top: $top, blocked: $blocked, allowed: $allowed, zones: $zones}' > "$VAR/tn-detail.json.tmp" 2>/dev/null && mv "$VAR/tn-detail.json.tmp" "$VAR/tn-detail.json"
  fi
  [[ -s "$VAR/cert.json" ]] || tls_info config
  [[ -s "$VAR/tn-detail.json" ]] || echo '{}' > "$VAR/tn-detail.json"
  jq -c --argjson s "${set:-{\}}" --argjson st "${stats:-{\}}" --arg url "$(env_get APP_URL)" --arg ip "$(env_get LAN_IP)" --arg dport "$(env_get DNS_PORT)" \
     --arg resolver "$(env_get RESOLVER)" --arg up "$(env_get UPSTREAM)" --arg proto "$(env_get DNS_PROTO)" --arg custom "$(env_get CUSTOM_DNS)" \
     --arg api "$api" --arg net "$(env_get NET_MODE)" --arg bind "$(env_get DNS_BIND)" --arg tls "$(env_get TLS)" --arg tls_source "$(env_get TLS_SOURCE)" --argjson cert "$(cat "$VAR/cert.json" 2>/dev/null || echo null)" \
     '. + {up: true, url: $url, api: ($api == "1"), dns: {ip: $ip, port: ($dport | tonumber? // 53)}, net: {mode: $net, bind: $bind},
           blocking: {enabled: ($s.enableBlocking // false),
                      until: (($s.temporaryDisableBlockingTill // null) | if . == null then null else (sub("\\.[0-9]+"; "") | fromdateiso8601? // null) end)},
           lists: ($s.blockListUrls // []), list_hours: ($s.blockListUpdateIntervalHours // 24),
           stats: {queries: ($st.totalQueries // 0), blocked: ($st.totalBlocked // 0), clients: ($st.totalClients // 0), cached: ($st.totalCached // 0),
                   list_domains: ($st.blockListZones // 0), zones: ($st.zones // 0)},
           resolver: {mode: $resolver, upstream: $up, proto: $proto, custom: ($custom | split("+") | map(select(length > 0))),
                      forwarders: ($s.forwarders // []), protocol: ($s.forwarderProtocol // ""), recursion: ($s.recursion // "")},
           tls: {mode: $tls, source: $tls_source, cert: $cert}}' "$VAR/tn-detail.json" 2>/dev/null || echo '{"up": true}'
}
tn_export() {   # blocked|allowed → your own blocked or allowed sites, as a JSON array (Technitium exports them as text)
  local base; base=$(tn_base) || return 1
  curl -s --max-time 20 -X POST "$base/$1/export" --data-urlencode "token=$(env_get TN_TOKEN)" 2>/dev/null \
    | tr -d '\r' | grep -E '^[A-Za-z0-9_.-]+$' | head -n 500 | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# ------------------------------------------------------------ updates: the pinned release, moved on when you say so
tn_check_image() {   # the newest Technitium release tag on Docker Hub → IMAGE_UPDATE for the window
  local cur latest avail=false
  cur=$(tn_tag)
  [[ -n "$cur" ]] || { IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get TN_IMAGE)" '{checked: $at, image: $img, error: "the image is not a Technitium release the package knows"}'); return 0; }
  latest=$(curl -fsS --max-time 15 "https://hub.docker.com/v2/repositories/$TN_REPO/tags?page_size=50&ordering=last_updated" 2>/dev/null \
    | jq -r '.results[]?.name' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -n 1)
  if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get TN_IMAGE)" '{checked: $at, image: $img, error: "Docker Hub could not be reached"}'); return 0; fi
  newer "$latest" "$cur" && avail=true
  IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get TN_IMAGE)" --arg cur "$cur" --arg latest "$latest" --argjson avail "$avail" \
    '{checked: $at, image: $img, available: $avail, current: $cur, latest: $latest, remote: $latest, local: $cur,
      page: "https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md"}')
  say "Technitium: newest release $latest, this is $cur$([[ "$avail" == true ]] && echo " — an update is available")"
}
app_check_updates() { tn_check_image; }
# The core's update_app pulls whatever the compose file names and then prunes
# every dangling image on the host. Here: back up, pull the newer release found
# by tn_check_image (never a value from a request), restart, and remove only the
# old Technitium image, by name.
update_app() {
  local cur latest old img
  cur=$(tn_tag); latest=$(jq -r '.latest // ""' <<< "$IMAGE_UPDATE" 2>/dev/null)
  if ! [[ -n "$cur" && "$latest" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || ! newer "$latest" "$cur" || ! jq -e '.available == true' <<< "$IMAGE_UPDATE" >/dev/null 2>&1; then
    MSG="There's no newer Technitium to install — look for updates first."; return 1; fi
  old=$(env_get TN_IMAGE); img="$TN_REPO:$latest"
  say "updating Technitium $cur → $latest — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so Technitium wasn't updated."; return 1; }
  record_backup true "$MADE"
  say "pulling $img"
  docker pull "$img" 2>&1 | grep -vE '^\s*$' | tail -n 5 | tee -a "$LOG" >/dev/null
  docker image inspect "$img" >/dev/null 2>&1 || { MSG="Technitium $latest couldn't be downloaded; it stays at $cur."; return 1; }
  env_set TN_IMAGE "$img"
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="Technitium $latest didn't start — see the log. The state from before is in $MADE."; return 1; }
  wait_ready 600 || { MSG="Technitium $latest hasn't answered yet — see the log. The state from before is in $MADE."; return 1; }
  [[ "$old" != "$img" ]] && { docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old image $old" || true; }
  tn_check_image
  MSG="Technitium is updated to $(app_version). The state from before is in $MADE."
}

app_tick() {
  make_admin 1
  svc_up server || return 0
  # The console's HTTPS as the package says (a restore can bring back other web settings).
  fresh "$VAR/.web-check" 600 || { touch "$VAR/.web-check"; [[ -n "$(env_get TN_TOKEN)" ]] && web_drift && { sync_web || true; }; }
  fresh "$VAR/.cert-check" 86400 && return 0; touch "$VAR/.cert-check"
  tls_refresh_dsm config
  [[ "$CERT_REFRESH" == changed ]] && { setup_tls && sync_web; } || true
  return 0
}
web_drift() { local s; s=$(tn settings/get) || return 1; [[ "$(jq -r '.webServiceEnableTls' <<< "$s")" != "$([[ "$(env_get TLS_SOURCE)" =~ ^(dsm|self)$ ]] && echo true || echo false)" ]]; }

# ------------------------------------------------------------ settings, logs, storage, backups, report
app_settings() {
  local want_net=${NET_MODE:-$(env_get NET_MODE)} want_tls=${TLS:-$(env_get TLS)}
  if [[ "$want_net" == host && "$want_tls" != off ]]; then
    MSG="On the NAS's own network, Technitium's console can't share its port with the package's HTTPS. Turn HTTPS off first (DSM's reverse proxy can still add it), or keep Docker's network."; return 1
  fi
  if [[ -n "${NET_MODE:-}" && "$NET_MODE" != "$(env_get NET_MODE)" ]]; then
    # Told first, while it still answers where it is; the container is then made again for the new mode.
    say "network: $(env_get NET_MODE) → $NET_MODE"
    sync_net "$NET_MODE" || say "Technitium will be told where to listen once it's up again ($TN_WHY)"
    env_set NET_MODE "$NET_MODE"
  elif [[ "$(env_get NET_MODE)" == host && -n "${HTTP_PORT:-}" ]]; then
    sync_net host || true   # the console moves with the package's port
  fi
  [[ -n "${TLS:-}" ]] && env_set TLS "$TLS"
  setup_tls || return 1
  # While the network changes, Technitium is told about HTTPS once its new container is up (app_after_settings):
  # until then it isn't where the new mode looks for it.
  [[ -n "${NET_MODE:-}" ]] && return 0
  sync_web || { MSG="Technitium didn't take the HTTPS setting: $TN_WHY"; return 1; }
  return 0
}
app_after_settings() {   # after the container is made again: HTTPS and the listening addresses as the settings say
  sync_web || say "✗ the console's HTTPS setting didn't apply: $TN_WHY"
  net_ok || sync_net || say "✗ Technitium didn't take the listening addresses: $TN_WHY"
  true
}
app_extra_ports() {   # DNS, beside the web console, in DSM's firewall list
  printf '[%s_dns]\ntitle="%s: DNS"\ndesc="%s"\nport_forward="no"\ndst.ports="%s/tcp,udp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$(env_get DNS_PORT)"
}
app_logs() { :; }
app_storage() {
  in_volume config ro -- 'cd /vol; for d in blocklists zones stats; do printf "%s\t%s\n" "$d" "$(du -sm "$d" 2>/dev/null | cut -f1)"; done; true' </dev/null 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
# Technitium keeps users, API tokens and zone permissions in memory and writes
# auth.config only when it starts or stops cleanly. A copy of the live folder (or
# Technitium's own backup file, made from the same files) can therefore lack a
# zone's permissions, and Technitium 15 then fails to start from it. So the copy
# is made with Technitium stopped cleanly: DNS is away for a few seconds.
app_backup() {   # dir — the whole config folder, Technitium stopped cleanly for the moment of the copy
  local was_up=0 rc=0 i
  svc_up server && { was_up=1; docker stop -t 30 "$TN" >/dev/null 2>&1 || true; }
  in_volume config ro -- 'tar -C /vol -czf - --exclude=./first-password .' > "$1/config.tar.gz" 2>>"$LOG" </dev/null || rc=1
  if (( was_up )); then docker start "$TN" >/dev/null 2>&1 || true; for i in $(seq 1 60); do app_health && break; sleep 1; done; fi
  (( rc == 0 )) && grep -q 'auth.config' < <(tar -tzf "$1/config.tar.gz" 2>/dev/null) || { say "✗ Technitium's config folder didn't copy"; return 1; }
}
app_restore() {   # dir — the core has stopped the containers
  [[ -s "$1/config.tar.gz" ]] || { MSG="That backup has no Technitium config folder."; return 1; }
  in_volume config rw -- 'find /vol -mindepth 1 -delete && tar -C /vol -xzf -' < "$1/config.tar.gz" 2>>"$LOG" || { MSG="Technitium's files didn't unpack."; return 1; }
  rm -f "$VAR/.needs-admin" "$VAR/.web-check" "$VAR/tn-detail.json"
}
app_report() {
  local s st; s=$(tn settings/get) || s='{}'; st=$(tn dashboard/stats/get type=LastDay | jq -c '.stats // {}') || st='{}'
  echo "== Technitium $(jq -r '.version // "?"' <<< "$s"); API token works: $([[ "$s" != '{}' ]] && echo yes || echo "no ($TN_WHY)")"
  echo "== last 24 hours: $(jq -r '.totalQueries // "?"' <<< "$st") queries, $(jq -r '.totalBlocked // "?"' <<< "$st") blocked, $(jq -r '.totalClients // "?"' <<< "$st") clients; $(jq -r '.blockListZones // "?"' <<< "$st") domains on blocklists, $(jq -r '.zones // "?"' <<< "$st") zones"
  echo "== blocking: $(jq -c '{enableBlocking, temporaryDisableBlockingTill, blockingType}' <<< "$s" 2>/dev/null)"
  echo "== network: $(env_get NET_MODE); Technitium listens on: $(tn settings/get 2>/dev/null | jq -c '{dns: .dnsServerLocalEndPoints, web: .webServiceHttpPort}' 2>/dev/null)"
  echo "== DNS port $(env_get DNS_PORT) on $(env_get DNS_BIND); who listens on it:"; ss -lntupH 2>/dev/null | awk -v p=":$(env_get DNS_PORT)\$" '$5 ~ p { print "   " $1, $5, $NF }'
  echo "== resolver $(env_get RESOLVER) $(env_get UPSTREAM) $(env_get DNS_PROTO): $(jq -c '{forwarders, forwarderProtocol, recursion}' <<< "$s" 2>/dev/null)"
  echo "== lists"; jq -r '.blockListUrls[]?' <<< "$s" 2>/dev/null
  echo; echo "== HTTPS"; echo "mode $(env_get TLS), in use: $(env_get TLS_SOURCE); console TLS: $(jq -r '.webServiceEnableTls' <<< "$s" 2>/dev/null)"; jq -c 'del(.names)' "$VAR/cert.json" 2>/dev/null
  :
}

# ------------------------------------------------------------ the window's actions
app_act() {   # action (request vars are set)
  local out url lists zone pw
  rm -f "$VAR/tn-detail.json"   # the window's lists are read again after any change
  case "$1" in
    blocking)
      [[ "${ON:-}" =~ ^[01]$ ]] || { MSG="On or off?"; return 1; }
      # A pause's timer outlives turning blocking on or off, and would switch it back on when it runs out: end it first (0 minutes).
      tn settings/temporaryDisableBlocking minutes=0 >/dev/null || true
      tn settings/set "enableBlocking=$([[ "$ON" == 1 ]] && echo true || echo false)" >/dev/null || { MSG="Technitium said no: $TN_WHY"; return 1; }
      MSG=$([[ "$ON" == 1 ]] && echo "Blocking is on." || echo "Blocking is off until you turn it on again.") ;;
    pause)
      tn settings/temporaryDisableBlocking "minutes=${PAUSE_MIN:-5}" >/dev/null || { MSG="Technitium said no: $TN_WHY"; return 1; }
      MSG="Blocking is paused for ${PAUSE_MIN:-5} minutes; it comes back by itself." ;;
    listadd|listdel)
      url=$(b64d "${URL_B64:-}"); [[ "$url" =~ ^https?://[^[:space:],\"\'\<\>]+$ && ${#url} -le 500 ]] || { MSG="A blocklist is a web address (https://…)."; return 1; }
      out=$(tn settings/get) || { MSG="Technitium isn't answering: $TN_WHY"; return 1; }
      if [[ "$1" == listadd ]]; then
        jq -e --arg u "$url" '(.blockListUrls // []) | index($u)' <<< "$out" >/dev/null && { MSG="That list is already there."; return 1; }
        lists=$(jq -r --arg u "$url" '(.blockListUrls // []) + [$u] | join(",")' <<< "$out")
      else
        jq -e --arg u "$url" '(.blockListUrls // []) | index($u)' <<< "$out" >/dev/null || { MSG="That list isn't there any more."; return 1; }
        lists=$(jq -r --arg u "$url" '(.blockListUrls // []) - [$u] | join(",")' <<< "$out"); [[ -n "$lists" ]] || lists=false
      fi
      tn settings/set "blockListUrls=$lists" >/dev/null || { MSG="Technitium said no: $TN_WHY"; return 1; }
      tn settings/forceUpdateBlockLists >/dev/null || true
      MSG=$([[ "$1" == listadd ]] && echo "Added; Technitium is fetching it now." || echo "Removed; its domains are dropped as the lists are read again.") ;;
    listupdate)
      tn settings/forceUpdateBlockLists >/dev/null || { MSG="Technitium said no: $TN_WHY"; return 1; }
      MSG="Technitium is fetching the lists again; the count updates in a minute or two." ;;
    domainadd)
      tn "$([[ "$KIND" == allow ]] && echo allowed || echo blocked)/add" "domain=$DOMAIN" >/dev/null || { MSG="Technitium didn't add it: $TN_WHY"; return 1; }
      MSG=$([[ "$KIND" == allow ]] && echo "$DOMAIN is always allowed now." || echo "$DOMAIN is always blocked now.") ;;
    domaindel)
      tn "$([[ "$KIND" == allow ]] && echo allowed || echo blocked)/delete" "domain=$DOMAIN" >/dev/null || { MSG="Technitium didn't remove it: $TN_WHY"; return 1; }
      MSG="$DOMAIN is off the $([[ "$KIND" == allow ]] && echo allowed || echo blocked) list." ;;
    recadd)
      case "$REC_TYPE" in
        A)     [[ "$REC_VALUE" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { MSG="An A record points at an IPv4 address, like 192.168.1.20."; return 1; } ;;
        AAAA)  [[ "$REC_VALUE" =~ ^[0-9a-fA-F:]{2,39}$ && "$REC_VALUE" == *:* ]] || { MSG="An AAAA record points at an IPv6 address."; return 1; } ;;
        CNAME) [[ "$REC_VALUE" =~ ^[a-z0-9]([a-z0-9-]{0,62}\.)*[a-z0-9]([a-z0-9-]{0,62})$ ]] || { MSG="A CNAME points at another name, like nas.home."; return 1; } ;;
      esac
      zone=$(zone_for "$DOMAIN")
      if [[ -z "$zone" ]]; then
        zone=${DOMAIN#*.}
        tn zones/create "zone=$zone" type=Primary >/dev/null || { MSG="The zone $zone couldn't be made: $TN_WHY"; return 1; }
        say "made the zone $zone for $DOMAIN"
      fi
      [[ "$REC_TYPE" == CNAME && "$DOMAIN" == "$zone" ]] && { MSG="A zone's own name can't be a CNAME — use a name inside it."; return 1; }
      tn zones/records/add "zone=$zone" "domain=$DOMAIN" "type=$REC_TYPE" ttl=3600 overwrite=true \
        "$([[ "$REC_TYPE" == CNAME ]] && echo cname || echo ipAddress)=$REC_VALUE" >/dev/null || { MSG="Technitium didn't add it: $TN_WHY"; return 1; }
      MSG="$DOMAIN → $REC_VALUE, answered by Technitium for your whole network." ;;
    recdel)
      zone=$(zone_for "$DOMAIN"); [[ -n "$zone" ]] || { MSG="There's no zone for $DOMAIN."; return 1; }
      tn zones/records/delete "zone=$zone" "domain=$DOMAIN" "type=$REC_TYPE" \
        "$([[ "$REC_TYPE" == CNAME ]] && echo cname || echo ipAddress)=$REC_VALUE" >/dev/null || { MSG="Technitium didn't remove it: $TN_WHY"; return 1; }
      MSG="$DOMAIN ($REC_TYPE $REC_VALUE) is removed." ;;
    zonedel)
      tn zones/list | jq -e --arg z "$ZONE" '.zones[]? | select(.name == $z and .internal != true)' >/dev/null || { MSG="There's no zone $ZONE of yours."; return 1; }
      tn zones/delete "zone=$ZONE" >/dev/null || { MSG="Technitium didn't delete it: $TN_WHY"; return 1; }
      MSG="The zone $ZONE and its names are deleted." ;;
    resolver)
      if [[ "$RESOLVER" == forward && "$UPSTREAM" == custom && -z "${CUSTOM_DNS:-}" ]]; then MSG="Give one or two DNS server addresses."; return 1; fi
      local o_res o_up o_proto o_custom
      o_res=$(env_get RESOLVER); o_up=$(env_get UPSTREAM); o_proto=$(env_get DNS_PROTO); o_custom=$(env_get CUSTOM_DNS)
      env_set RESOLVER "$RESOLVER"
      [[ -n "${UPSTREAM:-}" ]] && env_set UPSTREAM "$UPSTREAM"
      [[ -n "${DNS_PROTO:-}" ]] && env_set DNS_PROTO "$DNS_PROTO"
      env_set CUSTOM_DNS "$([[ "$(env_get UPSTREAM)" == custom ]] && echo "${CUSTOM_DNS:-}")"
      if ! apply_resolver; then
        env_set RESOLVER "$o_res"; env_set UPSTREAM "$o_up"; env_set DNS_PROTO "$o_proto"; env_set CUSTOM_DNS "$o_custom"
        MSG="Technitium said no: $TN_WHY"; return 1; fi
      if [[ "$RESOLVER" == recursive ]]; then MSG="Technitium now finds every answer itself, from the internet's root servers — no upstream service sees your lookups."
      else forwarders_for "$(env_get UPSTREAM)" "$(env_get DNS_PROTO)" "$(env_get CUSTOM_DNS)"
        MSG="Technitium now asks $(case "$(env_get UPSTREAM)" in cloudflare) echo Cloudflare ;; quad9) echo Quad9 ;; google) echo Google ;; *) sed 's/,/ and /' <<< "$FW" ;; esac) over $(case "$FWP" in Https) echo "DNS-over-HTTPS (encrypted)" ;; Tls) echo "DNS-over-TLS (encrypted)" ;; *) echo "plain DNS" ;; esac)."; fi ;;
    newpw)
      pw=$(strong_password)
      tn admin/users/set user=admin "newPass=$pw" >/dev/null || { MSG="The password wasn't changed: $TN_WHY"; return 1; }
      leave_secret "Technitium (user admin)" "$pw" setup; MSG="Your new password is shown below, once." ;;
    refreshcert)
      tls_refresh_dsm config; setup_tls || return 1; sync_web || { MSG="Technitium didn't take the certificate: $TN_WHY"; return 1; }
      MSG=$([[ "$(env_get TLS_SOURCE)" == dsm ]] && echo "DSM's certificate was read again." || echo "A new self-signed certificate is in use.") ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
