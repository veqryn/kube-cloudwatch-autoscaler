FROM alpine:3.11

LABEL maintainer="Chris Duncan <github.com/veqryn>"

# Install software requirements
RUN set -eux; \
  apk update; \
  apk upgrade; \
  apk add --update --no-cache tzdata ca-certificates curl jq bash less; \
  apk add --update --no-cache --repository https://dl-3.alpinelinux.org/alpine/edge/community aws-cli; \
  rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Add script
COPY ./entrypoint.sh /usr/local/bin/

# Command
CMD ["/usr/local/bin/entrypoint.sh"]
