#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
name="muty-test-$(uuidgen | tr '[:upper:]' '[:lower:]')"
fixtures="$(mktemp -d /tmp/muty-ssh-test.XXXXXX)"
chmod 700 "$fixtures"
agent_pid=""
cleanup() {
 [[ -z "$agent_pid" ]] || kill "$agent_pid" 2>/dev/null || true
 docker rm -f "$name" >/dev/null 2>&1 || true
 python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$fixtures"
}
trap cleanup EXIT INT TERM
ssh-keygen -q -t ed25519 -N '' -f "$fixtures/client"
python3 -c 'import secrets,sys; open(sys.argv[1],"w").write(secrets.token_urlsafe(24))' "$fixtures/password"
chmod 600 "$fixtures/password"
docker build -t muty-test-sshd:local Tests/Integration >/dev/null
docker run -d --name "$name" -p 127.0.0.1::22 -v "$fixtures:/fixtures:ro" muty-test-sshd:local >/dev/null
port="$(docker port "$name" 22/tcp | sed 's/.*://')"
opts=(-F /dev/null -p "$port" -i "$fixtures/client" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$fixtures/known_hosts")
ready=0
for attempt in $(seq 1 20); do
 if ssh "${opts[@]}" tester@127.0.0.1 'printf MUTY_READY' >"$fixtures/result" 2>"$fixtures/error"; then ready=1; break; fi
 sleep 1
done
[[ "$ready" == 1 ]] || { echo 'FAIL sshd readiness'; cat "$fixtures/error"; exit 1; }
grep -qx MUTY_READY "$fixtures/result"
echo 'PASS integration.identityLogin'
ssh "${opts[@]}" tester@127.0.0.1 'test "$(id -un)" = tester && printf "unicode: Привет\n"' >"$fixtures/result"
grep -q 'Привет' "$fixtures/result"
echo 'PASS integration.unicodeCommand'
run_pty_case() {
 MUTY_TEST_PORT="$port" MUTY_TEST_FIXTURES="$fixtures" MUTY_TEST_CONTAINER="$name" \
 python3 - "$bin/muty-regression-tests" "$1" <<'PYTHON'
import subprocess
import sys

try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=60).returncode)
except subprocess.TimeoutExpired:
    sys.exit(f"FAIL {sys.argv[2]}: timeout after 60s")
PYTHON
}
if [[ "${MUTY_TEST_PTY:-0}" == 1 ]]; then
 bin="$(swift build --build-system native --show-bin-path)"
 run_pty_case integration.ptySSH
 echo 'PASS integration.appSwiftTermPTY'
 run_pty_case integration.fullPassword
 echo 'PASS integration.fullPasswordConnection'
 run_pty_case integration.fullWrongPassword
 echo 'PASS integration.fullWrongPasswordConnection'
 run_pty_case integration.lifecycle
 echo 'PASS integration.lifecycleStress'
 run_pty_case integration.parallel
 echo 'PASS integration.authCancelAndParallel'
 run_pty_case integration.isolatedHostKeys
 echo 'PASS integration.isolatedHostKeysSSHAndSFTP'
fi
# Password via a test-only helper; its output is never recorded.
cat > "$fixtures/askpass" <<'HELPER'
#!/bin/sh
cat "$MUTY_TEST_PASSWORD_FILE"
HELPER
chmod 700 "$fixtures/askpass"
password_opts=(-F /dev/null -p "$port" -o PreferredAuthentications=password -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=3 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$fixtures/known_hosts")
DISPLAY=muty-test SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$fixtures/askpass" MUTY_TEST_PASSWORD_FILE="$fixtures/password" ssh "${password_opts[@]}" tester@127.0.0.1 'test "$(id -un)" = tester' </dev/null
echo 'PASS integration.passwordLogin'
printf 'intentionally-wrong-disposable-password' > "$fixtures/wrong-password"
if DISPLAY=muty-test SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$fixtures/askpass" MUTY_TEST_PASSWORD_FILE="$fixtures/wrong-password" ssh "${password_opts[@]}" tester@127.0.0.1 true </dev/null >/dev/null 2>"$fixtures/error"; then
 echo 'FAIL integration.wrongPassword'; exit 1
fi
grep -q 'Permission denied' "$fixtures/error"
echo 'PASS integration.wrongPassword'
# Dedicated agent only, no user agent or identity files.
eval "$(ssh-agent -s)" >/dev/null
agent_pid="$SSH_AGENT_PID"
ssh-add "$fixtures/client" >/dev/null 2>&1
ssh -F /dev/null -p "$port" -o IdentityFile=none -o IdentitiesOnly=no -o BatchMode=yes -o PreferredAuthentications=publickey -o ConnectTimeout=3 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$fixtures/known_hosts" tester@127.0.0.1 true
echo 'PASS integration.agentLogin'

# Encrypt a copy of the authorized key; passphrase is delivered only by helper pipe.
cp "$fixtures/client" "$fixtures/encrypted"
printf 'disposable-test-passphrase' > "$fixtures/passphrase"
ssh-keygen -q -p -P '' -N 'disposable-test-passphrase' -f "$fixtures/encrypted" >/dev/null
DISPLAY=muty-test SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$fixtures/askpass" MUTY_TEST_PASSWORD_FILE="$fixtures/passphrase" ssh -F /dev/null -p "$port" -i "$fixtures/encrypted" -o IdentityAgent=none -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ConnectTimeout=3 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$fixtures/known_hosts" tester@127.0.0.1 true </dev/null
echo 'PASS integration.encryptedIdentityLogin'

# A different, disposable host identity must be rejected, never accepted silently.
cp "$fixtures/known_hosts" "$fixtures/known_hosts.valid"
ssh-keygen -q -t ed25519 -N '' -f "$fixtures/wrong-host"
printf '[127.0.0.1]:%s %s\n' "$port" "$(cat "$fixtures/wrong-host.pub")" >"$fixtures/known_hosts"
if ssh "${opts[@]}" tester@127.0.0.1 true > /dev/null 2>"$fixtures/error"; then
 echo 'FAIL integration.changedHostKey'; exit 1
fi
grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$fixtures/error"
echo 'PASS integration.changedHostKey'
cp "$fixtures/known_hosts.valid" "$fixtures/known_hosts"
if [[ "${MUTY_TEST_PTY:-0}" == 1 ]]; then
 run_pty_case integration.serverTermination
 echo 'PASS integration.serverTermination'
 docker start "$name" >/dev/null
 port="$(docker port "$name" 22/tcp | sed 's/.*://')"
 ready=0
 for attempt in $(seq 1 20); do
  if ssh -F /dev/null -p "$port" -i "$fixtures/client" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$fixtures/known_hosts" tester@127.0.0.1 true 2>/dev/null; then ready=1; break; fi
  sleep 1
 done
 [[ "$ready" == 1 ]] || { echo 'FAIL restart readiness'; exit 1; }
 run_pty_case integration.blackhole
 echo 'PASS integration.silentTransportLoss'
 echo '15/15 integration checks passed'
else
 echo '7/7 CLI checks passed; SwiftTerm PTY skipped (set MUTY_TEST_PTY=1 after scripts/test.sh)'
fi
