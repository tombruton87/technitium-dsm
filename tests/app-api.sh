# Technitium's CGI checks (sourced by chassis/tests/test-api.sh).
expect "pause" 202 "$(post "$me" pause 'action=pause&minutes=30')"; request_is "pause request" "ACTION='pause'
PAUSE_MIN='30'
BY='$me'"
expect "pause bad" 400 "$(post "$me" pause 'action=pause&minutes=99999')"
expect "blocking off" 202 "$(post "$me" blocking 'action=blocking&on=0')"; request_is "blocking request" "ACTION='blocking'
ON='0'
BY='$me'"
expect "listadd" 202 "$(post "$me" listadd 'action=listadd&url=https%3A%2F%2Fexample.com%2Flist.txt%3Fa%3D1%26b%3D2')"; request_is "listadd request" "ACTION='listadd'
URL_B64='aHR0cHM6Ly9leGFtcGxlLmNvbS9saXN0LnR4dD9hPTEmYj0y'
BY='$me'"
expect "listadd bad" 400 "$(post "$me" listadd 'action=listadd&url=file%3A%2F%2F%2Fetc%2Fpasswd')"
expect "listadd comma" 400 "$(post "$me" listadd 'action=listadd&url=https%3A%2F%2Fa.com%2Fx%2Chttps%3A%2F%2Fb.com')"
expect "domainadd" 202 "$(post "$me" domainadd 'action=domainadd&kind=allow&domain=Ads.Example.com')"; request_is "domainadd request" "ACTION='domainadd'
KIND='allow'
DOMAIN='ads.example.com'
BY='$me'"
expect "domainadd bad" 400 "$(post "$me" domainadd 'action=domainadd&kind=block&domain=a%3Bb.com')"
expect "recadd" 202 "$(post "$me" recadd 'action=recadd&name=NAS.home&type=A&value=192.168.1.20')"; request_is "recadd request" "ACTION='recadd'
DOMAIN='nas.home'
REC_TYPE='A'
REC_VALUE='192.168.1.20'
BY='$me'"
expect "recadd cname" 202 "$(post "$me" recadd 'action=recadd&name=files.home&type=CNAME&value=NAS.home')"; request_is "recadd cname request" "ACTION='recadd'
DOMAIN='files.home'
REC_TYPE='CNAME'
REC_VALUE='nas.home'
BY='$me'"
expect "recadd bad ip" 400 "$(post "$me" recadd 'action=recadd&name=nas.home&type=A&value=nas.home')"
expect "recadd one label" 400 "$(post "$me" recadd 'action=recadd&name=nas&type=A&value=192.168.1.20')"
expect "recadd bad type" 400 "$(post "$me" recadd 'action=recadd&name=nas.home&type=TXT&value=x')"
expect "zonedel" 202 "$(post "$me" zonedel 'action=zonedel&zone=home')"; request_is "zonedel request" "ACTION='zonedel'
ZONE='home'
BY='$me'"
expect "zonedel bad" 400 "$(post "$me" zonedel 'action=zonedel&zone=..%2Fetc')"
expect "resolver custom" 202 "$(post "$me" resolver 'action=resolver&mode=forward&upstream=custom&proto=https&custom=192.168.1.1%2C%201.1.1.1')"; request_is "resolver request" "ACTION='resolver'
RESOLVER='forward'
UPSTREAM='custom'
DNS_PROTO='https'
CUSTOM_DNS='192.168.1.1+1.1.1.1'
BY='$me'"
expect "resolver bad" 400 "$(post "$me" resolver 'action=resolver&mode=forward&upstream=custom&proto=udp&custom=evil.com')"
expect "resolver bad proto" 400 "$(post "$me" resolver 'action=resolver&mode=forward&upstream=quad9&proto=quic')"
