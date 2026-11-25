// ChopPool messages: sign-in codes, vendor invites and vendor "Forgot PIN" codes, by WhatsApp or SMS (update 54).
//
// Who calls it:
//   1. Supabase Auth, through its "Send SMS" hook, whenever a customer needs a phone code (signed by Supabase).
//   2. The app: { action: "invite" } after a customer invites a vendor, { action: "vendor_code" } for a vendor's
//      Forgot PIN, and the team's { action: "test" } / { action: "status" } in Admin › Settings › Messages.
//   3. Meta (WhatsApp): delivery receipts and replies to the alerts number (webhook, optional).
//
// Order: Admin › Settings › Messages says which channel goes first; the other is the backup. If both fail, a vendor
// invite goes to the team's New vendors list. Nothing is sent by a channel that isn't switched on and set up.
//
// Secrets (Supabase › Edge Functions › Secrets), never in the app or in chat:
//   WHATSAPP_TOKEN            permanent System User token from Meta
//   WHATSAPP_PHONE_ID         Phone number ID (default: ChopPool's alerts number)
//   WHATSAPP_APP_SECRET       Meta app › Settings › Basic › App secret (checks replies really come from Meta)
//   WHATSAPP_VERIFY_TOKEN     any long random words you choose, typed again in Meta's webhook setup
//   ARKESEL_API_KEY           SMS (Arkesel)
//   SEND_SMS_HOOK_SECRET      shown by Supabase when you create the Send SMS hook (v1,whsec_...)
//   Optional: SMS_SENDER (ChopPool), WHATSAPP_LANG (en), WHATSAPP_API_VERSION (v24.0), APP_URL (https://choppool.com)
// Deploy with "Verify JWT" OFF: this function checks every caller itself.
import { createClient } from "npm:@supabase/supabase-js@2";

const env = (k: string, d = "") => Deno.env.get(k) || d;
const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
const APP = env("APP_URL", "https://choppool.com").replace(/\/$/, "");
const GRAPH = () => `https://graph.facebook.com/${env("WHATSAPP_API_VERSION", "v24.0")}/${env("WHATSAPP_PHONE_ID", "1452676334597552")}/messages`;
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });
const hookFail = (status: number, message: string) =>
  new Response(JSON.stringify({ error: { http_code: status, message } }), { status, headers: { "content-type": "application/json" } });

// ---------- small helpers ----------
function b64ToBytes(b64: string) { const s = atob(b64); return Uint8Array.from(s, c => c.charCodeAt(0)); }
function bytesToB64(b: Uint8Array) { let s = ""; b.forEach(x => { s += String.fromCharCode(x); }); return btoa(s); }
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, "0")).join("");
function same(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const ghPhone = (p: unknown) => {   // 0241234567 / +233 24 123 4567 -> 233241234567 (Ghana only)
  const d = String(p || "").replace(/\D/g, "");
  return /^0\d{9}$/.test(d) ? "233" + d.slice(1) : /^233\d{9}$/.test(d) ? d : null;
};
const sha256 = async (s: string) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
const sixDigits = () => String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");

async function log(kind: string, phone: string | null, channel: string | null, status: string, detail = "", ref: string | null = null, kitchen: string | null = null) {
  try {
    await db.from("msg_log").insert({ kind, phone, channel, status, detail: detail.slice(0, 300) || null, ref, kitchen_id: kitchen });
    if (Math.random() < 0.02) await db.from("msg_log").delete().lt("created_at", new Date(Date.now() - 90 * 864e5).toISOString());
  } catch (_) { /* logging never stops a message */ }
}

async function settings() {
  const { data } = await db.from("settings").select("msg_first, wa_ready, sms_ready, msg_reply").eq("id", 1).single();
  return data || { msg_first: "whatsapp", wa_ready: true, sms_ready: false, msg_reply: null };
}
// The channels to try, in order: only those switched on in Settings and set up with a secret
async function channels(skip: string[] = []) {
  const s = await settings();
  const order = s.msg_first === "sms" ? ["sms", "whatsapp"] : ["whatsapp", "sms"];
  return order.filter(c => !skip.includes(c) && (c === "whatsapp" ? s.wa_ready && !!env("WHATSAPP_TOKEN") : s.sms_ready && !!env("ARKESEL_API_KEY")));
}

// ---------- senders ----------
type Sent = { ok: boolean; ref?: string; error?: string };
async function whatsapp(payload: Record<string, unknown>): Promise<Sent> {
  try {
    const r = await fetch(GRAPH(), { method: "POST", headers: { Authorization: "Bearer " + env("WHATSAPP_TOKEN"), "Content-Type": "application/json" },
      body: JSON.stringify({ messaging_product: "whatsapp", recipient_type: "individual", ...payload }) });
    const out = await r.json().catch(() => ({}));
    if (!r.ok) return { ok: false, error: "whatsapp " + r.status + ": " + (out?.error?.error_data?.details || out?.error?.message || "error") };
    return { ok: true, ref: out?.messages?.[0]?.id };
  } catch (e) { return { ok: false, error: "whatsapp: " + (e as Error).message }; }
}
const waTemplate = (to: string, name: string, body: string[], button?: string) => whatsapp({
  to, type: "template",
  template: { name, language: { code: env("WHATSAPP_LANG", "en") }, components: [
    ...(body.length ? [{ type: "body", parameters: body.map(text => ({ type: "text", text })) }] : []),
    ...(button != null ? [{ type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: button }] }] : []) ] },
});
async function sms(to: string, message: string): Promise<Sent> {
  try {
    const r = await fetch("https://sms.arkesel.com/api/v2/sms/send", { method: "POST", headers: { "api-key": env("ARKESEL_API_KEY"), "Content-Type": "application/json" },
      body: JSON.stringify({ sender: env("SMS_SENDER", "ChopPool"), recipients: [to], message }) });
    const out = await r.json().catch(() => ({}));
    if (!r.ok || String(out.status || "success").toLowerCase() !== "success") return { ok: false, error: "sms " + r.status + ": " + JSON.stringify(out).slice(0, 200) };
    return { ok: true };
  } catch (e) { return { ok: false, error: "sms: " + (e as Error).message }; }
}

