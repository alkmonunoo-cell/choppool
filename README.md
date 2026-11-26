# ChopPool

Pooled lunch delivery for offices, student hostels and apartments in Ghana.

- Live app: https://choppool.com
- Team pages: https://choppool.com/#admin
- Database setup: paste `schema.sql` into the Supabase SQL Editor and run it once.


## Updating the database

There is one update file: `choppool-update.sql`. Whenever the app changes, this file is replaced with the latest version.

1. In Supabase, open **SQL Editor** and keep one saved query called **ChopPool update**.
2. Select everything in it, paste the new `choppool-update.sql` over it, and click **Run**.
3. You should see "ChopPool database is up to date".

It's safe to run any number of times and never deletes your data. `schema.sql` is only for setting up a brand-new database.

## Messages: WhatsApp and SMS (update 54)

One server function, `supabase/functions/sms`, sends every code and vendor invite. Deploy it with **Verify JWT off**.

Secrets (Supabase › Edge Functions › Secrets; never in the app or in chat):

| Secret | What it is |
| --- | --- |
| `WHATSAPP_TOKEN` | Meta System User token (never expires) |
| `WHATSAPP_PHONE_ID` | Phone number ID (defaults to the alerts number 1452676334597552) |
| `WHATSAPP_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN` | Optional: delivery receipts and auto-replies (Meta webhook) |
| `ARKESEL_API_KEY`, `SEND_SMS_HOOK_SECRET` | SMS and the Supabase "Send SMS" hook, as before |

WhatsApp templates (WhatsApp Manager): `login_code` (Authentication, copy code), `vendor_invite` (body: vendor name, building; URL button `https://choppool.com/?v={{1}}`) and `branch_check` (body: vendor name, building; same URL button).

Admin › Settings › Messages chooses which goes first, switches each channel on or off, and sends a test.
