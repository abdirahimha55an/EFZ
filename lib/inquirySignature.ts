/**
 * Server-only. Proves to the database which network a public inquiry really came from.
 *
 * The browser used to call submit_public_inquiry() directly, so the only address the database saw was the
 * first x-forwarded-for hop, which a caller can set to anything. The /api/inquiries route instead reads the
 * address Vercel itself sets, then signs `ip|timestamp|submissionKey` with a secret that only the server and the
 * database know. The database (migration 31, still a draft) recomputes the signature and, if it matches, trusts
 * the address for per-network limits; a missing or wrong signature goes to a small separate bucket.
 */
import { createHmac, timingSafeEqual } from "node:crypto";
import { isIP } from "node:net";

/** A signature older than this is rejected, which also bounds replay of a captured request. */
export const SIGNATURE_MAX_AGE_SECONDS = 300;

/**
 * The visitor's address as set by the hosting platform. Vercel overwrites these headers, so a caller cannot forge them
 * there; plain x-forwarded-for is deliberately not used because a caller can prepend to it anywhere.
 */
export function trustedClientIp(headers: Pick<Headers, "get">): string | null {
  for (const name of ["x-vercel-forwarded-for", "x-real-ip"]) {
    const first = (headers.get(name) ?? "").split(",")[0]?.trim() ?? "";
    if (first && isIP(first) !== 0) return first.toLowerCase();
  }
  return null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The submission key in the exact text the database will sign over (it casts the key to uuid), or null if it is not a uuid. */
export function normalizedSubmissionKey(key: unknown): string | null {
  return typeof key === "string" && UUID.test(key) ? key.toLowerCase() : null;
}

function mac(secret: string, ip: string, ts: number, submissionKey: string): string {
  return createHmac("sha256", secret).update(`${ip}|${ts}|${submissionKey}`).digest("hex");
}

export type ClientProof = { _ip: string; _ts: number; _sig: string };

/** The proof fields to merge into the RPC payload, or null when there is no secret, address or submission key to sign. */
export function clientProof(opts: { secret: string | undefined; ip: string | null; submissionKey: string | null | undefined; nowMs?: number }): ClientProof | null {
  const { secret, ip, submissionKey } = opts;
  if (!secret || secret.length < 32 || !ip || !submissionKey) return null;
  const ts = Math.floor((opts.nowMs ?? Date.now()) / 1000);
  return { _ip: ip, _ts: ts, _sig: mac(secret, ip, ts, submissionKey) };
}

/** The same check the database makes, kept here so the rule is unit-tested. */
export function verifyClientProof(proof: Partial<ClientProof>, submissionKey: string, secret: string, nowMs = Date.now()): boolean {
  if (typeof proof._ip !== "string" || typeof proof._sig !== "string" || typeof proof._ts !== "number") return false;
  const age = Math.floor(nowMs / 1000) - proof._ts;
  if (age < -30 || age > SIGNATURE_MAX_AGE_SECONDS) return false;
  const want = Buffer.from(mac(secret, proof._ip, proof._ts, submissionKey));
  const got = Buffer.from(proof._sig);
  return want.length === got.length && timingSafeEqual(want, got);
}
