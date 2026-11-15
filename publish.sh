#!/bin/sh
# Build the live site from the demo source: keep the live CONFIG, stamp a new cache version so phones update.
# _src/index.html is the readable page; index.html is the smaller copy phones download (see minify.py).
set -e
SRC=${1:-../choppool/index.html}
python3 - "$SRC" <<'PY'
import sys, re, time
import os
src = open(sys.argv[1]).read(); live = open('_src/index.html' if os.path.exists('_src/index.html') else 'index.html').read()
a = live.index('const CONFIG = {'); b = live.index('};', a) + 2
sa = src.index('const CONFIG = {'); sb = src.index('};', sa) + 2
os.makedirs('_src', exist_ok=True)
open('_src/index.html', 'w').write(src[:sa] + live[a:b] + src[sb:])
sw = open('sw.js').read()
sw = re.sub(r'choppool-v[0-9A-Za-z.-]+', 'choppool-v' + time.strftime('%Y%m%d%H%M', time.gmtime()), sw, count=1)
open('sw.js', 'w').write(sw)
print('built index.html; cache', re.search(r'choppool-v[0-9A-Za-z.-]+', sw).group(0))
PY
python3 minify.py _src/index.html index.html
