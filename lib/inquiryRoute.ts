/**
 * The request logic behind POST /api/inquiries, kept free of Next and Supabase imports so it can be unit-tested.
 * The route file supplies the real `rpc`; tests supply a stub.
 */
import { clientProof, normalizedSubmissionKey, trustedClientIp } from "./inquirySignature";

export const MAX_BODY_BYTES = 16 * 1024;

export type RpcResult = { data: unknown; error: { message?: string; code?: string } | null };
export type InquiryRouteDeps = {
  rpc: (payload: Record<string, unknown>) => Promise<RpcResult>;
  secret: string | undefined;
  nowMs?: number;
};

export const UNAVAILABLE = "This form is temporarily unavailable. Please try again shortly or contact us on WhatsApp.";

const json = (body: unknown, status: number) => ({ status, body });

export async function handleInquiry(rawBody: string, headers: Pick<Headers, "get">, deps: InquiryRouteDeps) {
  if (rawBody.length > MAX_BODY_BYTES) return json({ message: "Request too large", code: "WR413" }, 413);
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return json({ message: "Invalid request", code: "WR400" }, 400);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return json({ message: "Invalid request", code: "WR400" }, 400);

  // Never trust proof fields sent by the browser: drop them, then add our own.
  const payload = { ...(parsed as Record<string, unknown>) };
  delete payload._ip;
  delete payload._ts;
  delete payload._sig;
  // Sign and forward the key in canonical (lower-case uuid) form so the database computes the same signature.
  const key = normalizedSubmissionKey(payload.submissionKey);
  if (key) payload.submissionKey = key;
  const proof = clientProof({ secret: deps.secret, ip: trustedClientIp(headers), submissionKey: key, nowMs: deps.nowMs });

  const { data, error } = await deps.rpc(proof ? { ...payload, ...proof } : payload);
  // An error with no code never came from the database function (the database was unreachable): do not echo its text.
  if (error && !error.code) return json({ message: UNAVAILABLE, code: "WR502" }, 502);
  if (error) return json({ message: error.message ?? "Request failed", code: error.code ?? null }, error.code === "WR429" ? 429 : 400);
  return json({ id: data }, 200);
}
