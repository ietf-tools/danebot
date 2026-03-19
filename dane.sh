#!/bin/bash

# domains on the certificate
domain_list=${DANEBOT_DOMAINS:-"mail.mydomain.com mx.mydomain.com"}
domains=(${domain_list[@]})
printf -v domains_joined '%s,' ${domains[@]}
# email address for Lets letsencrypt
le_account_email=${DANEBOT_EMAIL_ADDR}
le_account_tos=${DANEBOT_TOS_AGREE:-no}
# ports to generate records for
tlsa_ports=${DANEBOT_PORTS:-"25 587"}
ports=(${tlsa_ports})
# generic options
ttl=300
dns_prop_delay=300
max_retries=100

# use rfc2136, or cloudflare for dns updates
update_type=${DANEBOT_UPDATE_TYPE:-rfc2136}
# needed for rfc2136 updates
master=${DANEBOT_RFC2136_MASTER:-192.0.2.234}
tsig_name=${DANEBOT_TSIG_NAME}
tsig_secret=${DANEBOT_TSIG_SECRET}
tsig_algo=${DANEBOT_TSIG_ALGO:-hmac-sha256}
#tsig_path=${DANEBOT_RFC2136_TSIG:-/etc/letsencrypt/tsig.key}

# clouddlare updates use CFTOKEN
cf_token=${DANEBOT_CFTOKEN}

# Either k8s, or systemd
service_type=${DANEBOT_SERVICE_TYPE:-k8s}

# needed for in-cluster actions
namespace=${DANEBOT_K8S_NS:-mailserver}
deployment_type=${DANEBOT_K8S_DEPLOYMENT_TYPE:-deployments}
deployment_name=${DANEBOT_K8S_DEPLOYMENT_NAME:-mailserver-deployment}
secret_name=${DANEBOT_K8S_SECRET_NAME:-dane}

# k8s primitives, probably doont need to change
apiserver=https://kubernetes.default.svc
serviceaccount=/var/run/secrets/kubernetes.io/serviceaccount

if [ ${service_type} == "k8s" ]; then
  namespace=$(cat ${serviceaccount}/namespace)
  token=$(cat ${serviceaccount}/token)
  cacert=${serviceaccount}/ca.crt
fi

# needed for systemd service restarts
systemd_services=${DANEBOT_SYSTEMD_SERVICES:-postfix}
sytemd_reload_type=${DANEBOT_SYSTEMD_RELOAD_TYPE:-reload}



rfc2136_update() {
  printf "server ${master}\nupdate add _${1}._tcp.${2}. ${ttl} TLSA 3 1 1 ${3}\nsend" | nsupdate -y "${tsig_algo}:${tsig_name}:${tsig_secret}"
}

rfc2136_remove() {
  printf "server ${master}\nupdate delete _${1}._tcp.${2}. ${ttl} TLSA 3 1 1 ${3}\nsend" | nsupdate -y "${tsig_algo}:${tsig_name}:${tsig_secret}"
}

cloudflare_update() {
  echo "Getting Zone ID for domain"

  zone_id=`curl -X GET "https://api.cloudflare.com/client/v4/zones" \
    --fail --silent --show-error \
    -H "Authorization: Bearer ${cf_token}" \
    -H "Content-Type: application/json" | \
    jq --arg ZONE "${2}" '.result[] | (select(.name == $ZONE)) | .id' | tr -d '"'`

  echo "checking for existing records"
  existing_record=`curl https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records \
    --fail --silent --show-error \
    -H "Authorization: Bearer ${cf_token}" | \
    jq '.result[] | (select(.type=="TLSA" and .content=="3 1 1 '"${3}"'")) | .id' | tr -d '"'`

  if [ -z ${existing_record+x} ]; then
    echo 'no record found creating TLSA record...'
    curl -X POST https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records \
      --fail --silent --show-error \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${cf_token}" \
      -d '{
      "content": "3 1 1 '"${3}"'",
      "data": {
      "certificate": "'"${3}"'",
        "matching_type": 1,
        "selector": 1,
        "usage": 3
      },
      "name": "'"_${1}._tcp.${2}."'",
      "type": "TLSA"
    }'

    echo "Done."
  else
    echo "existing record found with id ${existing_record}, nothing needed"
    echo "Done."
  fi
}

