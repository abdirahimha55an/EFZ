// A stand-in for @/lib/supabase/db: the ONLY thing replaced when the real ConvertRequestDialog is rendered. No network, no Supabase.
export const stub = {
  products: [], customers: [], matches: [],
  /** key "customerId|productId|designName" -> answer; a missing key answers with the product's list price */
  answers: new Map(),
  failLookups: false, malformedLookups: false,
  lookups: [], converted: [], convertError: null,
  reset() { this.products = []; this.customers = []; this.matches = []; this.answers = new Map(); this.failLookups = false; this.malformedLookups = false; this.lookups = []; this.converted = []; this.convertError = null; },
};
export function getDb() {
  return {
    products: { list: async () => stub.products },
    customers: { list: async () => stub.customers },
    orderRequests: {
      findCustomers: async () => stub.matches,
      convert: async (id, input) => { if (stub.convertError) throw stub.convertError; stub.converted.push({ id, input }); return "ORD-STUB-1"; },
    },
    orders: {
      resolvePrice: async (customerId, productId, designName) => {
        stub.lookups.push(`${customerId}|${productId}|${designName ?? ""}`);
        if (stub.failLookups) return null;                      // exactly what the real resolvePrice returns when the RPC errors
        if (stub.malformedLookups) return { source: "agreement", price: "ten" };
        const k = `${customerId}|${productId}|${designName ?? ""}`;
        if (stub.answers.has(k)) return stub.answers.get(k);
        const p = stub.products.find((x) => x.id === productId);
        return { source: "list", price: p.sellingPrice, listPrice: p.sellingPrice, reason: null };
      },
    },
  };
}
export const describeDbError = (e) => String(e?.message ?? e);
export class EfzDbError extends Error {}