// One message, tried on each channel in turn. wa: [template, body params, button param]
async function deliver(kind: string, to: string, wa: [string, string[], string?], text: string, kitchen: string | null = null, skip: string[] = []) {
  const list = await channels(skip), errors: string[] = [];
  for (const c of list) {
    const r = c === "whatsapp" ? await waTemplate(to, wa[0], wa[1], wa[2]) : await sms(to, text);
    await log(kind, to, c, r.ok ? "sent" : "failed", r.error || "", r.ref || null, kitchen);
    if (r.ok) return { ok: true, channel: c };
    errors.push(r.error || c);
  }
  return { ok: false, channel: null, error: list.length ? errors.join(" | ") : "no channel is switched on" };
}
const codeMsg = (to: string, code: string, kind: string) =>
  deliver(kind, to, [env("WA_TEMPLATE_CODE", "login_code"), [code], code], `Your ChopPool code is ${code}. Don't share it with anyone.`);

// ---------- vendor invite ----------
async function sendInvite(kitchenId: string, skip: string[] = []) {
  const { data: k } = await db.from("kitchens").select("id, public_name, phone, site_id, invite_status").eq("id", kitchenId).single();
  if (!k || !k.phone) return { status: "team", error: "no vendor" };
  const [{ data: site }, { data: a }] = await Promise.all([
    db.from("sites").select("name").eq("id", k.site_id).maybeSingle(),
    db.from("vendor_auth").select("invite_code").eq("kitchen_id", k.id).maybeSingle()]);
  const code = a?.invite_code, siteName = site?.name || "a ChopPool building";
  if (!code) return { status: "team", error: "no setup code" };
  const text = `Hello ${k.public_name}, a customer at ${siteName} invited your kitchen to ChopPool so their building can order lunch from you together. Set up your menu for free: ${APP}/?v=${code}`;
  const r = await deliver("vendor_invite", k.phone, [env("WA_TEMPLATE_INVITE", "vendor_invite"), [k.public_name, siteName], code], text, k.id, skip);
  await db.from("kitchens").update(r.ok
    ? { invite_status: "sent", invite_channel: r.channel, invite_sent_at: new Date().toISOString(), invite_error: null }
    : { invite_status: "team", invite_channel: "team", invite_error: (r.error || "").slice(0, 300) }).eq("id", k.id).in("invite_status", ["pending", "sent", "team"]);
  return r.ok ? { status: "sent", channel: r.channel } : { status: "team" };
}

