// Stands in for @/lib/supabase/db during the order-form DOM test: the test decides the catalog, the designs and what submit() does.
export const getDb = () => ({
  products: {
    listPublic: () => Promise.resolve(globalThis.__products),
    listPublicDesigns: () => Promise.resolve(globalThis.__designs),
  },
  orderRequests: { submit: (input) => globalThis.__submit(input) },
});
export const describeDbError = (e) => (e instanceof Error ? e.message : "Something went wrong.");
