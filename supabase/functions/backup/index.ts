// ChopPool weekly backup. A Google Apps Script in the owner's Google account calls this once a week
// and saves the result to Google Drive. It returns every table in the database as JSON, plus the list of
// accounts (id, email, phone, dates; never passwords). Photos in storage are not included.
//
// Protected by its own key: the BACKUP_KEY secret in Supabase must match the key the script sends.
// Deploy with "Verify JWT" switched OFF (the script has no Supabase sign-in); the key check below guards it.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

// Every table at version 41. Any table added later is picked up automatically from the database's own list.
const TABLES = ["activity_log", "admins", "feedback", "kitchen_days", "kitchens", "menu_items", "notifications", "orders",
  "payment_methods", "payouts", "pools", "price_requests", "profiles", "push_log", "push_subs", "reviews", "riders", "settings",
  "site_waiters", "sites", "tester_acceptances", "unmatched_payments", "wallet_entries"];
// Read-only views (worked out from the tables above), so they are not copied twice
const VIEWS = new Set(["dish_popularity", "kitchen_load", "kitchen_scores", "public_menus", "public_pools", "public_reviews",
  "public_sites", "recent_activity", "site_kitchen_counts"]);
const PAGE = 1000;

function same(a: string, b: string) {   // compare keys without leaking timing
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function tableNames(): Promise<string[]> {
  const names = new Set(TABLES);
  try {   // the database's own list, so a new table is never missed
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const r = await fetch(Deno.env.get("SUPABASE_URL") + "/rest/v1/", { headers: { apikey: key, Authorization: "Bearer " + key } });
    if (r.ok) { const spec = await r.json(); Object.keys(spec.definitions || {}).forEach(n => { if (!VIEWS.has(n)) names.add(n); }); }
  } catch (_) { /* fall back to the list above */ }
  return [...names].sort();
}

async function readAll(table: string) {
  const rows: unknown[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await db.from(table).select("*").range(from, from + PAGE - 1);
    if (error) throw new Error(table + ": " + error.message);
    rows.push(...(data || []));
    if (!data || data.length < PAGE) break;
  }
  return rows;
}

async function accounts() {
  const out: unknown[] = [];
  for (let page = 1; ; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new Error("accounts: " + error.message);
    const us = data?.users || [];
    us.forEach((u: any) => out.push({ id: u.id, email: u.email ?? null, phone: u.phone ?? null, created_at: u.created_at,
      last_sign_in_at: u.last_sign_in_at ?? null, email_confirmed_at: u.email_confirmed_at ?? null }));
    if (us.length < 1000) break;
  }
  return out;
}

export async function makeBackup() {
  const tables: Record<string, unknown[]> = {}, counts: Record<string, number> = {}, problems: string[] = [];
  for (const t of await tableNames()) {
    try { tables[t] = await readAll(t); counts[t] = tables[t].length; }
    catch (e) { problems.push(String((e as Error).message || e)); }
  }
  let users: unknown[] = [];
  try { users = await accounts(); } catch (e) { problems.push(String((e as Error).message || e)); }
  return { app: "ChopPool", kind: "weekly backup", made_at: new Date().toISOString(), counts, accounts: users.length, problems, auth_users: users, tables };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  const want = Deno.env.get("BACKUP_KEY") || "";
  if (want.length < 24 || !same(req.headers.get("x-backup-key") || "", want)) return new Response("Not allowed", { status: 401 });
  try {
    const b = await makeBackup();
    return new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message || e) }), { status: 500, headers: { "content-type": "application/json" } });
  }
});
