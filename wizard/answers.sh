    echo "DNS_PORT='$(printf '%s' "${wizard_dns_port:-53}" | tr -cd '0-9' | head -c 5)'"
    echo "TLS='$(if [ "${wizard_tls_dsm:-false}" = true ]; then echo dsm; elif [ "${wizard_tls_self:-false}" = true ]; then echo self; else echo off; fi)'"
