# ChopPool checks

Run before every release. They use the demo build (no live data) and a local Postgres copy of the schema.

Browser flows (Playwright), from the folder that holds the demo `index.html`:

```
python3 -m http.server 8765 &
for t in tests/browser/run*.js; do node "$t"; done   # each ends with "errors []"
```

Database (local Postgres on port 5499):

```
createdb tf && psql -d tf -f tests/db/stub.sql && psql -d tf -f schema.sql
for t in t14 t15 t16 t18 t18b; do psql -d tf -f tests/db/$t.sql; done
psql -d tf -f tests/db/sec.sql    # security: every write through a public view, helper call and coordinator overreach must fail
psql -d tf -f tests/db/atk.sql    # the order-theft chain from the 7 Nov audit: must no longer work
```