restart_k8s_deployment() {
  curl --cacert ${cacert} --header "Authorization: Bearer ${token}" -X PATCH \
    --fail --silent --show-error -o /dev/null \
    ${apiserver}/apis/apps/v1/namespaces/${namespace}/${deployment_type}/${deployment_name} \
    --header 'Content-Type: application/strategic-merge-patch+json' \
    -d '{
      "spec": {
        "template": {
          "metadata": {
            "annotations": {
              "kubectl.kubernetes.io/restartedAt": "'"$(date)"'"
            },
            "namespace": "'"${namespace}"'"
          }
        }
      }
    }'
}

insert_k8s_secret() {
  curl --cacert ${cacert} --header "Authorization: Bearer ${token}" -X GET \
    --fail --silent -o /dev/null \
    ${apiserver}/api/v1/namespaces/${namespace}/secrets/${secret_name}
  if [ $? -ne 0 ]; then
    curl --cacert ${cacert} --header "Authorization: Bearer ${token}" -X POST \
      --fail --silent --show-error -o /dev/null \
      ${apiserver}/api/v1/namespaces/${namespace}/secrets/ \
      --header 'Content-Type: application/json' \
      -d '{
        "kind": "Secret",
        "apiVersion": "v1",
        "metadata": {
            "name": "'"${secret_name}"'",
            "namespace": "'"${namespace}"'"
        },
        "data": {
            "tls.crt": "'"$(cat /etc/letsencrypt/${1}/${domains[0]}/fullchain.pem | base64 -w 0)"'",
            "tls.key": "'"$(cat /etc/letsencrypt/${1}/${domains[0]}/privkey.pem | base64 -w 0)"'"
        },
        "type": "kubernetes.io/tls"
      }'
  else
    curl --cacert ${cacert} --header "Authorization: Bearer ${token}" -X PATCH \
      --fail --silent --show-error -o /dev/null \
      ${apiserver}/api/v1/namespaces/${namespace}/secrets/${secret_name} \
      --header 'Content-Type: application/strategic-merge-patch+json' \
      -d '{
        "kind": "Secret",
        "apiVersion": "v1",
        "metadata": {
            "name": "'"${secret_name}"'",
            "namespace": "'"${namespace}"'"
        },
        "data": {
            "tls.crt": "'"$(cat /etc/letsencrypt/${1}/${domains[0]}/fullchain.pem | base64 -w 0)"'",
            "tls.key": "'"$(cat /etc/letsencrypt/${1}/${domains[0]}/privkey.pem | base64 -w 0)"'"
        },
        "type": "kubernetes.io/tls"
      }'
  fi
}

update_dns() {
  for d in ${domains[@]}; do
    for p in ${ports[@]}; do
      ${update_type}_update ${p} ${d} ${1}
    done
  done
}

check_dns() {
  attempt=0
  for d in ${domains[@]}; do
    for p in ${ports[@]}; do
      until dig +short _${p}._tcp.${d} tlsa | cut -d' ' -f4- | sed s/\ // | grep -i -q ${1}; do
        ((attempt++))
        if [ ${attempt} -ge ${max_retries} ]; then
          echo "Did not find TLSA records after ${max_retries} attempts."
          exit 1
        fi
        echo "looking for ${new_next_hash} on _${p}._tcp.${d}, attempt ${attempt}"
        sleep 1
      done
      echo "found ${1} on _${p}._tcp.${d}"
    done
  done
}

