// ChopPool push alerts. The app calls this after something happens (an order, a seller confirming,
// a status change). It reads the real state from the database, decides who should hear about it,
// sends each alert once (push_log), and removes phones that have switched alerts off.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:hello@choppool.app", Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);
const APP = (Deno.env.get("APP_URL") || "https://alkmonunoo-cell.github.io/choppool").replace(/\/$/, "");
const money = (n: number) => "GHS " + Number(n).toFixed(2);

async function once(key: string) {   // true the first time a key is seen
  const { data } = await db.from("push_log").upsert({ key }, { onConflict: "key", ignoreDuplicates: true }).select("key");
  return !!(data && data.length);
}
async function send(subs: any[], title: string, body: string, url: string, tag: string) {
  const seen = new Set<string>();
  for (const s of subs || []) {
    if (seen.has(s.endpoint)) continue; seen.add(s.endpoint);
    try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ title, body, url, tag })); }
    catch (e: any) { if (e && (e.statusCode === 404 || e.statusCode === 410)) await db.from("push_subs").delete().eq("endpoint", s.endpoint); }
  }
}
async function customerSubs(orders: any[]) {
  const users = [...new Set(orders.map((o) => o.user_id).filter(Boolean))], ids = orders.map((o) => o.id);
  const out: any[] = [];
  if (users.length) { const { data } = await db.from("push_subs").select("*").in("user_id", users); out.push(...(data || [])); }
  if (ids.length) { const { data } = await db.from("push_subs").select("*").overlaps("order_ids", ids); out.push(...(data || [])); }
  return out;
}
const kitchenSubs = async (kid: string) => (await db.from("push_subs").select("*").eq("kitchen_id", kid)).data || [];
const riderSubs = async (rid: string) => (await db.from("push_subs").select("*").eq("rider_id", rid)).data || [];

async function poolEvents(poolId: string, opened = false) {
  const { data: p } = await db.from("pools").select("*").eq("id", poolId).single(); if (!p) return;
  const [{ data: k }, { data: site }, { data: s }, { data: orders }] = await Promise.all([
    db.from("kitchens").select("*").eq("id", p.kitchen_id).single(), db.from("sites").select("*").eq("id", p.site_id).single(),
    db.from("settings").select("*").eq("id", 1).single(), db.from("orders").select("*").eq("pool_id", p.id).neq("status", "cancelled")]);
  const live = (orders || []).filter((o: any) => !["quote_requested", "quoted"].includes(o.status)), meals = live.reduce((t: number, o: any) => t + o.qty, 0);
  const cust = () => customerSubs(live), url = APP + "/#order";
  if (p.status === "waiting" && await once("new_pool:" + p.id))
    await send(await kitchenSubs(k.id), "New pool at " + site.name, "Customers want to order from you. Confirm you're cooking within " + s.accept_timeout_min + " minutes.", APP + "/#kitchen-" + k.token, "pool-" + p.id);
  if (opened && p.status === "collecting" && meals && await once("pool_open:" + p.id))
    await send(await cust(), k.public_name + " is cooking", "Your pool at " + site.name + " is open. Share it so delivery gets cheaper.", url, "pool-" + p.id);
  if (p.status === "collecting" && meals === s.max_meals - 1 && await once("seat1:" + p.id))
    await send(await cust(), "1 seat left", "Your pool at " + site.name + " is almost full. Delivery is at its lowest.", url, "pool-" + p.id);
  if (p.status === "arriving" && await once("arriving:" + p.id))
    await send(await cust(), "Lunch is 5 minutes away", site.handoff === "host" ? "It's coming to " + site.drop_point + "." : "Meet the rider at " + site.drop_point + " with your code.", url, "pool-" + p.id);
  if (p.status === "delivered" && site.handoff === "host" && await once("delivered:" + p.id))
    await send(await cust(), "Lunch is here", "Collect it from " + (site.host_label || site.drop_point) + " with your code.", url, "pool-" + p.id);
  if (p.rider_id && !["delivered", "cancelled"].includes(p.status) && await once("rider:" + p.id + ":" + p.rider_id)) {
    const { data: r } = await db.from("riders").select("*").eq("id", p.rider_id).single();
    if (r) await send(await riderSubs(r.id), "New pickup", k.public_name + " → " + site.name + ", " + meals + " meals.", APP + "/#rider-" + r.token, "rider-" + p.id);
  }
}
async function orderEvents(orderId: string) {
  const { data: o } = await db.from("orders").select("*").eq("id", orderId).single(); if (!o) return;
  const { data: k } = await db.from("kitchens").select("*").eq("id", o.kitchen_id).single();
  if (o.status === "quote_requested" && await once("special:" + o.id))
    await send(await kitchenSubs(o.kitchen_id), "Special request to price", o.qty + " × " + o.item_name + ": " + o.special_request, APP + "/#kitchen-" + k.token, "special-" + o.id);
  if (o.status === "quoted" && await once("quoted:" + o.id + ":" + o.quote_price))
    await send(await customerSubs([o]), "Your request is priced", k.public_name + " priced it at " + money(o.quote_price) + " a meal. Pay to confirm.", APP + "/#order", "order-" + o.id);
  if (o.status === "cancelled" && /^The seller can't/.test(o.cancel_reason || "") && await once("declined:" + o.id))
    await send(await customerSubs([o]), k.public_name + " can't do your request", (o.cancel_reason || "") + ". Nothing was charged.", APP + "/#order", "order-" + o.id);
  await poolEvents(o.pool_id);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const b = await req.json().catch(() => ({}));
    if (b.order_id) await orderEvents(String(b.order_id));
    if (b.pool_id) await poolEvents(String(b.pool_id));
    if (b.kitchen_token && b.date) {   // a seller just confirmed: tell every pool that opened
      const { data: k } = await db.from("kitchens").select("id").eq("token", String(b.kitchen_token)).single();
      if (k) { const { data: ps } = await db.from("pools").select("id").eq("kitchen_id", k.id).eq("order_date", String(b.date)); for (const p of ps || []) await poolEvents(p.id, true); }
    }
    return new Response(JSON.stringify({ ok: true }), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: String(e) }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
