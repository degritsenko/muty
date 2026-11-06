# Security Policy

## Reporting a vulnerability

Do not open a public issue for vulnerabilities involving credentials, authentication, host-key verification, backup encryption, file replacement, command execution or privilege boundaries.

Use GitHub Private Vulnerability Reporting for this repository. Include:

- affected version or commit;
- macOS version and architecture;
- minimal reproduction steps using disposable credentials and hosts;
- expected and observed behavior;
- impact assessment;
- relevant logs with secrets, usernames, hostnames and addresses removed.

Never test against another person's system or use production credentials for failure, lockout or corruption testing.

## Supported versions

Until the first stable release, security fixes target the latest published beta only.

## Security boundaries

- SSH runs through the system OpenSSH client with `-F /dev/null`. Existing SSH configuration, default identities and the agent are not used implicitly.
- Password prompts use a private authenticated Unix socket. Verify new host-key fingerprints before trusting them.
- The local vault uses AES-256-GCM. Master-password mode derives its key with PBKDF2-HMAC-SHA256 at 600,000 iterations. Backups exclude private SSH keys.
- Process memory may retain secret material. Complete zeroization is not guaranteed.

muty is a local desktop client and does not protect against a compromised macOS user account, malicious administrator, modified operating system or process-memory inspection. Automatic vault mode is not a security boundary because its key is stored locally beside the encrypted data.
