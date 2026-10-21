# The current Alpine release, so a rebuild with --pull moves on by itself
# (3.20, pinned before, had run out of support).
FROM alpine:3

RUN apk add --no-cache bash curl jq coreutils tzdata ca-certificates

COPY pacemaker.sh /usr/local/bin/pacemaker.sh
RUN chmod +x /usr/local/bin/pacemaker.sh

ENTRYPOINT ["/usr/local/bin/pacemaker.sh"]
