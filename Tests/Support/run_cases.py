#!/usr/bin/env python3
"""Run each regression in a separate process with a deadline and truthful count."""
import subprocess
import sys

binary = sys.argv[1]
cases = subprocess.run([binary, '--list'], capture_output=True, text=True, timeout=10, check=True).stdout.splitlines()
if not cases or len(cases) != len(set(cases)):
    raise SystemExit('FAIL: empty or duplicate test registry')
failed = []
for case in cases:
    try:
        result = subprocess.run([binary, case], capture_output=True, text=True, timeout=30)
        if result.returncode:
            failed.append(case)
            print(f'FAIL {case}: exit {result.returncode}', flush=True)
            print(result.stdout + result.stderr)
        else:
            print(f'PASS {case}', flush=True)
    except subprocess.TimeoutExpired:
        failed.append(case)
        print(f'FAIL {case}: timeout 30s', flush=True)
print(f'{len(cases) - len(failed)}/{len(cases)} passed; {len(failed)} failed', flush=True)
raise SystemExit(bool(failed))
