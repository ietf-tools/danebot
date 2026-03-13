#!/bin/bash

# domains on the certificate
domain_list=${DANEBOT_DOMAINS:-"mail.mydomain.com mx.mydomain.com"}
domains=(${domain_list})
printf -v domains_joined '%s,' ${domains}
# ports to generate records for
tlsa_ports=${DANEBOT_PORTS:-"25 587"}
ports=(${tlsa_ports})
# generic options
ttl=300
dns_prop_delay=230
max_retries=100

# use rfc2136, or cloudflare for dns updates
update_type=${DANEBOT_UPDATE_TYPE:-rfc2136}
# needed for rfc2136 updates
master=${DANEBOT_RFC2136_MASTER:-192.0.2.234}
tsig_path=${DANEBOT_RFC2136_TSIG:-/etc/letsencrypt/tsig.key}
# needed for in-cluster actions
service_type=${DANEBOT_SERVICE_TYPE:-k8s}
namespace=${DANEBOT_K8S_NS:-mailserver}
deployment_type=${DANEBOT_K8S_DEPLOYMENT_TYPE:-deployments}
deployment_name=${DANEBOT_K8S_DEPLOYMENT_NAME:-mailserver-deployment}
secret_name=${DANEBOT_K8S_SECRET_NAME:-dane}

# k8s primitives, probably doont need to change
apiserver=https://kubernetes.default.svc
serviceaccount=/var/run/secrets/kubernetes.io/serviceaccount
namespace=$(cat ${serviceaccount}/namespace)
token=$(cat ${serviceaccount}/token)
cacert=${serviceaccount}/ca.crt


rfc2136_update() {
  printf "server ${master}\nupdate add _${1}._tcp.${2}. ${ttl} TLSA 3 1 1 ${3}\nsend" | nsupdate -k ${tsig_path}
}

rfc2136_remove() {
  printf "server ${master}\nupdate delete _${1}._tcp.${2}. ${ttl} TLSA 3 1 1 ${3}\nsend" | nsupdate -k ${tsig_path}
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

cleanup_records() {
  for d in ${domains[@]}; do
    for p in ${ports[@]}; do
      echo "deleting record _${p}._tcp.${d} ${$1}"
      rfc2136_remove ${p} ${d} ${1}
    done
  done
}

# gather some initial info
cur_hash=$(openssl ec -in /etc/letsencrypt/current/${domains[0]}/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
next_hash=$(openssl ec -in /etc/letsencrypt/next/${domains[0]}/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

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
openssl s_client -connect ${domains[0]}:${ports[0]} \
  -starttls smtp \
  -brief \
  -dane_tlsa_domain ${domains[0]} \
  -dane_tlsa_rrdata "3 1 1 ${cur_hash}" \
  -verify_return_error <<<"QUIT" 2>/dev/null

if [[ $? != 0 ]]; then
  echo "Not using the current cert"
  exit 1
fi

# renew next before using
certbot renew --cert-name ${domains[0]}$next --force-renewal

# get new cert hash for dns
new_next_hash=$(openssl ec -in /etc/letsencrypt/next/${domains[0]}/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

# ensure dns records exist
for d in ${domains[@]}; do
  for p in ${ports[@]}; do
    ${update_type}_update ${p} ${d} ${new_next_hash}
  done
done

# verify dns records before applying new cert
#
echo "Waiting dns_prop_delay of ${dns_prop_delay} before checking DNS"
sleep ${dns_prop_delay}

attempt=0
for d in ${domains[@]}; do
  for p in ${ports[@]}; do
    until dig +short _${p}._tcp.${d} tlsa | cut -d' ' -f4- | sed s/\ // | grep -i -q ${new_next_hash}; do
      ((attempt++))
      if [ ${attempt} -ge ${max_retries} ]; then
        echo "Did not find TLSA records after ${max_retries} attempts."
        exit 1
      fi
      echo "looking for ${new_next_hash} on _${p}._tcp.${d}, attempt ${attempt}"
      sleep 1
    done
    echo "found ${new_next_hash} on _${p}._tcp.${d}"
  done
done

if [ ${service_type} == "k8s" ]; then
  # Apply next cert to deployment

  echo "Inserting new cert into secret"

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
          "tls.crt": "'"$(cat /etc/letsencrypt/next/${domains[0]}/fullchain.pem | base64 -w 0)"'",
          "tls.key": "'"$(cat /etc/letsencrypt/next/${domains[0]}/privkey.pem | base64 -w 0)"'"
      },
      "type": "kubernetes.io/tls"
    }'

  echo "Restarting deployment"
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

  echo "Checking service for new certificates before continuing"
  # validate against "next"
  check_attempt=0
  until openssl s_client -connect ${domains[0]}:${ports[0]} -starttls smtp -brief -dane_tlsa_domain ${domains[0]} -dane_tlsa_rrdata "3 1 1 ${new_next_hash}" -verify_return_error <<<"QUIT" 2>/dev/null; do
    ((check_attempt++))
    echo "Checking for new certificate, attempt ${check_attempt}"
    if [ ${check_attempt} -ge ${max_retries} ]; then
      echo "Did not find new certificate after ${max_retries} attempts."
      exit 1
    fi
    sleep 1
  done
  echo "New certificate found with hash ${new_next_hash}"
fi

# swap symlinks
echo 'Swapping symlinks after successful deployment'
rm "/etc/letsencrypt/next/${domains[0]}"
rm "/etc/letsencrypt/current/${domains[0]}"
ln -s "/etc/letsencrypt/live/${domains[0]}$next" "/etc/letsencrypt/current/${domains[0]}"
ln -s "/etc/letsencrypt/live/${domains[0]}$curr" "/etc/letsencrypt/next/${domains[0]}"

echo 'Rollover complete'
