# ChopPool sign-in emails

Two parts: send from **ChopPool <hello@choppool.com>** instead of "Supabase Auth", and use ChopPool's own wording and colours.

## Part 1: send from your own address (about 15 minutes)

Supabase's built-in email always shows "Supabase Auth" and only sends a few emails an hour. A free email service fixes both.

1. Go to **resend.com** and create a free account (3,000 emails a month, 100 a day).
2. **Domains → Add domain** → `choppool.com`.
3. Resend shows a few DNS records. Choose **"Sign in to Cloudflare"** to add them automatically, or add them yourself in Cloudflare → choppool.com → DNS → Records. Leave each one on **DNS only** (grey cloud). Wait for Resend to say **Verified** (usually a few minutes).
4. Resend → **API Keys → Create API key** (Sending access, choppool.com). Copy it. Don't share it.
5. Supabase → **Authentication → Emails → SMTP Settings** (or Project Settings → Auth → SMTP) → **Enable custom SMTP**:
   - Sender email: `hello@choppool.com`
   - Sender name: `ChopPool`
   - Host: `smtp.resend.com`
   - Port: `465`
   - Username: `resend`
   - Password: the API key from step 4
   - Save.
6. Supabase → Authentication → **Rate limits**: raise "emails sent per hour" to 30.

## Part 2: ChopPool wording

Supabase → **Authentication → Emails → Templates**. For each one, set the subject and paste the message (switch to the HTML/source view first).

### Reset password

**Subject:** `Reset your ChopPool password`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#1F1A17">
  <p style="font-size:20px;font-weight:bold;color:#D9480F;margin:0 0 16px">ChopPool</p>
  <h1 style="font-size:22px;margin:0 0 12px">Reset your password</h1>
  <p style="font-size:16px;line-height:1.5;margin:0 0 20px">Someone asked to reset the password for your ChopPool account. Tap the button to choose a new one.</p>
  <p style="margin:0 0 24px"><a href="{{ .ConfirmationURL }}" style="display:inline-block;background:#D9480F;color:#ffffff;text-decoration:none;font-weight:bold;padding:14px 24px;border-radius:12px">Choose a new password</a></p>
  <p style="font-size:14px;line-height:1.5;color:#6B625C;margin:0">Open it on the phone you use for ChopPool. If you didn't ask for this, ignore this email: your password stays the same.</p>
  <p style="font-size:13px;color:#9A918A;margin:24px 0 0">ChopPool · Order together, pay less</p>
</div>
```

### Confirm signup

**Subject:** `Welcome to ChopPool: confirm your email`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#1F1A17">
  <p style="font-size:20px;font-weight:bold;color:#D9480F;margin:0 0 16px">ChopPool</p>
  <h1 style="font-size:22px;margin:0 0 12px">Welcome to ChopPool</h1>
  <p style="font-size:16px;line-height:1.5;margin:0 0 20px">Confirm your email to keep your delivery cashback and see your orders on any phone.</p>
  <p style="margin:0 0 24px"><a href="{{ .ConfirmationURL }}" style="display:inline-block;background:#D9480F;color:#ffffff;text-decoration:none;font-weight:bold;padding:14px 24px;border-radius:12px">Confirm my email</a></p>
  <p style="font-size:14px;line-height:1.5;color:#6B625C;margin:0">If you didn't sign up for ChopPool, ignore this email.</p>
  <p style="font-size:13px;color:#9A918A;margin:24px 0 0">ChopPool · Order together, pay less</p>
</div>
```

### Change email address

**Subject:** `Confirm your new ChopPool email`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#1F1A17">
  <p style="font-size:20px;font-weight:bold;color:#D9480F;margin:0 0 16px">ChopPool</p>
  <h1 style="font-size:22px;margin:0 0 12px">Confirm your new email</h1>
  <p style="font-size:16px;line-height:1.5;margin:0 0 20px">Tap the button to use {{ .NewEmail }} for your ChopPool account.</p>
  <p style="margin:0 0 24px"><a href="{{ .ConfirmationURL }}" style="display:inline-block;background:#D9480F;color:#ffffff;text-decoration:none;font-weight:bold;padding:14px 24px;border-radius:12px">Confirm new email</a></p>
  <p style="font-size:14px;line-height:1.5;color:#6B625C;margin:0">If you didn't ask for this, ignore this email.</p>
  <p style="font-size:13px;color:#9A918A;margin:24px 0 0">ChopPool · Order together, pay less</p>
</div>
```

## Check

Use "Forgot password" on https://choppool.com. The email should come from **ChopPool**, say "Reset your ChopPool password", and the button should open the new-password page.
