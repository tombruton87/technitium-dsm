# Technitium's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# DNS on port 1054 here: this box's own resolver has 53.
app_e2e_answers() { printf "DNS_PORT='1054'\nTLS='off'\nNET_MODE='bridge'\n"; }
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r 'select(.kind == "setup") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
login_ok() { [[ "$(curl -sk --max-time 10 "$1/api/user/login" --data-urlencode user=admin --data-urlencode "pass=$2" | jq -r .status)" == ok ]]; }
ask() { dig +short +time=3 +tries=2 ${3:-} @127.0.0.1 -p 1054 "$1" "${2:-A}" 2>/dev/null | tail -n 1; }
rcode() {   # BLOCKED when Technitium says so (Extended DNS Error 15), else the response code
  local o; o=$(dig +time=3 +tries=2 @127.0.0.1 -p 1054 "$1" A 2>/dev/null)
  grep -q 'EDE: 15' <<< "$o" && echo BLOCKED || sed -n 's/.*status: \([A-Z]*\).*/\1/p' <<< "$o"; }
until_dns() { local i; for i in $(seq 1 "$3"); do [[ "$($1 "$2")" =~ $4 ]] && return 0; sleep 1; done; return 1; }
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
app_e2e_act() {
  local fail=0 url="http://127.0.0.1:$PORT" pw pw2 listed n name
  log "technitium"
  echo "  (version $(jq -r .version "$VAR/status.json"), image $(jq -r '.image_update.image // "?"' "$VAR/status.json"))"
  [[ "${E2E_PART:-1}" == 1 ]] && { pw=$(secret); printf '%s' "$pw" > "$E2E/.pw"; }
  [[ "${E2E_PART:-1}" == 2 ]] && pw=$(cat "$E2E/.pw" 2>/dev/null)
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time admin password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  login_ok "$url" "$pw" && echo "  ok   it signs in to Technitium as admin" || { echo "  FAIL sign-in"; fail=1; }
  docker exec technitium-server test -e /etc/dns/first-password && { echo "  FAIL the throwaway first-password file is still there"; fail=1; } || echo "  ok   the throwaway first password is gone"
  grep -q '^TN_FIRST_PW=$' "$APP/.env" 2>/dev/null || docker run --rm -v "$APP:/a" alpine grep -q '^TN_FIRST_PW=$' /a/.env && echo "  ok   …and blanked in .env" || { echo "  FAIL TN_FIRST_PW still set"; fail=1; }
  wait_for '.app.api == true and .app.blocking.enabled == true and (.app.lists | length) == 1 and .app.stats.list_domains > 10000' 240 \
    && echo "  ok   API token works; blocking on, $(jq -r .app.stats.list_domains "$VAR/status.json") domains on the default list" || { echo "  FAIL status: $(jq -c '.app | {api, blocking, lists, stats}' "$VAR/status.json")"; fail=1; }
  wait_for '.app.resolver.protocol == "Https" and (.app.resolver.forwarders[0] | test("cloudflare"))' 20 && echo "  ok   upstream Cloudflare over DNS-over-HTTPS from the start" || { echo "  FAIL resolver: $(jq -c .app.resolver "$VAR/status.json")"; fail=1; }
  if [[ "${E2E_PART:-1}" == 1 ]]; then
  # Forwarding: real answers, over UDP and TCP.
  until_dns ask example.org 20 '^[0-9]+\.' && [[ "$(ask example.org A +tcp)" =~ ^[0-9]+\. ]] && echo "  ok   DNS answers on port 1054 (UDP and TCP): example.org → $(ask example.org)" || { echo "  FAIL dns: '$(ask example.org)'"; fail=1; }
  # A domain from the default blocklist is blocked.
  listed=$(docker exec technitium-server sh -c 'cat /etc/dns/blocklists/* 2>/dev/null' | sed -n 's/^0\.0\.0\.0 \([a-z0-9][a-z0-9.-]*\.[a-z]\{2,\}\)$/\1/p' | sed -n 3000p)
  [[ -n "$listed" && "$(rcode "$listed")" == BLOCKED ]] && echo "  ok   on the blocklist: $listed → blocked" || { echo "  FAIL blocklist: '$listed' → $(rcode "$listed")"; fail=1; }
  # Your own sites: blocked, then allowed over the list.
  request "ACTION='domainadd'" "KIND='block'" "DOMAIN='example.org'" || fail=1
  until_dns rcode example.org 10 '^BLOCKED$' && echo "  ok   always blocked: example.org → blocked" || { echo "  FAIL block: $(rcode example.org)"; fail=1; }
  wait_for '.app.blocked | index("example.org")' 20 && echo "  ok   listed under your sites" || { echo "  FAIL blocked list: $(jq -c .app.blocked "$VAR/status.json")"; fail=1; }
  request "ACTION='domaindel'" "KIND='block'" "DOMAIN='example.org'" || fail=1
  until_dns ask example.org 10 '^[0-9]+\.' && echo "  ok   unblocked again" || { echo "  FAIL unblock"; fail=1; }
  request "ACTION='domainadd'" "KIND='allow'" "DOMAIN='$listed'" || fail=1
  until_dns rcode "$listed" 10 '^(NOERROR|NXDOMAIN|SERVFAIL)$' && wait_for ".app.allowed | index(\"$listed\")" 20 && echo "  ok   always allowed beats the blocklist: $listed → $(rcode "$listed")" || { echo "  FAIL allow: $(rcode "$listed")"; fail=1; }
  request "ACTION='domaindel'" "KIND='allow'" "DOMAIN='$listed'" || fail=1
  until_dns rcode "$listed" 10 '^BLOCKED$' && echo "  ok   …and blocked again when that's removed" || { echo "  FAIL allow removed: $(rcode "$listed")"; fail=1; }
  # Pause, off, on.
  request "ACTION='pause'" "PAUSE_MIN='5'" || fail=1
  until_dns rcode "$listed" 10 '^(NOERROR|NXDOMAIN|SERVFAIL)$' && wait_for '.app.blocking.enabled == false and .app.blocking.until > now' 20 && echo "  ok   paused for 5 minutes: $listed gets through" || { echo "  FAIL pause: $(rcode "$listed") $(jq -c .app.blocking "$VAR/status.json")"; fail=1; }
  request "ACTION='blocking'" "ON='1'" || fail=1
  until_dns rcode "$listed" 10 '^BLOCKED$' && wait_for '.app.blocking.enabled == true and .app.blocking.until == null' 20 && echo "  ok   turned back on" || { echo "  FAIL on"; fail=1; }
  request "ACTION='blocking'" "ON='0'" || fail=1
  until_dns rcode "$listed" 10 '^(NOERROR|NXDOMAIN|SERVFAIL)$' && wait_for '.app.blocking.enabled == false and .app.blocking.until == null' 20 && echo "  ok   off until turned on" || { echo "  FAIL off"; fail=1; }
  request "ACTION='blocking'" "ON='1'" || fail=1
  # Blocklists: add one, fetch, remove.
  n=$(jq -r .app.stats.list_domains "$VAR/status.json")
  request "ACTION='listadd'" "URL_B64='$(b64u 'https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-only/hosts')'" || fail=1
  wait_for "(.app.lists | length) == 2 and .app.stats.list_domains > $n" 180 && echo "  ok   a second blocklist, fetched: $n → $(jq -r .app.stats.list_domains "$VAR/status.json") domains" || { echo "  FAIL listadd: $(jq -c '[.app.lists, .app.stats.list_domains]' "$VAR/status.json")"; fail=1; }
  request "ACTION='listupdate'" || fail=1
  request "ACTION='listdel'" "URL_B64='$(b64u 'https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-only/hosts')'" || fail=1
  wait_for '(.app.lists | length) == 1' 30 && echo "  ok   removed again" || { echo "  FAIL listdel"; fail=1; }
  # Zones: a local name, a CNAME to it.
  request "ACTION='recadd'" "DOMAIN='nas.home'" "REC_TYPE='A'" "REC_VALUE='192.168.1.20'" || fail=1
  [[ "$(ask nas.home)" == 192.168.1.20 ]] && echo "  ok   a local name: nas.home → 192.168.1.20 (zone home made for it)" || { echo "  FAIL nas.home: '$(ask nas.home)'"; fail=1; }
  request "ACTION='recadd'" "DOMAIN='files.home'" "REC_TYPE='CNAME'" "REC_VALUE='nas.home'" || fail=1
  [[ "$(ask files.home)" == 192.168.1.20 ]] && echo "  ok   a CNAME: files.home → nas.home → 192.168.1.20" || { echo "  FAIL files.home: '$(ask files.home)'"; fail=1; }
  request "ACTION='recadd'" "DOMAIN='nas.home'" "REC_TYPE='A'" "REC_VALUE='192.168.1.21'" || fail=1
  [[ "$(dig +short @127.0.0.1 -p 1054 nas.home A | paste -sd,)" == 192.168.1.21 ]] && echo "  ok   adding the name again replaces it" || { echo "  FAIL replace: $(dig +short @127.0.0.1 -p 1054 nas.home A | paste -sd,)"; fail=1; }
  wait_for '.app.zones | map(select(.name == "home")) | .[0].records | map(.name + "=" + .value) | (index("nas.home=192.168.1.21") and index("files.home=nas.home"))' 20 && echo "  ok   the Zones tab lists them" || { echo "  FAIL zones: $(jq -c .app.zones "$VAR/status.json")"; fail=1; }
  request "ACTION='recdel'" "DOMAIN='files.home'" "REC_TYPE='CNAME'" "REC_VALUE='nas.home'" || fail=1
  [[ "$(rcode files.home)" == NXDOMAIN ]] && echo "  ok   a name removed" || { echo "  FAIL recdel: $(rcode files.home)"; fail=1; }
  # Backup, then lose the zone, then restore it.
  request "ACTION='backup'" || fail=1; name=$(jq -r '.backups[0].name // ""' "$VAR/status.json")
  grep -q 'zones/home.zone' <<< "$(tar -xOf "$APP/backups/$name" --wildcards '*/config.tar.gz' 2>/dev/null | tar -tzf - 2>/dev/null)" \
    && until_dns ask nas.home 30 '^192\.168\.1\.21$' && echo "  ok   the backup has the config folder (with zone home); DNS is back after the copy" || { echo "  FAIL backup contents: $(tar -tf "$APP/backups/$name" | paste -sd' ')"; fail=1; }
  request "ACTION='zonedel'" "ZONE='home'" || fail=1
  [[ "$(rcode nas.home)" == NXDOMAIN ]] && echo "  ok   zone deleted: nas.home → NXDOMAIN" || { echo "  FAIL zonedel: $(rcode nas.home)"; fail=1; }
  request "ACTION='restore'" "BACKUP='$name'" || fail=1
  until_dns ask nas.home 30 '^192\.168\.1\.21$' && wait_for '.app.api == true' 30 && login_ok "$url" "$pw" && echo "  ok   restored: nas.home → 192.168.1.21 again, the package's token and your password still work" || { echo "  FAIL restore: '$(ask nas.home)' api $(jq -r .app.api "$VAR/status.json")"; fail=1; }
  request "ACTION='zonedel'" "ZONE='home'" || fail=1
  fi
  if [[ "${E2E_PART:-1}" == 2 ]]; then
  pw=$(cat "$E2E/.pw" 2>/dev/null)
  # Resolvers: DNS-over-TLS, plain custom, recursive, back to the default.
  request "ACTION='resolver'" "RESOLVER='forward'" "UPSTREAM='quad9'" "DNS_PROTO='tls'" "CUSTOM_DNS=''" || fail=1
  wait_for '.app.resolver.protocol == "Tls" and (.app.resolver.forwarders[0] | test("quad9"))' 20 && until_dns ask example.net 20 '^[0-9]+\.' && echo "  ok   Quad9 over DNS-over-TLS answers: example.net → $(ask example.net)" || { echo "  FAIL quad9 tls: $(jq -c .app.resolver "$VAR/status.json")"; fail=1; }
  request "ACTION='resolver'" "RESOLVER='forward'" "UPSTREAM='custom'" "DNS_PROTO='https'" "CUSTOM_DNS='1.1.1.1+9.9.9.9'" || fail=1
  wait_for '.app.resolver.protocol == "Udp" and .app.resolver.forwarders == ["1.1.1.1","9.9.9.9"]' 20 && until_dns ask example.com 20 '^[0-9]+\.' && echo "  ok   your own servers, plain DNS" || { echo "  FAIL custom: $(jq -c .app.resolver "$VAR/status.json")"; fail=1; }
  request "ACTION='resolver'" "RESOLVER='recursive'" "UPSTREAM='cloudflare'" "DNS_PROTO='https'" "CUSTOM_DNS=''" || fail=1
  wait_for '.app.resolver.forwarders == [] and .app.resolver.mode == "recursive"' 20 && until_dns ask wikipedia.org 30 '^[0-9]+\.' && echo "  ok   recursive: wikipedia.org → $(ask wikipedia.org)" || { echo "  FAIL recursive: $(jq -c .app.resolver "$VAR/status.json") '$(ask wikipedia.org)'"; fail=1; }
  request "ACTION='resolver'" "RESOLVER='forward'" "UPSTREAM='cloudflare'" "DNS_PROTO='https'" "CUSTOM_DNS=''" || fail=1
  # A new password; HTTPS for the console.
  request "ACTION='newpw'" || fail=1; pw2=$(secret)
  login_ok "$url" "$pw2" && ! login_ok "$url" "$pw" && wait_for '.app.api == true' 20 && echo "  ok   a new password works, the old one doesn't, the window's token still does" || { echo "  FAIL newpw"; fail=1; }
  request "ACTION='settings'" "TLS='self'" || fail=1
  login_ok "https://127.0.0.1:$PORT" "$pw2" && echo "  ok   HTTPS self: the console on https://…:$PORT, sign-in works" || { echo "  FAIL https: $(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/")"; fail=1; }
  [[ "$(ask example.net)" =~ ^[0-9]+\. ]] && echo "  ok   DNS unaffected by HTTPS" || { echo "  FAIL dns after https"; fail=1; }
  request "ACTION='settings'" "TLS='off'" || fail=1
  login_ok "$url" "$pw2" && echo "  ok   back to plain HTTP" || { echo "  FAIL http again"; fail=1; }
  # Network mode: the NAS's own network shows each device's address; HTTPS from the package can't share its port.
  request "ACTION='settings'" "NET_MODE='host'" "TLS='self'" >/dev/null 2>&1
  [[ "$(jq -r .app.net.mode "$VAR/status.json")" == bridge ]] && echo "  ok   host network with the package's HTTPS on: refused" || { echo "  FAIL host+https accepted"; fail=1; }
  request "ACTION='settings'" "NET_MODE='host'" || fail=1
  wait_for '.app.net.mode == "host" and .app.api == true' 60 && [[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' technitium-server)" == host ]] \
    && echo "  ok   host network: the container is on the NAS's own network, the window's token still works" || { echo "  FAIL host: $(docker inspect -f '{{.HostConfig.NetworkMode}}' technitium-server) $(jq -c .app.net "$VAR/status.json")"; fail=1; }
  [[ "$(ask example.net)" =~ ^[0-9]+\. ]] && login_ok "$url" "$pw2" && echo "  ok   host network: DNS on 127.0.0.1:1054 and the console answer" || { echo "  FAIL host dns/console"; fail=1; }
  tok=$(curl -s "$url/api/user/login" --data-urlencode user=admin --data-urlencode "pass=$pw2" | jq -r '.token // empty')
  for i in $(seq 1 15); do ask "client-$i-$RANDOM.example.com" >/dev/null; sleep 5
    clients=$(curl -s "$url/api/dashboard/stats/get" --data-urlencode "token=$tok" --data-urlencode type=LastHour | jq -r '[.response.topClients[]?.name] | join(",")')
    [[ "$clients" == *127.0.0.1* ]] && break; done
  [[ "$clients" == *127.0.0.1* ]] && echo "  ok   host network: Technitium sees the real client (top clients: $clients)" || { echo "  FAIL client address: $clients"; fail=1; }
  request "ACTION='settings'" "NET_MODE='bridge'" || fail=1
  wait_for '.app.net.mode == "bridge" and .app.api == true' 60 && [[ "$(ask example.net)" =~ ^[0-9]+\. ]] && login_ok "$url" "$pw2" \
    && echo "  ok   back to Docker's network: DNS and the console answer" || { echo "  FAIL back to bridge: $(jq -c .app.net "$VAR/status.json")"; fail=1; }
  # Categories: the query log is turned on, lookups are sorted into categories, groups block by category.
  request "ACTION='catsetup'" || fail=1
  wait_for '.app.cat.querylog == true' 120 && echo "  ok   category stats on: Technitium's query log app installed" || { echo "  FAIL catsetup: $(jq -c .app.cat "$VAR/status.json" | head -c 300)"; fail=1; }
  for d in www.instagram.com www.facebook.com youtube.com pornhub.com www.bbc.co.uk; do ask "$d" >/dev/null; done
  rm -f "$VAR/.cat-check"
  for i in $(seq 1 40); do jq -e '[.devices[].cats | keys[]] | (index("social") and index("youtube") and index("adult"))' "$VAR/categories.json" >/dev/null 2>&1 && break; sleep 5; done
  jq -e '[.devices[].cats | keys[]] | (index("social") and index("youtube") and index("adult"))' "$VAR/categories.json" >/dev/null 2>&1 \
    && echo "  ok   lookups sorted: $(jq -c '[.devices[0].cats | to_entries[] | "\(.key) \(.value.n)"]' "$VAR/categories.json")" || { echo "  FAIL categories: $(head -c 300 "$VAR/categories.json" 2>/dev/null)"; fail=1; }
  request "ACTION='catgroups'" "GROUPS_B64='$(printf '%s' '{"groups":[{"name":"x","members":["1.2.3"],"block":[]}],"default":[]}' | base64 -w0 | tr '+/' '-_' | tr -d '=')'" >/dev/null 2>&1
  [[ "$(jq -r '.app.cat.groups.groups | length' "$VAR/status.json")" == 0 ]] && echo "  ok   a group with a bad address: refused" || { echo "  FAIL bad group accepted"; fail=1; }
  g='{"groups":[{"name":"Kids","members":["172.16.0.0/12","127.0.0.1"],"block":["social","youtube"]}],"default":["ads"]}'
  request "ACTION='catgroups'" "GROUPS_B64='$(printf '%s' "$g" | base64 -w0 | tr '+/' '-_' | tr -d '=')'" || fail=1
  for i in $(seq 1 24); do [[ -z "$(ask www.instagram.com)" || "$(ask www.instagram.com)" == 0.0.0.0 ]] && break; sleep 5; done
  ig=$(ask www.instagram.com); yt=$(ask youtube.com); bbc=$(ask www.bbc.co.uk)
  [[ ( -z "$ig" || "$ig" == 0.0.0.0 ) && ( -z "$yt" || "$yt" == 0.0.0.0 ) && "$bbc" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[1-9] ]] \
    && echo "  ok   group Kids blocks social and YouTube (instagram: ${ig:-blocked}, youtube: ${yt:-blocked}), the BBC still answers ($bbc)" || { echo "  FAIL group blocking: ig=$ig yt=$yt bbc=$bbc"; fail=1; }
  request "ACTION='catgroups'" "GROUPS_B64='$(printf '%s' '{"groups":[],"default":[]}' | base64 -w0 | tr '+/' '-_' | tr -d '=')'" || fail=1
  for i in $(seq 1 12); do [[ "$(ask www.instagram.com)" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[1-9] ]] && break; sleep 5; done
  [[ "$(ask www.instagram.com)" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[1-9] ]] && echo "  ok   group removed: instagram answers again" || { echo "  FAIL unblock: $(ask www.instagram.com)"; fail=1; }
  # Updates: the pin moves to the newest release; the old image goes by name, nothing else is pruned.
  docker pull -q technitium/dns-server:15.6.0 >/dev/null 2>&1
  docker run --rm -v "$APP:/a" alpine sed -i 's|^TN_IMAGE=.*|TN_IMAGE=technitium/dns-server:15.6.0|' /a/.env
  request "ACTION='check'" || fail=1
  wait_for '.image_update.available == true and .image_update.current == "15.6.0"' 20 && echo "  ok   pinned 15.6.0: Docker Hub has $(jq -r .image_update.latest "$VAR/status.json")" || { echo "  FAIL check: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  n=$(docker images -q -f dangling=true | wc -l)
  request "ACTION='updateapp'" || fail=1
  grep -q "^TN_IMAGE=technitium/dns-server:$(jq -r .image_update.latest "$VAR/status.json")$" <(docker run --rm -v "$APP:/a" alpine cat /a/.env) && ! docker image inspect technitium/dns-server:15.6.0 >/dev/null 2>&1 \
    && [[ "$(docker images -q -f dangling=true | wc -l)" -ge "$n" ]] && wait_for '.image_update.available == false' 20 \
    && echo "  ok   updated: the pin moved on, 15.6.0 removed by name, other dangling images left alone" || { echo "  FAIL update: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  docker image rm technitium/dns-server:15.6.0 >/dev/null 2>&1
  fi
  (( fail )) && { echo "  technitium: something FAILED"; return 1; }; echo "  technitium: all passed"
}
