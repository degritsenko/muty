#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native
bin="$(swift build --build-system native --show-bin-path)"
objects=()
for object in "$bin"/muty.build/*.swift.o "$bin"/SwiftTerm.build/*.o "$bin"/MutyIPC.build/*.o "$bin"/SecureCRTSupport.build/*.o; do
 [[ "$object" == */MutyApp.swift.o ]] && continue
 [[ "$object" == "$bin"/muty.build/* && ! -f "Sources/muty/$(basename "${object%.o}")" ]] && continue
 objects+=("$object")
done
swiftc -parse-as-library -enable-testing -I "$bin/Modules" -Xcc -fmodule-map-file="$bin/SecureCRTSupport.build/module.modulemap" -Xcc -I -Xcc "$PWD/Sources/SecureCRTSupport/include" Tests/MutyTests/*.swift "${objects[@]}" -o "$bin/muty-regression-tests"
python3 Tests/Support/run_cases.py "$bin/muty-regression-tests"

python3 Tests/Support/test_askpass.py "$bin/muty-askpass"
