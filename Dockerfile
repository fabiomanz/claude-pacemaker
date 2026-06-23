FROM alpine:3.20

RUN apk add --no-cache bash curl jq coreutils tzdata ca-certificates

COPY pacemaker.sh /usr/local/bin/pacemaker.sh
RUN chmod +x /usr/local/bin/pacemaker.sh

ENTRYPOINT ["/usr/local/bin/pacemaker.sh"]
