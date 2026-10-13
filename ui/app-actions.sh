# Technitium's actions, validated by the CGI before they become a request file.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
name_ok() { [[ "$1" =~ ^[a-z0-9_]([a-z0-9_-]{0,62}\.)+[a-z0-9]([a-z0-9-]{0,62})$ && ${#1} -le 253 ]]; }
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 v u k d t z r up p c
  case "$a" in
    listupdate|newpw|refreshcert) lines="ACTION='$a'" ;;
    blocking) v=$(param on "$body"); [[ "$v" =~ ^[01]$ ]] || error "400 Bad Request" "On or off?"; lines="ACTION='blocking'
ON='$v'" ;;
    pause) v=$(param minutes "$body"); [[ "$v" =~ ^(5|30|60)$ ]] || error "400 Bad Request" "Pick how long."; lines="ACTION='pause'
PAUSE_MIN='$v'" ;;
    listadd|listdel) u=$(decode "$(param url "$body")")
      [[ "$u" =~ ^https?://[^[:space:],\"\'\<\>]+$ && ${#u} -le 500 ]] || error "400 Bad Request" "A blocklist is a web address (https://…)."
      lines="ACTION='$a'
URL_B64='$(b64u "$u")'" ;;
    domainadd|domaindel) k=$(param kind "$body"); d=$(decode "$(param domain "$body")" | tr 'A-Z' 'a-z')
      [[ "$k" =~ ^(allow|block)$ ]] || error "400 Bad Request" "Allow or block."
      name_ok "$d" || error "400 Bad Request" "A site's name, like ads.example.com."
      lines="ACTION='$a'
KIND='$k'
DOMAIN='$d'" ;;
    recadd|recdel) d=$(decode "$(param name "$body")" | tr 'A-Z' 'a-z'); t=$(param type "$body"); r=$(decode "$(param value "$body")"); [[ "$t" == CNAME ]] && r=$(tr 'A-Z' 'a-z' <<< "$r")
      name_ok "$d" || error "400 Bad Request" "A full name with a dot, like nas.home."
      [[ "$t" =~ ^(A|AAAA|CNAME)$ ]] || error "400 Bad Request" "Pick a type."
      case "$t" in
        A)     [[ "$r" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "400 Bad Request" "An IPv4 address, like 192.168.1.20." ;;
        AAAA)  [[ "$r" =~ ^[0-9a-fA-F:]{2,39}$ && "$r" == *:* ]] || error "400 Bad Request" "An IPv6 address, like fd00::20." ;;
        CNAME) [[ "$r" =~ ^[a-z0-9]([a-z0-9-]{0,62}\.)*[a-z0-9]([a-z0-9-]{0,62})$ && ${#r} -le 253 ]] || error "400 Bad Request" "Another name, like nas.home." ;;
      esac
      lines="ACTION='$a'
DOMAIN='$d'
REC_TYPE='$t'
REC_VALUE='$r'" ;;
    zonedel) z=$(decode "$(param zone "$body")" | tr 'A-Z' 'a-z')
      [[ "$z" =~ ^[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62}))*$ && ${#z} -le 253 ]] || error "400 Bad Request" "Pick a zone."
      lines="ACTION='zonedel'
ZONE='$z'" ;;
    resolver) v=$(param mode "$body"); up=$(param upstream "$body"); p=$(param proto "$body"); c=$(decode "$(param custom "$body")" | tr -s ' ,' '++' | sed 's/^+//; s/+$//')
      [[ "$v" =~ ^(forward|recursive)$ ]] || error "400 Bad Request" "Forward or recursive?"
      [[ "$up" =~ ^(cloudflare|quad9|google|custom)$ ]] || error "400 Bad Request" "Pick a service."
      [[ "$p" =~ ^(https|tls|udp)$ ]] || error "400 Bad Request" "Pick a protocol."
      if [[ "$v" == forward && "$up" == custom ]]; then [[ "$c" =~ ^[0-9.]{7,15}(\+[0-9.]{7,15})?$ ]] || error "400 Bad Request" "One or two IPv4 addresses, like 192.168.1.1."; else c=""; fi
      lines="ACTION='resolver'
RESOLVER='$v'
UPSTREAM='$up'
DNS_PROTO='$p'
CUSTOM_DNS='$c'" ;;
  esac
}
app_cgi_settings() {   # body → appends TLS to $lines, or errors
  local tls; tls=$(param tls "$1")
  [[ -z "$tls" ]] && return 0
  [[ "$tls" =~ ^(dsm|self|off)$ ]] || error "400 Bad Request" "HTTPS is DSM's certificate, self-signed, or off."
  lines="$lines
TLS='$tls'"
}
