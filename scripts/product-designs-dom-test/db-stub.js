// Stands in for @/lib/supabase/db during the Product Designs DOM test. The in-memory store applies the same rules as the database
// (guard_product_design(): trimmed names, https-only picture link, unique name per product, a design never moves to another product).
const world = () => globalThis.__world;
const refuse = (message, code) => Object.assign(new Error(message), { code });
const now = () => "2026-11-05T12:00:00.000Z";

export const getDb = () => ({
  auth: { getProfile: async () => world().me },
  products: { list: async () => world().products },
  designs: {
    list: async () => world().designs.map((d) => ({ ...d })),
    create: async (i) => {
      const w = world(); w.calls.push(["create", i]);
      if (!w.canWrite) throw refuse("Permission denied: new row violates row-level security policy for table \"product_designs\"", "42501");
      const name = i.name.trim();
      if (name === "") throw refuse("new row violates check constraint", "23514");
      if (i.imageUrl && !/^https:\/\/\S+$/.test(i.imageUrl.trim())) throw refuse("The image link must start with https:// and be at most 500 characters", "22023");
      if (w.designs.some((d) => d.productId === i.productId && d.name.toLowerCase() === name.toLowerCase())) throw refuse("duplicate key value violates unique constraint \"product_designs_name_key\"", "23505");
      const d = { id: "d" + (w.designs.length + 1), productId: i.productId, name, imageUrl: (i.imageUrl ?? "").trim(), sortOrder: i.sortOrder ?? 0, isActive: i.isActive ?? true, createdAt: now(), updatedAt: now() };
      w.designs.push(d); return d;
    },
    update: async (id, patch) => {
      const w = world(); w.calls.push(["update", id, patch]);
      if (!w.canWrite) throw refuse("Permission denied: you may not change designs, or the design no longer exists", "42501");
      const d = w.designs.find((x) => x.id === id);
      if (patch.name !== undefined) {
        const name = patch.name.trim();
        if (w.designs.some((x) => x.id !== id && x.productId === d.productId && x.name.toLowerCase() === name.toLowerCase())) throw refuse("duplicate key value violates unique constraint \"product_designs_name_key\"", "23505");
        d.name = name;
      }
      if (patch.imageUrl !== undefined) d.imageUrl = patch.imageUrl.trim();
      if (patch.sortOrder !== undefined) d.sortOrder = patch.sortOrder;
      d.updatedAt = now(); return { ...d };
    },
    setActive: async (id, isActive) => {
      const w = world(); w.calls.push(["setActive", id, isActive]);
      if (!w.canWrite) throw refuse("Permission denied: you may not change designs, or the design no longer exists", "42501");
      const d = w.designs.find((x) => x.id === id); d.isActive = isActive; d.updatedAt = now(); return { ...d };
    },
  },
});
export const describeDbError = (e) => (e instanceof Error ? e.message : "Something went wrong.");
