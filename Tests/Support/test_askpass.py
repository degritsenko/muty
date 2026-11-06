#!/usr/bin/env python3
"""Exercise the actual compiled helper over its real Unix-socket protocol."""
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading

helper = str(Path(sys.argv[1]).resolve())
count = 0

def case(name, reply, accepted, expected=b''):
    global count
    with tempfile.TemporaryDirectory(prefix='muty-ipc-', dir='/tmp') as directory:
        path = directory + '/a'
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        os.chmod(path, 0o600)
        listener.listen(1)
        listener.settimeout(5)
        token = secrets.token_hex(16)
        errors = []
        def serve():
            try:
                with listener.accept()[0] as client:
                    client.settimeout(5)
                    def read(n):
                        data = b''
                        while len(data) < n:
                            part = client.recv(n-len(data))
                            if not part:
                                raise RuntimeError('truncated request')
                            data += part
                        return data
                    size = struct.unpack('!I', read(4))[0]
                    assert 0 < size <= 65536
                    request = json.loads(read(size))
                    assert request == {'token': token, 'connection': 'test-run',
                                       'prompt': "tester@localhost's password: ", 'kind': ''}
                    if reply is not None:
                        for byte in reply:
                            client.sendall(bytes([byte]))
            except Exception as error:
                errors.append(error)
            finally:
                listener.close()
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        env = dict(os.environ, MUTY_ASKPASS_SOCKET=path, MUTY_ASKPASS_TOKEN=token,
                   MUTY_ASKPASS_CONNECTION='test-run', SSH_ASKPASS_PROMPT='')
        result = subprocess.run([helper, "tester@localhost's password: "], env=env,
                                capture_output=True, timeout=10)
        worker.join(6)
        assert not worker.is_alive() and not errors, name
        assert (result.returncode == 0) == accepted, name
        assert result.stdout == expected and result.stderr == b'', name
        count += 1
        print('PASS ' + name)

def packet(value):
    data = json.dumps(value).encode()
    return struct.pack('!I', len(data)) + data

case('askpass.fragmentedResponse', packet({'accepted': True, 'value': 'disposable-test-secret'}), True, b'disposable-test-secret\n')
case('askpass.deniedNoOutput', packet({'accepted': False, 'value': 'must-not-leak'}), False)
case('askpass.zeroLength', struct.pack('!I', 0), False)
case('askpass.oversized', struct.pack('!I', 65537), False)
case('askpass.truncated', struct.pack('!I', 100) + b'{}', False)
case('askpass.invalidJSON', struct.pack('!I', 3) + b'bad', False)
case('askpass.peerClosed', None, False)
env = {k: v for k,v in os.environ.items() if not k.startswith('MUTY_ASKPASS_')}
result = subprocess.run([helper, 'password'], env=env, capture_output=True, timeout=5)
assert result.returncode != 0 and not result.stdout and not result.stderr
count += 1
print('PASS askpass.missingEnvironment')
print(f'{count}/{count} actual-helper checks passed')
