#!/bin/sh
# Set/check nanomon's package version without changing nanoui's version.
set -eu
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
from pathlib import Path
import re
import sys
p = Path('build.zig.zon')
s = p.read_text()
pattern = r'(?m)^(    \.version = ")([^"]+)(",)$'
m = re.search(pattern, s)
assert m, 'missing package version'
args = sys.argv[1:]
if not args:
    print(m[2])
elif args[0] == '--check':
    assert len(args) == 2 and args[1].removeprefix('v') == m[2], 'tag/package version mismatch'
    print('nanomon is at ' + m[2])
else:
    assert len(args) == 1 and re.fullmatch(r'\d+\.\d+\.\d+', args[0]), 'usage: version.sh major.minor.patch | --check vX.Y.Z'
    p.write_text(s[:m.start(2)] + args[0] + s[m.end(2):])
    print('Set nanomon to ' + args[0])
PY
