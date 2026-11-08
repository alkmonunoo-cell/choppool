#!/bin/sh
# Build the live site from the demo source: keep the live CONFIG, stamp a new cache version so phones update.
set -e
SRC=${1:-../choppool/index.html}
python3 - "$SRC" <<'PY'
import sys, re, time
src = open(sys.argv[1]).read(); live = open('index.html').read()
a = live.index('const CONFIG = {'); b = live.index('};', a) + 2
sa = src.index('const CONFIG = {'); sb = src.index('};', sa) + 2
open('index.html', 'w').write(src[:sa] + live[a:b] + src[sb:])
sw = open('sw.js').read()
sw = re.sub(r'choppool-v[0-9A-Za-z.-]+', 'choppool-v' + time.strftime('%Y%m%d%H%M', time.gmtime()), sw, count=1)
open('sw.js', 'w').write(sw)
print('built index.html; cache', re.search(r'choppool-v[0-9A-Za-z.-]+', sw).group(0))
PY
