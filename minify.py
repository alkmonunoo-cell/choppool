#!/usr/bin/env python3
"""Make the served page smaller without changing what it does.

Reads the readable page (src/index.html) and writes index.html:
  - the demo data layer is left out when the page has a live Supabase CONFIG (it never runs there)
  - the app script and styles are minified with esbuild, when esbuild is available
If esbuild is missing or fails, the readable page is served as it is, so a release never breaks.
"""
import os, re, shutil, subprocess, sys, tempfile

SRC, OUT = sys.argv[1], sys.argv[2]
page = open(SRC).read()

ESBUILD = shutil.which("esbuild") or next((p for p in ["/opt/npm-tools/node_modules/esbuild/bin/esbuild", "/tmp/min/node_modules/.bin/esbuild"] if os.path.exists(p)), None)

def esb(code, loader):
    if not ESBUILD:
        return None
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "in." + loader); out = os.path.join(d, "out." + loader)
        open(src, "w").write(code)
        r = subprocess.run([ESBUILD, src, "--minify", "--target=esnext", "--charset=utf8", "--legal-comments=none", "--log-level=error", "--outfile=" + out], capture_output=True, text=True)
        if r.returncode != 0:
            print("minify skipped (" + loader + "):", r.stderr.strip()[:300]); return None
        return open(out).read().rstrip("\n")

# The app script is the last <script> block
i = page.rfind("<script>"); j = i + len("<script>"); k = page.rfind("</script>")
js = page[j:k]
live = re.search(r'SUPABASE_URL:\s*"https://', js) is not None
if live:
    a = js.index("function makeDemoApi() {"); b = js.index("\n}\n", a) + 3
    js = js[:a] + "function makeDemoApi() { return null; }\n" + js[b:]
mjs = esb(js, "js")
if mjs is not None:
    # never let a closing script tag inside a string end the block early
    if "</script" in mjs.lower():
        mjs = None; print("minify skipped (js): closing tag inside the code")
page = page[:j] + (mjs if mjs is not None else js) + page[k:]

# Styles
def css_sub(m):
    c = esb(m.group(2), "css")
    return m.group(1) + (c if c is not None else m.group(2)) + m.group(3)
page = re.sub(r'(<style[^>]*>)(.*?)(</style>)', css_sub, page, flags=re.S)

open(OUT, "w").write(page)
print("served page:", len(page.encode()) // 1024, "KB", "(demo layer removed)" if live else "")
