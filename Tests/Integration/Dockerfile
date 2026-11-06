FROM alpine:3.22
RUN apk add --no-cache openssh-server vim && adduser -D tester && mkdir -p /home/tester/.ssh /run/sshd && chown -R tester:tester /home/tester
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
