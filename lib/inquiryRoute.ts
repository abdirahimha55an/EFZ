/**
 * The request logic behind POST /api/inquiries, kept free of Next and Supabase imports so it can be unit-tested.
 * The route file supplies the real `rpc`; tests supply a stub.
 */
import { clientProof, trustedClientIp } from "./inquirySignature";

export const MAX_BODY_BYTES = 16 * 1024;

export type RpcResult = { data: unknown; error: { message?: string; code?: string } | null };
export type InquiryRouteDeps = {
  rpc: (payload: Record<string, unknown>) => Promise<RpcResult>;
  secret: string | undefined;
  nowMs?: number;
};

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
  const key = typeof payload.submissionKey === "string" ? payload.submissionKey : null;
  const proof = clientProof({ secret: deps.secret, ip: trustedClientIp(headers), submissionKey: key, nowMs: deps.nowMs });

  const { data, error } = await deps.rpc(proof ? { ...payload, ...proof } : payload);
  if (error) return json({ message: error.message ?? "Request failed", code: error.code ?? null }, 400);
  return json({ id: data }, 200);
}
