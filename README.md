In progress:

```
certbot certonly --reuse-key --dns-rfc2136-credentials=/etc/letsencrypt/dns.ini --dns-rfc2136 -d ${domains_joined%,}
certbot certonly --reuse-key --dns-rfc2136-credentials=/etc/letsencrypt/dns.ini --dns-rfc2136 --duplicate --cert-name "${domains[0]}-duplicate" -d ${domains_joined%,}

mkdir /etc/letsencrypt/current
ln -s /etc/letsencrypt/live/${domains[0]} /etc/letsencrypt/current/${domains[0]}

mkdir /etc/letsencrypt/next
ln -s /etc/letsencrypt/live/${domains[0]}-duplicate /etc/letsencrypt/next/${domains[0]}

kubectl -n ${namespace} create secret tls ${secret_name} --cert= /etc/letsencrypt/current/${domains[0]}/fullchain.pem --key= /etc/letsencrypt/current/${domains[0]}/privkey

cur_hash=$(openssl ec -in /etc/letsencrypt/current/mailserver.slush.ca/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
next_hash=$(openssl ec -in /etc/letsencrypt/next/mailserver.slush.ca/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

echo "server ${master}" >/tmp/nsupdate
for d in ${domains[@]}; do
  for p in ${ports[@]}; do
    echo "update add _${p}._tcp.${d}. ${ttl} TLSA 3 1 1 ${cur_hash}" >>/tmp/nsupdate
    echo "send" >>/tmp/nsupdate
  done
done

```