check_service() {
  check_attempt=0
  until openssl s_client -connect ${domains[0]}:${ports[0]} -starttls smtp -brief -dane_tlsa_domain ${domains[0]} -dane_tlsa_rrdata "3 1 1 ${1}" -verify_return_error <<<"QUIT" 2>/dev/null; do
    ((check_attempt++))
    echo "Checking for certificate with hash ${1}, attempt ${check_attempt}"
    if [[ ${check_attempt} -ge ${max_retries} ]]; then
      echo "Did not find new certificate after ${max_retries} attempts."
      exit 1
    fi
    sleep 1
  done
  echo "Found hash ${1}"
}

cleanup_records() {
  for d in ${domains[@]}; do
    for p in ${ports[@]}; do
      echo "deleting record _${p}._tcp.${d} ${$1}"
      rfc2136_remove ${p} ${d} ${1}
    done
  done
}

# check if certbot is installed, and in PATH
type certbot
if [ $? -ne 0 ]; then
  echo "Please install certbot and either RFC2136, or Cloudflare DNS plugins"
  exit 1
fi

# Check for auth parameters for both update types
if [ ${update_type} == "rfc2136" ]; then
  if [ -z ${DANEBOT_TSIG_NAME+x} ] || [ -z ${DANEBOT_TSIG_SECRET+x} ]; then
    echo "RFC2136 updates need both DANEBOT_TSIG_NAME, and DANEBOT_TSIG_SECRET set"
    exit 1
  fi
elif [ ${update_type} == "cloudflare" ]; then
  if [ -z ${DANEBOT_CFTOKEN+x} ]; then
    echo "Cloudflare updates need DANEBOT_CFTOKEN set"
    exit 1
  fi
fi

# Fetch inital certs if none exist for our domain set
if [ ! -d "/etc/letsencrypt/live/${domains[0]}" ]; then
  if [ -z ${le_account_email+x} ]; then
    echo "Initial certificates need an email address, please set DANEBOT_EMAIL_ADDR"
    exit 1
  fi
  if [ ${le_account_tos} == "no" ]; then
    echo "Please set DANEBOT_TOS_AGREE to yes to agree to the LetsEncrypt TOS"
    exit 1
  fi
  initial_setup="1"
  if [ ${update_type} == "rfc2136" ]; then
    echo "dns_rfc2136_server = ${master}" >/etc/letsencrypt/dns.ini
    echo "dns_rfc2136_name = ${tsig_name}" >>/etc/letsencrypt/dns.ini
    echo "dns_rfc2136_secret = ${tsig_secret}" >>/etc/letsencrypt/dns.ini
    echo "dns_rfc2136_algorithm = ${tsig_algo^^}" >>/etc/letsencrypt/dns.ini
    echo "dns_rfc2136_port = 53" >>/etc/letsencrypt/dns.ini
    echo "dns_rfc2136_sign_query = false" >>/etc/letsencrypt/dns.ini
  echo "Requesting initial certs"
  /usr/bin/certbot certonly --reuse-key \
    --dns-rfc2136-credentials=/etc/letsencrypt/dns.ini \
    --dns-rfc2136 -d ${domains_joined%,} \
    -n -m ${le_account_email} --agree-tos \
    --no-autorenew
  elif [ ${update_type} == "cloudflare" ]; then
  /usr/bin/certbot certonly --reuse-key \
    --dns-cloudflare -d ${domains_joined%,} \
    -n -m ${le_account_email} --agree-tos \
    --no-autorenew
  fi
  mkdir -p /etc/letsencrypt/current
  ln -s /etc/letsencrypt/live/${domains[0]} \
    /etc/letsencrypt/current/${domains[0]}
fi

