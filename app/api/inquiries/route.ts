import { createClient } from "@supabase/supabase-js";
import type { Database, Json } from "@/lib/supabase/database.types";
import { getSupabasePublicEnv } from "@/lib/supabase/env";
import { handleInquiry, UNAVAILABLE } from "@/lib/inquiryRoute";

/**
 * Public Contact/Wholesale submissions. Signs the visitor's real network address so the database can rate-limit per
 * network (see lib/inquirySignature.ts). Uses only the public anon key: no service-role key is involved.
 * Called by the Contact and Wholesale forms (lib/inquirySubmit.ts). Works with migration 30; migration 31 will start using the signature.
 */
export async function POST(request: Request) {
  const { url, key } = getSupabasePublicEnv();
  if (!url || !key) return Response.json({ message: UNAVAILABLE, code: "WR503" }, { status: 503 });
  const supabase = createClient<Database>(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { status, body } = await handleInquiry(await request.text(), request.headers, {
    secret: process.env.INQUIRY_HMAC_SECRET,
    rpc: async (payload) => {
      const { data, error } = await supabase.rpc("submit_public_inquiry", { p_payload: payload as unknown as Json });
      return { data, error };
    },
  });
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}
