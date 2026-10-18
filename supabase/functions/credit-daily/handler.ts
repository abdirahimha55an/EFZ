/**
 * Daily credit run trigger (migration 25). It is ONLY a trigger: all the logic (defaults, reminders, escalations, retries) is the database function
 * credit_daily_run(), which is idempotent. This function exists so any scheduler that can send an HTTPS request (Supabase Cron, an external cron, a
 * GitHub Action) can start it without holding a database credential.
 *
 *   POST  with header  x-cron-secret: <CREDIT_CRON_SECRET>
 *
 *  - no secret configured on the function  -> 501 (it refuses to run unprotected)
 *  - a missing or wrong secret             -> 401, nothing is called (compared in constant time)
 *  - anything but POST                     -> 405
 *  - otherwise the database function runs; its counts come back, nothing else (no customer data, no error detail)
 * Deploy with --no-verify-jwt (the shared secret is the credential) and set CREDIT_CRON_SECRET with `supabase secrets set`. Never put the secret in the repository.
 */
export type Json = Record<string, unknown>;
export type CreditDailyDeps = {
  secret: string | undefined;
  /** Calls credit_daily_run with the service role. */
  run: () => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
};
const json = (status: number, body: Json): Response => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder(); const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function handleCreditDaily(req: Request, deps: CreditDailyDeps): Promise<Response> {
  if (!deps.secret || deps.secret.length < 24) return json(501, { error: "Not configured" });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!safeEqual(given, deps.secret)) return json(401, { error: "Unauthorized" });
  const r = await deps.run();
  if (r.error) return json(500, { error: "The daily run failed" });
  const d = (r.data ?? {}) as { asOf?: string; remindersSent?: number; failed?: number };
  return json(200, { ok: true, asOf: d.asOf ?? null, remindersSent: d.remindersSent ?? 0, failed: d.failed ?? 0 });
}
