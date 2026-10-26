// Stands in for @/lib/supabase/db during the DOM test: the test decides what submit() does.
export const getDb = () => ({ inquiries: { submit: (input) => globalThis.__submit(input) } });
export const describeDbError = (e) => (e instanceof Error ? e.message : "Something went wrong.");
