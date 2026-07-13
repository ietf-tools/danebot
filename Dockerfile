FROM alpine:3.22.4

RUN apk add --no-cache certbot certbot-dns-rfc2136 \
    jq py3-tldextract certbot-dns-cloudflare bash \
    bind-tools curl openssl

COPY . /app

ENTRYPOINT /app/dane.sh
