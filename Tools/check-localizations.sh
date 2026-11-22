#!/bin/bash
# Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
# SPDX-License-Identifier: MIT
#
# Lists texts the code looks up for translation that aren't in Support/Localization/keys.json yet
# (so they'd show in English). Compiles into a scratch folder with -emit-localized-strings.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swift build --build-path "$TMP/b" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$TMP/sd" >/dev/null
python3 - "$TMP/sd" <<'PY'
import json, glob, re, sys
known = set(json.load(open('Support/Localization/keys.json')))
used = set()
for f in glob.glob(sys.argv[1] + '/*.stringsdata'):
    for entries in json.load(open(f)).get('tables', {}).values():
        used.update(e['key'] for e in entries)
new = sorted(k for k in used - known if re.search(r'[A-Za-z]{3}', k))
print('\n'.join(new) if new else 'All texts are in keys.json.')
PY