if [ ! -d "/etc/letsencrypt/live/${domains[0]}-duplicate" ]; then
  echo "Duplicating initial certs"
  if [ ${update_type} == "rfc2136" ]; then
    /usr/bin/certbot certonly --reuse-key \
      --dns-rfc2136-credentials=/etc/letsencrypt/dns.ini \
      --dns-rfc2136 --duplicate \
      --cert-name "${domains[0]}-duplicate" \
      -d ${domains_joined%,} \
      -n -m ${le_account_email} --agree-tos \
      --no-autorenew
  elif [ ${update_type} == "cloudflare" ]; then
    /usr/bin/certbot certonly --reuse-key \
      --dns-cloudflare --duplicate \
      --cert-name "${domains[0]}-duplicate" \
      -d ${domains_joined%,} \
      -n -m ${le_account_email} --agree-tos \
      --no-autorenew
  fi
  mkdir -p /etc/letsencrypt/next
  ln -s /etc/letsencrypt/live/${domains[0]}-duplicate \
    /etc/letsencrypt/next/${domains[0]}
fi

# gather some initial info
cur_hash=$(openssl ec -in /etc/letsencrypt/current/${domains[0]}/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
next_hash=$(openssl ec -in /etc/letsencrypt/next/${domains[0]}/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

if [[ ${initial_setup} == "1" ]]; then
  echo "Starting DANE setup for ${domains[@]}"

  echo "Adding hashes to DNS"
  update_dns ${cur_hash}
  update_dns ${next_hash}
  echo "Waiting dns_prop_delay of ${dns_prop_delay} before checking DNS"
  sleep ${dns_prop_delay}
  check_dns ${cur_hash}
  check_dns ${next_hash}

  if [ ${service_type} == "k8s" ]; then
    insert_k8s_secret current
    restart_k8s_deployment
  else
    echo "Configure your application to use the files in /etc/letsencrypt/current/${domains[0]} and reload to use your new certificates"
  fi

  echo "Checking service for new certificates before continuing"
  check_service ${cur_hash}
  echo "New certificate found with hash ${1}"
  echo "Cleaning up LE dns.ini"
  rm /etc/letsencrypt/dns.ini
  echo "Initial setup done"
  exit 0
else
  echo "Starting DANE rollover for ${domains[@]}"

  # get transition
  if readlink "/etc/letsencrypt/current/${domains[0]}" | grep -q ".-duplicate"; then
    curr="-duplicate"
    next=""
    echo "Migrating from /etc/letsencrypt/live/${domains[0]}-duplicate to /etc/letsencrypt/live/${domains[0]}"
  else
    curr=""
    next="-duplicate"
    echo "Migrating from /etc/letsencrypt/live/${domains[0]} to /etc/letsencrypt/live/${domains[0]}-duplicate"
  fi

  # validate against "current", exit if weird.
  echo "Checking if live server is using the current certificate, /etc/letsencrypt/current/${domains[0]}/fullchain.pem"
  check_service ${cur_hash}

  # renew next before using
  /usr/bin/certbot renew --cert-name ${domains[0]}$next --force-renewal

  # get new cert hash for dns
  new_next_hash=$(openssl ec -in /etc/letsencrypt/next/${domains[0]}/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

  # ensure dns records exist
  update_dns ${new_next_hash}


  echo "Waiting dns_prop_delay of ${dns_prop_delay} before checking DNS"
  sleep ${dns_prop_delay}
  # verify dns records before applying new cert
  check_dns ${new_next_hash}

  echo "Swapping symlinks"
  rm "/etc/letsencrypt/next/${domains[0]}"
  rm "/etc/letsencrypt/current/${domains[0]}"
  ln -s "/etc/letsencrypt/live/${domains[0]}$next" "/etc/letsencrypt/current/${domains[0]}"
  ln -s "/etc/letsencrypt/live/${domains[0]}$curr" "/etc/letsencrypt/next/${domains[0]}"

  if [ ${service_type} == "k8s" ]; then
    # Apply next cert to deployment
    echo "Inserting new cert into secret"
    insert_k8s_secret current

    echo "Restarting deployment"
    restart_k8s_deployment
  else
    for service in ${systemd_services}; do
      systemctl ${sytemd_reload_type} ${service}
    done
  fi

  echo "Checking service for new certificates before continuing"
  check_service ${new_next_hash}

  echo 'Rollover complete'
fi
