# Third-Party Notices

## SwiftTerm

muty uses SwiftTerm 1.20.0 by Miguel de Icaza and contributors under the MIT License.

The dependency is declared in `Package.swift`. Its license is copied into application bundles as `Contents/Resources/SwiftTerm-LICENSE`.

## OpenSSH portable compatibility code

`Sources/SecureCRTSupport/bcrypt_pbkdf.c`, `blowfish.c` and `blf.h` originate from OpenSSH portable tag `V_10_2_P1`, commit `d01efaa1c9ed84fd9011201dbc3c7cb0a82bcee3`.

These files retain their ISC-style and BSD-3-Clause-style notices. The combined text is available in `Sources/SecureCRTSupport/LICENSE` and is copied into application bundles as `Contents/Resources/SecureCRTSupport-LICENSE`.

Local adaptations permit an empty SecureCRT configuration passphrase, prefix exported symbols, use CommonCrypto SHA-512 and provide local explicit-memory-zeroing helpers.

## SecureCRT format reference

The independently implemented SecureCRT `Password V2` 02/03 decoder uses publicly documented format information from the HyperSine `how-does-SecureCRT-encrypt-password` research repository. No HyperSine source file is included in muty.

SecureCRT is a trademark of VanDyke Software. muty is not affiliated with or endorsed by VanDyke Software.
