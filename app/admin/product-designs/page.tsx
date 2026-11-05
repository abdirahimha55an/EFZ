"use client";

/**
 * Product designs (migration 32): the ball designs a visitor can choose on the public order form.
 *
 *  - Create, rename, set the picture link and the display order, and switch a design on or off. Switching off hides it from the order form at once; requests and orders
 *    that already carry the design keep it. There is deliberately no delete button here: a design may be referenced by requests, orders and price agreements, so it is
 *    deactivated instead.
 *  - Who: staff with the edit_products privilege. The page hides itself from everyone else; the protection is the database (row-level rules on product_designs and the
 *    guard_product_design() trigger), which refuses any other caller whichever screen is used. Every change is recorded in the Audit Trail by the database.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, CheckCircle2, Loader2, Palette, Pencil, Power, Shield } from "lucide-react";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import {
  EMPTY_DRAFT, IMAGE_MAX, NAME_MAX, activeCount, filterDesigns, groupByProduct, validateDraft,
  type DesignDraft, type DesignErrors, type DesignFilter,
} from "@/lib/productDesigns";
import type { Product, ProductDesign } from "@/lib/types";

type Data = { designs: ProductDesign[]; products: Product[] };
type Loaded = { state: "ready"; data: Data } | { state: "denied" } | { state: "error"; message: string };

const input = "h-9 w-full rounded-lg border border-slate-200 bg-white px-2.5 text-sm focus:border-slate-400 focus:outline-none";
const btn = "inline-flex items-center gap-1.5 rounded-lg bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-40";
const btn2 = "inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-40";
const card = "rounded-xl border border-slate-200 bg-white p-4";
const err = "mt-1 text-xs font-medium text-red-600";

export default function ProductDesignsPage() {
  const [state, setState] = useState<"loading" | "ready" | "denied" | "error">("loading");
  const [loadMessage, setLoadMessage] = useState<string | null>(null);
  const [data, setData] = useState<Data | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [filter, setFilter] = useState<DesignFilter>({ productId: "", status: "all", search: "" });

  const [draft, setDraft] = useState<DesignDraft>(EMPTY_DRAFT);
  const [draftErrors, setDraftErrors] = useState<DesignErrors>({});
  const [editingId, setEditingId] = useState<string | null>(null);
  const [edit, setEdit] = useState<DesignDraft>(EMPTY_DRAFT);
  const [editErrors, setEditErrors] = useState<DesignErrors>({});

  const fetchAll = useCallback(async (): Promise<Loaded> => {
    try {
      const db = getDb();
      const me = await db.auth.getProfile();
      if (!derivePermissions(me).editProducts) return { state: "denied" };
      const [designs, products] = await Promise.all([db.designs.list(), db.products.list({ includeInactive: true })]);
      return { state: "ready", data: { designs, products } };
    } catch (e) { return { state: "error", message: describeDbError(e) }; }
  }, []);
  const apply = useCallback((r: Loaded) => { if (r.state === "ready") setData(r.data); if (r.state === "error") setLoadMessage(r.message); setState(r.state); }, []);
  useEffect(() => {
    let cancelled = false;
    (async () => { const r = await fetchAll(); if (!cancelled) apply(r); })();
    return () => { cancelled = true; };
  }, [fetchAll, apply]);

  /** Runs one database call, then reloads. When the database refuses, its own sentence is shown and nothing else changes. */
  const run = async (what: string, fn: () => Promise<void>): Promise<boolean> => {
    setBusy(true); setProblem(null); setDone(null);
    try { await fn(); setDone(what); apply(await fetchAll()); return true; }
    catch (e) { setProblem(describeDbError(e)); return false; }
    finally { setBusy(false); }
  };

  const products = useMemo(() => data?.products ?? [], [data]);
  const designs = useMemo(() => data?.designs ?? [], [data]);
  const nameOf = useCallback((id: string) => products.find((p) => p.id === id)?.name ?? id, [products]);
  const selectable = useMemo(() => products.filter((p) => p.isActive !== false), [products]);
  const groups = useMemo(() => groupByProduct(filterDesigns(designs, filter), products), [designs, filter, products]);

  if (state === "loading") return <div className="flex items-center gap-2 p-6 text-sm text-slate-500"><Loader2 className="h-4 w-4 animate-spin" /> Loading designs…</div>;
  if (state === "denied") return (
    <div className={`${card} m-4 max-w-xl`} data-testid="designs-denied">
      <Shield className="mb-2 h-6 w-6 text-slate-400" aria-hidden="true" />
      <h1 className="text-base font-bold text-slate-900">Product designs</h1>
      <p className="mt-1 text-sm text-slate-600">You need the &ldquo;edit products&rdquo; privilege to manage designs. Ask a Super Admin or Manager.</p>
    </div>
  );
  if (state === "error") return <div className="m-4 flex items-start gap-2 rounded-xl border border-red-100 bg-red-50 p-4 text-sm text-red-700" role="alert"><AlertCircle className="mt-0.5 h-4 w-4" /> {loadMessage}</div>;

  const create = async () => {
    const v = validateDraft(draft, designs);
    if (!v.ok) { setDraftErrors(v.errors); return; }
    setDraftErrors({});
    const ok = await run(`Design "${v.value.name}" created for ${nameOf(v.value.productId)}. It is on the order form now.`, async () => { await getDb().designs.create(v.value); });
    if (ok) setDraft({ ...EMPTY_DRAFT, productId: v.value.productId });
  };

  const startEdit = (d: ProductDesign) => { setEditingId(d.id); setEdit({ productId: d.productId, name: d.name, imageUrl: d.imageUrl, sortOrder: String(d.sortOrder) }); setEditErrors({}); setProblem(null); setDone(null); };
  const saveEdit = async (d: ProductDesign) => {
    const v = validateDraft(edit, designs, { editingId: d.id });
    if (!v.ok) { setEditErrors(v.errors); return; }
    setEditErrors({});
    const ok = await run(`Design "${v.value.name}" saved.`, async () => { await getDb().designs.update(d.id, { name: v.value.name, imageUrl: v.value.imageUrl, sortOrder: v.value.sortOrder }); });
    if (ok) setEditingId(null);
  };
  const toggle = (d: ProductDesign) => run(
    d.isActive ? `"${d.name}" is switched off: visitors no longer see it. Requests and orders that already use it are unchanged.` : `"${d.name}" is switched on and appears on the order form.`,
    async () => { await getDb().designs.setActive(d.id, !d.isActive); },
  );

  return (
    <div className="mx-auto max-w-5xl space-y-4 p-4">
      <header>
        <h1 className="flex items-center gap-2 text-xl font-bold text-slate-900"><Palette className="h-5 w-5" aria-hidden="true" /> Product designs</h1>
        <p className="mt-1 text-sm text-slate-600">
          The designs a visitor can choose, per ball, on the website order form. A product with active designs makes the visitor pick one on each order line; a product with none is ordered as before.
          Switching a design off hides it at once and never changes requests or orders that already use it.
        </p>
      </header>

      {problem && <div className="flex items-start gap-2 rounded-xl border border-red-100 bg-red-50 p-3 text-sm text-red-700" role="alert" data-testid="designs-problem"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" /> {problem}</div>}
      {done && <div className="flex items-start gap-2 rounded-xl border border-emerald-100 bg-emerald-50 p-3 text-sm text-emerald-800" role="status" data-testid="designs-done"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" /> {done}</div>}

      <section className={card} aria-labelledby="new-design">
        <h2 id="new-design" className="mb-3 text-sm font-bold text-slate-900">Add a design</h2>
        <div className="grid gap-3 md:grid-cols-[1.2fr_1.2fr_2fr_6rem_auto] md:items-start">
          <div>
            <label className="text-xs font-semibold text-slate-600" htmlFor="nd-product">Product</label>
            <select id="nd-product" className={input} value={draft.productId} onChange={(e) => setDraft({ ...draft, productId: e.target.value })} aria-invalid={Boolean(draftErrors.productId)}>
              <option value="">Choose…</option>
              {selectable.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
            {draftErrors.productId && <p className={err}>{draftErrors.productId}</p>}
          </div>
          <div>
            <label className="text-xs font-semibold text-slate-600" htmlFor="nd-name">Design name</label>
            <input id="nd-name" className={input} maxLength={NAME_MAX} placeholder="e.g. Red" value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} aria-invalid={Boolean(draftErrors.name)} />
            {draftErrors.name && <p className={err}>{draftErrors.name}</p>}
          </div>
          <div>
            <label className="text-xs font-semibold text-slate-600" htmlFor="nd-image">Picture link (optional, https://)</label>
            <input id="nd-image" className={input} maxLength={IMAGE_MAX} placeholder="https://…" value={draft.imageUrl} onChange={(e) => setDraft({ ...draft, imageUrl: e.target.value })} aria-invalid={Boolean(draftErrors.imageUrl)} />
            {draftErrors.imageUrl && <p className={err}>{draftErrors.imageUrl}</p>}
          </div>
          <div>
            <label className="text-xs font-semibold text-slate-600" htmlFor="nd-order">Order</label>
            <input id="nd-order" className={input} inputMode="numeric" value={draft.sortOrder} onChange={(e) => setDraft({ ...draft, sortOrder: e.target.value })} aria-invalid={Boolean(draftErrors.sortOrder)} />
            {draftErrors.sortOrder && <p className={err}>{draftErrors.sortOrder}</p>}
          </div>
          <div className="md:pt-5"><button type="button" className={btn} onClick={create} disabled={busy} data-testid="design-create">{busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null} Add design</button></div>
        </div>
      </section>

      <section className={card} aria-label="Filter designs">
        <div className="flex flex-wrap items-end gap-3">
          <div><label className="text-xs font-semibold text-slate-600" htmlFor="f-product">Product</label>
            <select id="f-product" className={`${input} w-56`} value={filter.productId} onChange={(e) => setFilter({ ...filter, productId: e.target.value })}>
              <option value="">All products</option>{products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select></div>
          <div><label className="text-xs font-semibold text-slate-600" htmlFor="f-status">Status</label>
            <select id="f-status" className={`${input} w-36`} value={filter.status} onChange={(e) => setFilter({ ...filter, status: e.target.value as DesignFilter["status"] })}>
              <option value="all">All</option><option value="active">Active</option><option value="inactive">Switched off</option>
            </select></div>
          <div className="min-w-[10rem] flex-1"><label className="text-xs font-semibold text-slate-600" htmlFor="f-search">Search by name</label>
            <input id="f-search" className={input} value={filter.search} onChange={(e) => setFilter({ ...filter, search: e.target.value })} /></div>
        </div>
      </section>

      {designs.length === 0 ? (
        <div className={`${card} text-sm text-slate-600`} data-testid="designs-empty">
          No designs yet. Until you add one, every ball on the order form is ordered by product alone, exactly as before.
        </div>
      ) : groups.length === 0 ? (
        <div className={`${card} text-sm text-slate-600`}>No design matches this filter.</div>
      ) : groups.map((g) => (
        <section key={g.productId} className={card} aria-label={`Designs of ${g.productName}`} data-testid="design-group">
          <div className="mb-2 flex items-baseline justify-between">
            <h2 className="text-sm font-bold text-slate-900">{g.productName}</h2>
            <span className="text-xs text-slate-500">{activeCount(designs, g.productId)} on the order form</span>
          </div>
          <ul className="divide-y divide-slate-100">
            {g.designs.map((d) => (
              <li key={d.id} className="py-2" data-testid="design-row">
                {editingId === d.id ? (
                  <div className="grid gap-2 md:grid-cols-[1.2fr_2fr_6rem_auto] md:items-start">
                    <div><label className="sr-only" htmlFor={`e-name-${d.id}`}>Design name</label>
                      <input id={`e-name-${d.id}`} className={input} maxLength={NAME_MAX} value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} aria-invalid={Boolean(editErrors.name)} />
                      {editErrors.name && <p className={err}>{editErrors.name}</p>}</div>
                    <div><label className="sr-only" htmlFor={`e-img-${d.id}`}>Picture link</label>
                      <input id={`e-img-${d.id}`} className={input} maxLength={IMAGE_MAX} placeholder="https://…" value={edit.imageUrl} onChange={(e) => setEdit({ ...edit, imageUrl: e.target.value })} aria-invalid={Boolean(editErrors.imageUrl)} />
                      {editErrors.imageUrl && <p className={err}>{editErrors.imageUrl}</p>}</div>
                    <div><label className="sr-only" htmlFor={`e-ord-${d.id}`}>Display order</label>
                      <input id={`e-ord-${d.id}`} className={input} inputMode="numeric" value={edit.sortOrder} onChange={(e) => setEdit({ ...edit, sortOrder: e.target.value })} aria-invalid={Boolean(editErrors.sortOrder)} />
                      {editErrors.sortOrder && <p className={err}>{editErrors.sortOrder}</p>}</div>
                    <div className="flex gap-2">
                      <button type="button" className={btn} disabled={busy} onClick={() => saveEdit(d)} data-testid="design-save">Save</button>
                      <button type="button" className={btn2} disabled={busy} onClick={() => setEditingId(null)}>Cancel</button>
                    </div>
                  </div>
                ) : (
                  <div className="flex flex-wrap items-center gap-3">
                    {d.imageUrl ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={d.imageUrl} alt={`${d.name} design`} className="h-10 w-10 rounded-md border border-slate-200 object-cover" />
                    ) : <div className="flex h-10 w-10 items-center justify-center rounded-md border border-dashed border-slate-200 text-slate-300" aria-hidden="true"><Palette className="h-4 w-4" /></div>}
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-semibold text-slate-900" data-testid="design-name">{d.name}</p>
                      <p className="text-xs text-slate-500">Order {d.sortOrder} · updated {d.updatedAt.slice(0, 10)}</p>
                    </div>
                    <span className={`rounded-full border px-2 py-0.5 text-[11px] font-semibold ${d.isActive ? "border-emerald-200 bg-emerald-50 text-emerald-800" : "border-slate-200 bg-slate-100 text-slate-600"}`} data-testid="design-status">
                      {d.isActive ? "Active" : "Switched off"}
                    </span>
                    <button type="button" className={btn2} disabled={busy} onClick={() => startEdit(d)} aria-label={`Edit ${d.name}`}><Pencil className="h-3.5 w-3.5" /> Edit</button>
                    <button type="button" className={btn2} disabled={busy} onClick={() => toggle(d)} aria-label={`${d.isActive ? "Switch off" : "Switch on"} ${d.name}`} data-testid="design-toggle"><Power className="h-3.5 w-3.5" /> {d.isActive ? "Switch off" : "Switch on"}</button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}
