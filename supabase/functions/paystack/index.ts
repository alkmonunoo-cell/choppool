// ChopPool online payments (Paystack: mobile money and card).
//
// The app calls this with the customer's sign-in:
//   { action: "start", order_id }   -> starts a Paystack payment for what the order still owes (worked out by the database)
//   { action: "check", reference }  -> asks Paystack whether that payment went through, and marks the order paid if it did
// Paystack calls it too (webhook, signed with the secret key) so a payment counts even if the customer closes the app.
//
// Secrets: PAYSTACK_SECRET_KEY (test or live). Deploy with "Verify JWT" OFF: Paystack's webhook has no Supabase sign-in;
// app calls are checked here with the customer's own token, and webhooks by Paystack's signature.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = () => Deno.env.get("PAYSTACK_SECRET_KEY") || "";
const API = "https://api.paystack.co";

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });
const toPesewas = (ghs: number) => Math.round(Number(ghs) * 100);

async function paystack(path: string, init: RequestInit = {}) {
  const r = await fetch(API + path, { ...init, headers: { Authorization: "Bearer " + KEY(), "Content-Type": "application/json", ...(init.headers || {}) } });
  const body = await r.json().catch(() => ({}));
  if (!r.ok || body.status === false) throw new Error(body.message || "Paystack didn't answer. Try again.");
  return body.data;
}

async function hmacHex(secret: string, text: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(text)));
  return [...sig].map(b => b.toString(16).padStart(2, "0")).join("");
}
function same(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Ask Paystack about a payment, then let the database decide (paid, or kept in the wallet). Safe to run many times.
async function confirm(reference: string) {
  const { data: rec } = await db.from("paystack_payments").select("reference, status, order_id").eq("reference", reference).maybeSingle();
  if (!rec) return { result: "unknown" };
  if (rec.status !== "started") return { result: rec.status, order_id: rec.order_id };
  const tx = await paystack("/transaction/verify/" + encodeURIComponent(reference));
  if (tx.status !== "success" || tx.currency !== "GHS") return { result: tx.status || "pending", order_id: rec.order_id };
  const { data, error } = await db.rpc("paystack_settle", { p_ref: reference, p_amount: Number(tx.amount) / 100, p_channel: String(tx.channel || "") });
  if (error) throw new Error(error.message);
  return data;
}

async function start(userId: string, email: string, orderId: string) {
  const { data: chk, error } = await db.rpc("paystack_check_order", { p_order: orderId, p_user: userId });
  if (error) throw new Error(error.message);
  if (chk.error) return json({ error: chk.error }, 400);
  // Reuse a payment started in the last 20 minutes for the same amount (tapping Pay twice shouldn't charge twice)
  const { data: open } = await db.from("paystack_payments").select("reference, amount, created_at").eq("order_id", orderId).eq("status", "started")
    .gte("created_at", new Date(Date.now() - 20 * 60e3).toISOString()).order("created_at", { ascending: false }).limit(1);
  if (open && open[0] && Number(open[0].amount) === Number(chk.amount)) {
    const done = await confirm(open[0].reference).catch(() => null);
    if (done && done.result === "paid") return json({ paid: true, reference: open[0].reference });
  }
  const reference = "CP" + String(chk.code).replace(/[^A-Za-z0-9]/g, "") + "-" + crypto.randomUUID().replace(/-/g, "").slice(0, 10);
  const ins = await db.from("paystack_payments").insert({ reference, order_id: orderId, user_id: userId, amount: chk.amount });
  if (ins.error) throw new Error(ins.error.message);
  const tx = await paystack("/transaction/initialize", { method: "POST", body: JSON.stringify({
    email, amount: toPesewas(chk.amount), currency: "GHS", reference, channels: ["mobile_money", "card"],
    metadata: { order_id: orderId, code: chk.code, order_date: chk.order_date, custom_fields: [{ display_name: "Order code", variable_name: "code", value: String(chk.code) }] },
  }) });
  return json({ access_code: tx.access_code, reference, amount: chk.amount });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  if (!KEY()) return json({ error: "Online payment isn't set up yet." }, 503);
  const raw = await req.text();

  // Paystack's webhook: trust it only with a valid signature
  const sig = req.headers.get("x-paystack-signature");
  if (sig) {
    if (!same(await hmacHex(KEY(), raw), sig.toLowerCase())) return new Response("Bad signature", { status: 401 });
    try {
      const ev = JSON.parse(raw);
      if (ev.event === "charge.success" && ev.data?.reference) await confirm(String(ev.data.reference));
    } catch (e) { console.error("webhook", (e as Error).message); return new Response("Try again", { status: 500 }); }
    return new Response("ok", { status: 200 });
  }

  // The app: the customer's own sign-in
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: who } = await db.auth.getUser(token);
  const user = who?.user;
  if (!user) return json({ error: "Sign in again to pay." }, 401);
  let body: any = {};
  try { body = JSON.parse(raw || "{}"); } catch (_) { return json({ error: "Bad request" }, 400); }
  try {
    if (body.action === "start" && body.order_id) {
      return await start(user.id, user.email || ("customer-" + user.id.slice(0, 8) + "@choppool.com"), String(body.order_id));
    }
    if (body.action === "check" && body.reference) {
      const { data: rec } = await db.from("paystack_payments").select("user_id").eq("reference", String(body.reference)).maybeSingle();
      if (!rec || rec.user_id !== user.id) return json({ error: "Payment not found." }, 404);
      return json(await confirm(String(body.reference)));
    }
    return json({ error: "Unknown request" }, 400);
  } catch (e) {
    console.error("pay", (e as Error).message);
    return json({ error: (e as Error).message || "Payment didn't start. Try again." }, 500);
  }
});
