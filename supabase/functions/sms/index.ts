// ChopPool sign-in codes by SMS (Arkesel). Supabase Auth calls this through its "Send SMS" hook whenever a phone
// code is needed (new account, forgot PIN). It sends the code from the approved sender name "ChopPool".
//
// Secrets: ARKESEL_API_KEY (from Arkesel), SEND_SMS_HOOK_SECRET (shown by Supabase when you create the hook,
// starts with v1,whsec_). Optional: SMS_SENDER (default ChopPool). Deploy with "Verify JWT" OFF: Supabase signs
// every hook call and this function checks that signature.
const SENDER = () => Deno.env.get("SMS_SENDER") || "ChopPool";

const fail = (status: number, message: string) =>
  new Response(JSON.stringify({ error: { http_code: status, message } }), { status, headers: { "content-type": "application/json" } });

function b64ToBytes(b64: string) { const s = atob(b64); return Uint8Array.from(s, c => c.charCodeAt(0)); }
function bytesToB64(b: Uint8Array) { let s = ""; b.forEach(x => { s += String.fromCharCode(x); }); return btoa(s); }
function same(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Standard Webhooks signature, as Supabase Auth hooks use: base64(HMAC-SHA256(secret, id.timestamp.body))
async function signedBySupabase(req: Request, body: string) {
  const secret = (Deno.env.get("SEND_SMS_HOOK_SECRET") || "").replace(/^v1,/, "").replace(/^whsec_/, "");
  const id = req.headers.get("webhook-id") || "", ts = req.headers.get("webhook-timestamp") || "", sigs = req.headers.get("webhook-signature") || "";
  if (!secret || !id || !ts || !sigs) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;   // older than 5 minutes: refuse (replays)
  const key = await crypto.subtle.importKey("raw", b64ToBytes(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = bytesToB64(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(id + "." + ts + "." + body))));
  return sigs.split(" ").some(s => same(s.replace(/^v1,/, ""), mac));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return fail(405, "Use POST");
  const body = await req.text();
  if (!(await signedBySupabase(req, body))) return fail(401, "Not signed by Supabase");
  let p: any; try { p = JSON.parse(body); } catch (_) { return fail(400, "Bad request"); }
  const phone = String(p?.user?.phone || "").replace(/\D/g, ""), otp = String(p?.sms?.otp || "");
  // Ghana numbers only: stops anyone running up the SMS bill with foreign numbers
  if (!/^233\d{9}$/.test(phone)) return fail(400, "ChopPool sends codes to Ghana numbers only.");
  if (!/^\d{4,10}$/.test(otp)) return fail(400, "No code to send");
  const key = Deno.env.get("ARKESEL_API_KEY");
  if (!key) return fail(503, "SMS isn't set up yet.");
  try {
    const r = await fetch("https://sms.arkesel.com/api/v2/sms/send", {
      method: "POST",
      headers: { "api-key": key, "Content-Type": "application/json" },
      body: JSON.stringify({ sender: SENDER(), recipients: [phone], message: `Your ChopPool code is ${otp}. Don't share it with anyone.` }),
    });
    const out = await r.json().catch(() => ({}));
    if (!r.ok || String(out.status || "success").toLowerCase() !== "success") {
      console.error("arkesel", r.status, JSON.stringify(out).slice(0, 300));
      return fail(502, "We couldn't send the SMS. Try again in a minute.");
    }
    return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
  } catch (e) {
    console.error("arkesel", (e as Error).message);
    return fail(502, "We couldn't send the SMS. Try again in a minute.");
  }
});
