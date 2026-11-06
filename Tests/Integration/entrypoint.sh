#!/bin/sh
set -eu
ssh-keygen -A >/dev/null 2>&1
cp /fixtures/client.pub /home/tester/.ssh/authorized_keys
chown tester:tester /home/tester/.ssh/authorized_keys
chmod 700 /home/tester/.ssh
chmod 600 /home/tester/.ssh/authorized_keys
printf 'tester:%s\n' "$(cat /fixtures/password)" | chpasswd
exec /usr/sbin/sshd -D -e -o PasswordAuthentication=yes -o PermitRootLogin=no -o AllowUsers=tester -o AllowTcpForwarding=yes
