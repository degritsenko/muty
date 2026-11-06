# SecureCRT password import support

bcrypt_pbkdf.c, blowfish.c, blf.h originate from OpenSSH portable tag V_10_2_P1 (commit d01efaa1c9ed84fd9011201dbc3c7cb0a82bcee3):
https://github.com/openssh/openssh-portable/tree/V_10_2_P1/openbsd-compat

Original licenses are retained in the source and distributed in SecureCRTSupport-LICENSE.
Local adaptations: accept an empty configuration passphrase, prefix the bcrypt_pbkdf
symbol, use CommonCrypto SHA-512 and local explicit memory-zeroing compatibility helpers.

SecureCRT Password V2 formats 02/03 use AES-256-CBC, a length-prefixed UTF-8
password, SHA-256 integrity checksum and random padding. Format 03 derives its
key/IV via bcrypt_pbkdf (16 rounds, 16-byte salt, 48-byte output). Format 02 uses
SHA-256 of the configuration passphrase and a zero IV.
Algorithm reference: https://github.com/HyperSine/how-does-SecureCRT-encrypt-password
