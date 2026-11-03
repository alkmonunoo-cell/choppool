# ChopPool

Pooled lunch delivery for offices, student hostels and apartments in Ghana.

- Live app: https://alkmonunoo-cell.github.io/choppool/
- Team pages: https://alkmonunoo-cell.github.io/choppool/#admin
- Database setup: paste `schema.sql` into the Supabase SQL Editor and run it once.


## Updating the database

There is one update file: `choppool-update.sql`. Whenever the app changes, this file is replaced with the latest version.

1. In Supabase, open **SQL Editor** and keep one saved query called **ChopPool update**.
2. Select everything in it, paste the new `choppool-update.sql` over it, and click **Run**.
3. You should see "ChopPool database is up to date".

It's safe to run any number of times and never deletes your data. `schema.sql` is only for setting up a brand-new database.