// ---------- callers ----------
async function caller(req: Request) {
  const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const { data } = await db.auth.getUser(jwt);
  return data?.user || null;
}
async function isTeam(user: { email?: string } | null) {
  if (!user?.email) return false;
  const { data } = await db.from("admins").select("email").eq("email", user.email.toLowerCase()).maybeSingle();
  return !!data;
}

// Standard Webhooks signature, as Supabase Auth hooks use: base64(HMAC-SHA256(secret, id.timestamp.body))
async function signedBySupabase(req: Request, body: string) {
  const secret = env("SEND_SMS_HOOK_SECRET").replace(/^v1,/, "").replace(/^whsec_/, "");
  const id = req.headers.get("webhook-id") || "", ts = req.headers.get("webhook-timestamp") || "", sigs = req.headers.get("webhook-signature") || "";
  if (!secret || !id || !ts || !sigs) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;   // older than 5 minutes: refuse (replays)
  const key = await crypto.subtle.importKey("raw", b64ToBytes(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = bytesToB64(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(id + "." + ts + "." + body))));
  return sigs.split(" ").some(s => same(s.replace(/^v1,/, ""), mac));
}
async function signedByMeta(req: Request, body: string) {
  const secret = env("WHATSAPP_APP_SECRET"), sig = (req.headers.get("x-hub-signature-256") || "").replace(/^sha256=/, "");
  if (!secret || !sig) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return same(hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))), sig);
}

