# Privacy

muty does not require an account and does not include telemetry, analytics, advertising or a muty-operated cloud service.

Data such as sessions, preferences, credentials, backups, terminal logs and transfer history is processed locally. Network connections are initiated only for user-requested SSH/SFTP sessions, tunnels and related host-key checks performed by the system OpenSSH client.

Passwords may be stored in the local muty vault. Private SSH keys remain at their selected filesystem paths and are not included in muty backups. Plain backups that include passwords contain readable secrets and require explicit acknowledgement.

Terminal output logging is opt-in. Log files may contain sensitive remote output and are created with mode `0600`.