// WhatsApp replies and delivery receipts
async function fromMeta(p: any) {
  for (const entry of p?.entry || []) for (const ch of entry?.changes || []) {
    const v = ch?.value || {};
    for (const st of v.statuses || []) {
      const status = String(st.status || "");
      if (!["delivered", "read", "failed"].includes(status)) continue;
      const { data: row } = await db.from("msg_log").select("id, kind, kitchen_id").eq("ref", st.id).maybeSingle();
      if (!row) continue;
      await db.from("msg_log").update({ status, detail: status === "failed" ? JSON.stringify(st.errors || []).slice(0, 300) : null }).eq("id", row.id);
      // An invite WhatsApp couldn't deliver: try SMS, else it goes to the team
      if (status === "failed" && row.kind === "vendor_invite" && row.kitchen_id) await sendInvite(row.kitchen_id, ["whatsapp"]);
    }
    for (const m of v.messages || []) {
      const from = String(m.from || "");
      await log("inbound", from, "whatsapp", "received", m.type === "text" ? String(m.text?.body || "") : "[" + m.type + "]");
      const since = new Date(Date.now() - 12 * 36e5).toISOString();
      const { count } = await db.from("msg_log").select("id", { count: "exact", head: true }).eq("kind", "auto_reply").eq("phone", from).gte("created_at", since);
      if (count) continue;   // one auto-reply per person every 12 hours
      const s = await settings();
      const body = s.msg_reply || "Hi! This number only sends ChopPool codes and alerts, so nobody reads replies here. For help, email support@choppool.com or chat with us in the ChopPool app.";
      const r = await whatsapp({ to: from, type: "text", text: { body } });
      await log("auto_reply", from, "whatsapp", r.ok ? "sent" : "failed", r.error || "", r.ref || null);
    }
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  // Meta checks the webhook once when you save it
  if (req.method === "GET") {
    const vt = env("WHATSAPP_VERIFY_TOKEN");
    if (url.searchParams.get("hub.mode") === "subscribe" && vt && same(url.searchParams.get("hub.verify_token") || "", vt)) return new Response(url.searchParams.get("hub.challenge") || "", { status: 200 });
    return new Response("Forbidden", { status: 403 });
  }
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  const body = await req.text();

  // 1. Supabase Auth: a customer's phone sign-in code
  if (req.headers.get("webhook-id")) {
    if (!(await signedBySupabase(req, body))) return hookFail(401, "Not signed by Supabase");
    let p: any; try { p = JSON.parse(body); } catch (_) { return hookFail(400, "Bad request"); }
    const phone = ghPhone(p?.user?.phone), otp = String(p?.sms?.otp || "");
    if (!phone) return hookFail(400, "ChopPool sends codes to Ghana numbers only.");   // also stops foreign numbers running up the bill
    if (!/^\d{4,10}$/.test(otp)) return hookFail(400, "No code to send");
    const r = await codeMsg(phone, otp, "login_code");
    if (!r.ok) return hookFail(r.error === "no channel is switched on" ? 503 : 502, r.error === "no channel is switched on" ? "Codes can't be sent right now. Try email instead." : "We couldn't send your code. Try again in a minute.");
    return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
  }

  // 2. Meta: replies and delivery receipts
  if (req.headers.get("x-hub-signature-256")) {
    if (!(await signedByMeta(req, body))) return new Response("Bad signature", { status: 401 });
    try { await fromMeta(JSON.parse(body)); } catch (e) { console.error("meta", (e as Error).message); }
    return new Response("ok", { status: 200 });
  }

  // 3. The app
  let p: any; try { p = JSON.parse(body || "{}"); } catch (_) { return json({ error: "Bad request" }, 400); }
  try {
    if (p.action === "invite") {   // the customer who invited her, once
      const user = await caller(req);
      if (!user) return json({ error: "Sign in to invite a vendor." }, 401);
      const { data: k } = await db.from("kitchens").select("id, added_by, invite_status").eq("id", String(p.kitchen || "")).maybeSingle();
      if (!k || k.added_by !== user.id) return json({ error: "Vendor not found." }, 404);
      if (k.invite_status !== "pending") return json({ status: k.invite_status });
      return json(await sendInvite(k.id));
    }
    if (p.action === "vendor_code") {   // Forgot PIN
      const phone = ghPhone(p.phone);
      if (!phone) return json({ error: "Enter your 10-digit phone number, like 024 123 4567." }, 400);
      const { data: k } = await db.from("kitchens").select("id, invite_status").eq("phone", phone).eq("archived", false).maybeSingle();
      if (!k || ["declined", "merged"].includes(k.invite_status || "")) return json({ ok: true });   // same answer either way
      const { data: a } = await db.from("vendor_auth").select("reset_last_at, reset_day, reset_count").eq("kitchen_id", k.id).maybeSingle();
      const today = new Date().toISOString().slice(0, 10), countToday = a?.reset_day === today ? a.reset_count : 0;
      if (a?.reset_last_at && Date.now() - Date.parse(a.reset_last_at) < 60e3) return json({ error: "We've just sent a code. Wait a minute before asking again." }, 429);
      if (countToday >= 5) return json({ error: "Too many codes today. Call ChopPool and we'll help you sign in." }, 429);
      const code = sixDigits();
      await db.from("vendor_auth").upsert({ kitchen_id: k.id, reset_hash: await sha256(code), reset_expires: new Date(Date.now() + 10 * 60e3).toISOString(), reset_tries: 0,
        reset_last_at: new Date().toISOString(), reset_day: today, reset_count: countToday + 1 }, { onConflict: "kitchen_id" });
      const r = await codeMsg(phone, code, "vendor_code");
      if (!r.ok) return json({ error: "We couldn't send a code right now. Call ChopPool and we'll help you sign in." }, 503);
      return json({ ok: true, channel: r.channel });
    }
    if (p.action === "status" || p.action === "test") {   // team only
      if (!(await isTeam(await caller(req)))) return json({ error: "Only the ChopPool team can do this." }, 403);
      if (p.action === "status") return json({ whatsapp: !!env("WHATSAPP_TOKEN"), sms: !!env("ARKESEL_API_KEY"), webhook: !!env("WHATSAPP_APP_SECRET") && !!env("WHATSAPP_VERIFY_TOKEN"), channels: await channels() });
      const phone = ghPhone(p.phone);
      if (!phone) return json({ error: "Enter a 10-digit Ghana number." }, 400);
      const code = sixDigits();
      if (p.channel === "whatsapp" || p.channel === "sms") {
        if (!(await channels()).includes(p.channel)) return json({ error: (p.channel === "sms" ? "SMS" : "WhatsApp") + " isn't switched on or set up yet." }, 400);
        const r = p.channel === "whatsapp" ? await waTemplate(phone, env("WA_TEMPLATE_CODE", "login_code"), [code], code) : await sms(phone, `ChopPool test: your code is ${code}.`);
        await log("test", phone, p.channel, r.ok ? "sent" : "failed", r.error || "", r.ref || null);
        return json(r.ok ? { ok: true, channel: p.channel } : { error: r.error }, r.ok ? 200 : 502);
      }
      const r = await codeMsg(phone, code, "test");
      return json(r.ok ? { ok: true, channel: r.channel } : { error: r.error }, r.ok ? 200 : 502);
    }
    return json({ error: "Unknown request" }, 400);
  } catch (e) {
    console.error("sms", (e as Error).message);
    return json({ error: "Something went wrong. Try again in a minute." }, 500);
  }
});
