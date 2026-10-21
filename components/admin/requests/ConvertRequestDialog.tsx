"use client";

/**
 * Convert to Order (design I/J/K). Everything is decided here, then ONE database
 * call - convert_website_request() - does it all in one transaction: the
 * customer (existing, or new with an optional initial Marketing Officer), one
 * order with every line through the unchanged create_order() (stock, pricing and
 * below-cost rules), and the request marked converted and linked. If anything
 * is refused, nothing at all is written and the request stays confirmed.
 *
 * Customer matching is by phone only (canonical form, find_customers_by_phone);
 * a name is never used to suggest a customer. Staff may still search by name and
 * pick one explicitly.
 */
import { useEffect, useMemo, useState } from "react";
import { AlertCircle, CheckCircle2, Loader2, Plus, Trash2, X } from "lucide-react";

import { Button } from "@/components/ui/button";
import { derivePermissions } from "@/lib/permissions";
import { isAcceptedRequestPhone, PHONE_HINT } from "@/lib/phone";
import { cn } from "@/lib/utils";
import { describeDbError, getDb } from "@/lib/supabase/db";
import {
  type ConversionLine,
  hasDuplicateLines,
  isAgreedPrice,
  isAgreementOverride,
  isPriceChanged,
  lineBlock,
  linePrice,
  OVERRIDE_REASON_MIN,
  overrideReasonMissing,
  overrideSummary,
  parsePriceInfo,
  toPayloadLine,
} from "@/lib/requestConversion";
import type { AdminUser, Customer, CustomerMatch, Product, WebsiteRequest } from "@/lib/types";

type Props = {
  request: WebsiteRequest;
  profile: AdminUser;
  staff: AdminUser[];
  onClose: () => void;
  onConverted: () => Promise<void>;
};

type Line = ConversionLine & { key: number };
type CustomerChoice = { kind: "existing"; customerId: string; label: string; archived: boolean } | { kind: "new" } | null;

const money = (n: number) => `$${n.toFixed(2)}`;

export function ConvertRequestDialog({ request, profile, staff, onClose, onConverted }: Props) {
  const perms = derivePermissions(profile);
  const [products, setProducts] = useState<Product[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [matches, setMatches] = useState<CustomerMatch[] | null>(null);
  const [choice, setChoice] = useState<CustomerChoice>(null);
  const [search, setSearch] = useState("");
  const [archivedConfirmed, setArchivedConfirmed] = useState(false);
  const [newCustomer, setNewCustomer] = useState({
    name: request.customerName,
    phone: request.phone,
    email: "",
    notes: request.organization ? `Arena / company: ${request.organization}` : "",
    ownerOfficerId: "",
  });
  const [newPhoneMatches, setNewPhoneMatches] = useState<CustomerMatch[]>([]);
  const [confirmNoDuplicate, setConfirmNoDuplicate] = useState(false);
  const [lines, setLines] = useState<Line[]>([]);
  const [nextKey, setNextKey] = useState(1);
  const [deliveryNotes, setDeliveryNotes] = useState(
    [
      request.deliveryLocation,
      request.visitorNotes,
    ].filter(Boolean).join(" - ")
  );
  const [belowCostReason, setBelowCostReason] = useState("");
  // 28: needed (10+ characters) when a line is charged a price other than the customer's agreed price.
  const [priceOverrideReason, setPriceOverrideReason] = useState("");
  // 28: bumped by "Retry" to ask the database for the customer's prices again.
  const [retryTick, setRetryTick] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [orderId, setOrderId] = useState<string | null>(null);

  // Load products, customers and phone matches; start the lines from the request.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const db = getDb();
        const [nextProducts, nextCustomers, nextMatches] = await Promise.all([
          db.products.list({ includeInactive: true }),
          db.customers.list({ includeArchived: true }),
          db.orderRequests.findCustomers(request.id),
        ]);
        if (cancelled) return;
        setProducts(nextProducts);
        setCustomers(nextCustomers);
        setMatches(nextMatches);
        // 22: a request from the customer app belongs to the staff-verified customer of that account: preselect it (staff can still change it).
        const verified = request.app ? nextCustomers.find((c) => c.id === request.app?.customerId) : undefined;
        if (verified) setChoice({ kind: "existing", customerId: verified.id, label: verified.name, archived: verified.status === "archived" });
        const start = request.lines.map((l, i) => {
          const p = nextProducts.find((x) => x.id === l.productId);
          // 28: the design chosen in the app travels with the line as structured data (no longer copied into the delivery notes).
          return { key: i + 1, productId: p ? p.id : "", quantity: String(l.quantity), designId: l.designId, designName: l.designName || undefined, price: "", priceEdited: false, info: undefined } as Line;
        });
        setLines(start);
        setNextKey(start.length + 1);
      } catch (e) {
        if (!cancelled) setError(describeDbError(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [request]);

  // A new customer's phone (as edited) checked against existing customers.
  useEffect(() => {
    if (choice?.kind !== "new") return;
    let cancelled = false;
    const timer = window.setTimeout(async () => {
      try {
        const found = isAcceptedRequestPhone(newCustomer.phone)
          ? await getDb().orderRequests.findCustomers(request.id, newCustomer.phone)
          : [];
        if (!cancelled) {
          setNewPhoneMatches(found);
          setConfirmNoDuplicate(false);
        }
      } catch {
        if (!cancelled) setNewPhoneMatches([]);
      }
    }, 300);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [choice?.kind, newCustomer.phone, request.id]);

  // 28: what price will the database apply to each line? Asked again when the customer, a product or a design changes. A brand-new customer has no
  // agreements, so the list price applies. If the answer cannot be had or is not usable (null) the line is BLOCKED with a Retry: a displayed price is never sent as
  // a fallback, because a price that differs from an agreement the page could not see would silently become an override.
  // a different customer means different agreements: every line waits for its new answer (the effect below asks again), and a price typed for the
  // previous customer is dropped so it can never be compared with, or sent against, someone else's agreement
  const chooseCustomer = (next: CustomerChoice) => {
    setChoice(next);
    setLines((c) => c.map((l) => ({ ...l, info: undefined, price: "", priceEdited: false })));
  };
  const retryLookups = () => {
    setLines((c) => c.map((l) => (l.info === null ? { ...l, info: undefined } : l)));
    setRetryTick((n) => n + 1);
  };
  const customerKey = choice?.kind === "existing" ? choice.customerId : choice?.kind ?? "";
  const resolveKey = lines.map((l) => `${l.key}:${l.productId}:${l.designName ?? ""}`).join(",") + "|" + customerKey;
  useEffect(() => {
    if (!choice || products.length === 0) return;
    let cancelled = false;
    const targets = lines.filter((l) => l.productId).map((l) => ({ key: l.key, productId: l.productId, designName: l.designName }));
    (async () => {
      const db = getDb();
      const answers = await Promise.all(targets.map(async (t) => {
        const p = products.find((x) => x.id === t.productId);
        if (choice.kind === "new") return { t, info: parsePriceInfo(p ? { source: "list", price: p.sellingPrice, listPrice: p.sellingPrice, reason: null } : null) };
        return { t, info: parsePriceInfo(await db.orders.resolvePrice(choice.customerId, t.productId, t.designName).catch(() => null)) };
      }));
      if (cancelled) return;
      setLines((c) => c.map((l) => {
        const a = answers.find((x) => x.t.key === l.key && x.t.productId === l.productId && x.t.designName === l.designName);
        if (!a) return l;
        // no usable answer (null) leaves the price EMPTY and the line blocked: a shown price is never a fallback
        const shown = a.info && a.info.price !== null ? String(a.info.price) : "";
        return { ...l, info: a.info, price: l.priceEdited && a.info ? l.price : shown, priceEdited: a.info ? l.priceEdited : false };
      }));
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [resolveKey, products, choice?.kind, retryTick]);

  const officers = useMemo(() => staff.filter((s) => s.role === "Marketing Officer" && s.status === "active"), [staff]);
  const searchResults = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (q.length < 2) return [];
    return customers.filter((c) => c.name.toLowerCase().includes(q) || c.id.toLowerCase().includes(q)).slice(0, 8);
  }, [customers, search]);

  const productOf = (id: string) => products.find((p) => p.id === id);
  const parsed = lines.map((l) => ({ ...l, qty: Math.round(Number(l.quantity)), unit: linePrice(l) }));
  const total = parsed.reduce((s, l) => s + (Number.isFinite(l.qty) && l.unit !== null ? l.qty * l.unit : 0), 0);
  // a line charged exactly its agreed price never asks for a below-cost reason (the agreement was approved when it was verified)
  const belowCost = parsed.some((l) => {
    const p = productOf(l.productId);
    return p?.costPrice != null && l.unit !== null && l.unit < p.costPrice && !isAgreedPrice(l);
  });
  const linesValid =
    parsed.length > 0 &&
    parsed.length <= 20 &&
    parsed.every((l) => l.productId && Number.isInteger(l.qty) && l.qty >= 1 && l.info !== undefined && !lineBlock(l) && l.unit !== null && l.unit >= 0) &&
    !hasDuplicateLines(lines);
  const overrideLines = lines.filter(isAgreementOverride);
  const overrideRows = overrideSummary(lines);

  const customerValid =
    choice?.kind === "existing"
      ? !choice.archived || archivedConfirmed
      : choice?.kind === "new"
        ? newCustomer.name.trim().length > 0 && isAcceptedRequestPhone(newCustomer.phone) && (newPhoneMatches.length === 0 || confirmNoDuplicate)
        : false;

  const canSubmit = linesValid && customerValid && !busy && !overrideReasonMissing(lines, priceOverrideReason) && (!belowCost || (perms.approveBelowCost && belowCostReason.trim().length > 0));

  const updateLine = (key: number, patch: Partial<Line>) => setLines((current) => current.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const convert = async () => {
    if (!choice) return;
    setBusy(true);
    setError(null);
    try {
      const id = await getDb().orderRequests.convert(request.id, {
        customer:
          choice.kind === "existing"
            ? { kind: "existing", customerId: choice.customerId }
            : {
                kind: "new",
                name: newCustomer.name.trim(),
                phone: newCustomer.phone.trim(),
                email: newCustomer.email.trim(),
                notes: newCustomer.notes.trim(),
                ownerOfficerId: newCustomer.ownerOfficerId || undefined,
                confirmNoDuplicate,
              },
        lines: lines.map(toPayloadLine),
        deliveryNotes: deliveryNotes.trim(),
        belowCostReason: belowCost ? belowCostReason.trim() : undefined,
        priceOverrideReason: overrideLines.length > 0 ? priceOverrideReason.trim() : undefined,
      });
      setOrderId(id);
    } catch (e) {
      setError(describeDbError(e, { hideCost: !perms.viewCost }));
    } finally {
      setBusy(false);
    }
  };

  if (orderId) {
    return (
      <div className="fixed inset-0 z-[60] flex items-center justify-center bg-slate-900/40 p-4" role="dialog" aria-label="Request converted">
        <div className="w-full max-w-md rounded-2xl bg-white p-8 text-center shadow-2xl">
          <CheckCircle2 className="mx-auto h-12 w-12 text-emerald-500" />
          <h3 className="mt-3 text-lg font-bold text-slate-900">Order {orderId} created</h3>
          <p className="mt-1 text-xs text-slate-500">
            {request.reference} is now converted and linked to this order. It continues in Order Tracking like any other order.
          </p>
          <Button className="mt-6" onClick={onConverted}>Done</Button>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4" role="dialog" aria-label="Convert to order">
      <div className="my-8 w-full max-w-2xl rounded-2xl bg-white shadow-2xl" data-testid="convert-dialog">
        <div className="flex items-center justify-between border-b border-slate-100 px-6 py-4">
          <div>
            <p className="font-mono text-[10px] text-slate-400">{request.reference}</p>
            <h3 className="text-base font-bold text-slate-900">Convert to Order</h3>
          </div>
          <button type="button" onClick={onClose} aria-label="Close" className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="space-y-6 p-6 text-xs">
          {/* 1. Customer */}
          <section className="space-y-3">
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500">1. Customer</p>
            {matches === null ? (
              <p className="text-slate-400"><Loader2 className="mr-1 inline h-3 w-3 animate-spin" />Checking existing customers by phone…</p>
            ) : matches.length > 0 ? (
              <div className="space-y-2">
                <p className="text-slate-600">Customers with this phone number. Pick one only if it is the same person:</p>
                {matches.map((m) => (
                  <label key={m.customerId} className={cn("flex cursor-pointer items-center gap-3 rounded-lg border p-3", choice?.kind === "existing" && choice.customerId === m.customerId ? "border-brand-blue bg-blue-50/50" : "border-slate-200")}>
                    <input
                      type="radio"
                      name="customer"
                      checked={choice?.kind === "existing" && choice.customerId === m.customerId}
                      onChange={() => { chooseCustomer({ kind: "existing", customerId: m.customerId, label: m.name, archived: m.status === "archived" }); setArchivedConfirmed(false); }}
                    />
                    <span className="flex-1">
                      <span className="font-bold text-slate-900">{m.name}</span>{" "}
                      <span className="font-mono text-slate-500">{m.phoneMasked}</span>
                      <span className="block text-[10px] text-slate-500">{m.officerName ? `Marketing Officer: ${m.officerName}` : "No Marketing Officer"}</span>
                    </span>
                    {m.status === "archived" && <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[9px] font-bold uppercase text-amber-700">archived</span>}
                  </label>
                ))}
              </div>
            ) : (
              <p className="text-slate-500">No existing customer has this phone number.</p>
            )}

            <div className="space-y-1">
              <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Or search customers by name or id…" aria-label="Search customers" className="w-full rounded-md border border-slate-200 p-2" />
              {searchResults.map((c) => (
                <button
                  key={c.id}
                  type="button"
                  onClick={() => { chooseCustomer({ kind: "existing", customerId: c.id, label: c.name, archived: c.status === "archived" }); setArchivedConfirmed(false); setSearch(""); }}
                  className="block w-full rounded-md px-2 py-1 text-left hover:bg-slate-50"
                >
                  {c.name} <span className="font-mono text-slate-400">{c.id}</span>{c.status === "archived" && " (archived)"}
                </button>
              ))}
            </div>

            <label className={cn("flex cursor-pointer items-center gap-3 rounded-lg border p-3", choice?.kind === "new" ? "border-brand-blue bg-blue-50/50" : "border-slate-200")}>
              <input type="radio" name="customer" checked={choice?.kind === "new"} onChange={() => chooseCustomer({ kind: "new" })} />
              <span className="font-bold text-slate-900">New customer from this request</span>
            </label>

            {choice?.kind === "existing" && (
              <p className="text-slate-600">
                Selected: <b>{choice.label}</b>. The customer keeps its current Marketing Officer.
                {choice.archived && (
                  <label className="mt-2 flex items-center gap-2 text-amber-700">
                    <input type="checkbox" checked={archivedConfirmed} onChange={(e) => setArchivedConfirmed(e.target.checked)} />
                    This customer is archived. Use it anyway.
                  </label>
                )}
              </p>
            )}

            {choice?.kind === "new" && (
              <div className="grid grid-cols-1 gap-3 rounded-lg border border-slate-100 p-3 sm:grid-cols-2">
                <label className="space-y-1">
                  <span className="text-[10px] font-bold uppercase text-slate-500">Name</span>
                  <input value={newCustomer.name} maxLength={200} onChange={(e) => setNewCustomer({ ...newCustomer, name: e.target.value })} className="w-full rounded-md border border-slate-200 p-2" />
                </label>
                <label className="space-y-1">
                  <span className="text-[10px] font-bold uppercase text-slate-500">Phone</span>
                  <input value={newCustomer.phone} onChange={(e) => setNewCustomer({ ...newCustomer, phone: e.target.value })} className="w-full rounded-md border border-slate-200 p-2 font-mono" />
                  {!isAcceptedRequestPhone(newCustomer.phone) && <span className="text-red-600">{PHONE_HINT}</span>}
                </label>
                <label className="space-y-1">
                  <span className="text-[10px] font-bold uppercase text-slate-500">Email (optional)</span>
                  <input value={newCustomer.email} onChange={(e) => setNewCustomer({ ...newCustomer, email: e.target.value })} className="w-full rounded-md border border-slate-200 p-2" />
                </label>
                {/* 19: setting the initial owner needs assign_website_requests (checked again by convert_website_request). */}
                {perms.assignWebsiteRequests && (
                  <label className="space-y-1">
                    <span className="text-[10px] font-bold uppercase text-slate-500">Initial Marketing Officer (optional)</span>
                    <select value={newCustomer.ownerOfficerId} onChange={(e) => setNewCustomer({ ...newCustomer, ownerOfficerId: e.target.value })} className="w-full rounded-md border border-slate-200 p-2">
                      <option value="">None - leave unassigned</option>
                      {officers.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
                    </select>
                  </label>
                )}
                <label className="space-y-1 sm:col-span-2">
                  <span className="text-[10px] font-bold uppercase text-slate-500">Customer notes</span>
                  <input value={newCustomer.notes} onChange={(e) => setNewCustomer({ ...newCustomer, notes: e.target.value })} className="w-full rounded-md border border-slate-200 p-2" />
                </label>
                {newPhoneMatches.length > 0 && (
                  <div className="space-y-1 rounded-md border border-amber-200 bg-amber-50 p-2 text-amber-800 sm:col-span-2">
                    <p className="font-bold">A customer with this phone already exists: {newPhoneMatches.map((m) => m.name).join(", ")}.</p>
                    <label className="flex items-center gap-2">
                      <input type="checkbox" checked={confirmNoDuplicate} onChange={(e) => setConfirmNoDuplicate(e.target.checked)} />
                      This is a different customer. Create a separate one.
                    </label>
                  </div>
                )}
                {newCustomer.ownerOfficerId && (
                  <p className="text-[10px] text-slate-500 sm:col-span-2">
                    The new customer and this order will belong to the chosen officer (commission per the usual rules). The officer does not get access to the website request.
                  </p>
                )}
              </div>
            )}
          </section>

          {/* 2. Lines and prices */}
          <section className="space-y-3">
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500">2. Products, quantities and price</p>
            <p className="text-[10px] text-slate-400">The price is the customer&apos;s agreed price when there is one (the design&apos;s own agreement first), otherwise the list price. Change it only to charge something else.</p>
            <div className="space-y-2">
              {lines.map((line) => {
                const p = productOf(line.productId);
                // a changed product loses the design, so only lines without a design count as "taken"
                const taken = new Set(lines.filter((l) => l.key !== line.key && !l.designId && !l.designName).map((l) => l.productId));
                const blocked = lineBlock(line);
                const changed = isPriceChanged(line);
                const requested = request.lines.find((r) => r.productId && r.productId === line.productId);
                return (
                  <div key={line.key} className="space-y-1" data-testid="convert-line">
                  <div className="grid grid-cols-[1fr_5rem_6rem_auto] items-end gap-2">
                    <label className="min-w-0 space-y-1">
                      <span className="text-[10px] text-slate-500">
                        Product{p ? ` · in stock ${p.stock}` : ""}{p && p.isActive === false ? " · hidden from the website" : ""}
                      </span>
                      <select
                        value={line.productId}
                        onChange={(e) => {
                          const next = productOf(e.target.value);
                          updateLine(line.key, { productId: e.target.value, designId: undefined, designName: undefined, price: next && choice?.kind === "new" ? String(next.sellingPrice) : "", priceEdited: false, info: undefined });
                        }}
                        className="w-full rounded-md border border-slate-200 p-2"
                        aria-label="Product"
                      >
                        <option value="">Choose a product…</option>
                        {products.map((x) => <option key={x.id} value={x.id} disabled={taken.has(x.id)}>{x.name}</option>)}
                      </select>
                    </label>
                    <label className="space-y-1">
                      <span className="text-[10px] text-slate-500">Qty{requested && Number(line.quantity) !== requested.quantity ? ` (asked ${requested.quantity})` : ""}</span>
                      <input type="number" min={1} step={1} value={line.quantity} onChange={(e) => updateLine(line.key, { quantity: e.target.value })} className="w-full rounded-md border border-slate-200 p-2 font-mono" aria-label="Quantity" />
                    </label>
                    <label className="space-y-1">
                      <span className="text-[10px] text-slate-500">Unit price{p ? ` (list ${money(p.sellingPrice)})` : ""}</span>
                      <input type="number" min={0} step="0.01" value={line.price} placeholder={choice ? "…" : "pick customer"} disabled={!line.info || line.info.price === null} onChange={(e) => updateLine(line.key, { price: e.target.value, priceEdited: true })} className="w-full rounded-md border border-slate-200 p-2 font-mono" aria-label="Unit price" data-testid="convert-price" />
                    </label>
                    <button type="button" onClick={() => setLines((c) => c.filter((l) => l.key !== line.key))} disabled={lines.length === 1} aria-label="Remove line" className="mb-0.5 rounded-md p-2 text-slate-400 hover:bg-red-50 hover:text-red-600 disabled:opacity-30">
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                  <div className="flex flex-wrap items-center gap-2 text-[10px]">
                    {line.designName && <span className="rounded bg-slate-100 px-1.5 py-0.5 font-bold text-slate-600" data-testid="convert-design">Design: {line.designName}</span>}
                    {line.info?.source === "agreement" && !changed && <span className="rounded bg-emerald-50 px-1.5 py-0.5 font-bold text-emerald-700" data-testid="convert-price-source">Agreed price</span>}
                    {line.info?.source === "list" && !changed && <span className="rounded bg-slate-100 px-1.5 py-0.5 font-bold text-slate-600" data-testid="convert-price-source">List price</span>}
                    {line.info === undefined && line.productId && choice && <span className="text-slate-400">Checking the customer&apos;s price…</span>}
                    {changed && (
                      <>
                        <span className="rounded bg-amber-50 px-1.5 py-0.5 font-bold text-amber-700" data-testid="convert-price-source">Price changed{line.info?.source === "agreement" ? ` (agreed ${line.info.price !== null ? money(line.info.price) : "-"})` : ""}</span>
                        <button type="button" className="text-brand-blue underline" onClick={() => updateLine(line.key, { priceEdited: false, price: line.info?.price != null ? String(line.info.price) : "" })}>Use the {line.info?.source === "agreement" ? "agreed" : "standard"} price</button>
                      </>
                    )}
                    {blocked && <span className="font-bold text-red-600" data-testid="convert-line-blocked">{blocked}</span>}
                    {line.info === null && (
                      <button type="button" onClick={retryLookups} className="rounded border border-red-200 px-1.5 py-0.5 font-bold text-red-700 hover:bg-red-50" data-testid="convert-retry">Retry</button>
                    )}
                  </div>
                  </div>
                );
              })}
              {request.lines.some((l) => !l.productId) && (
                <p className="text-red-600">A requested product no longer exists ({request.lines.filter((l) => !l.productId).map((l) => l.productName).join(", ")}). Choose a replacement or remove that line.</p>
              )}
              {lines.length < 20 && (
                <Button type="button" size="sm" variant="ghost" onClick={() => { setLines((c) => [...c, { key: nextKey, productId: "", quantity: "1", price: "", priceEdited: false, info: undefined }]); setNextKey((k) => k + 1); }}>
                  <Plus className="mr-1 h-3.5 w-3.5" /> Add a product
                </Button>
              )}
            </div>
            <p className="text-right font-bold text-slate-900">Order total: <span className="font-mono">{money(total)}</span></p>
            <p className="text-[10px] text-slate-400">Stock is checked again when you convert, against what open orders already promise. Stock leaves the shelf only when balls are delivered.</p>
            {overrideLines.length > 0 && (
              <div className="space-y-2 rounded-md border border-amber-200 bg-amber-50 p-3 text-amber-900" data-testid="override-reason">
                <p className="font-bold">Price override: this order charges a price other than the customer&apos;s agreed price.</p>
                <table className="w-full text-left" data-testid="override-summary">
                  <thead>
                    <tr className="text-[10px] uppercase text-amber-700"><th className="py-0.5 pr-2">Product</th><th className="pr-2">Qty</th><th className="pr-2">Agreed</th><th className="pr-2">Proposed</th><th className="text-right">Difference</th></tr>
                  </thead>
                  <tbody>
                    {overrideRows.map((r, i) => (
                      <tr key={i} className="font-mono">
                        <td className="py-0.5 pr-2 font-sans">{productOf(r.productId)?.name ?? r.productId}{r.designName ? ` (${r.designName})` : ""}</td>
                        <td className="pr-2">{r.quantity}</td>
                        <td className="pr-2">{money(r.agreed)}</td>
                        <td className="pr-2 font-bold">{money(r.proposed)}</td>
                        <td className="text-right">{r.total >= 0 ? "+" : "-"}{money(Math.abs(r.total))} ({r.perUnit >= 0 ? "+" : "-"}{money(Math.abs(r.perUnit))} each)</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                <label className="block space-y-1">
                  <span className="font-bold">Reason (at least {OVERRIDE_REASON_MIN} characters; it is recorded in the audit log with the agreed and charged prices):</span>
                  <input value={priceOverrideReason} onChange={(e) => setPriceOverrideReason(e.target.value)} className="w-full rounded-md border border-amber-200 bg-white p-2" aria-label="Price override reason" />
                </label>
              </div>
            )}
            {belowCost && (
              perms.approveBelowCost ? (
                <label className="block space-y-1 rounded-md border border-amber-200 bg-amber-50 p-2 text-amber-800">
                  <span className="font-bold">A price is below cost. Reason for approving the below-cost sale:</span>
                  <input value={belowCostReason} onChange={(e) => setBelowCostReason(e.target.value)} className="w-full rounded-md border border-amber-200 p-2" />
                </label>
              ) : (
                <p className="rounded-md border border-red-100 bg-red-50 p-2 text-red-700">A price is below the product&apos;s cost. Only a Super Admin can approve a below-cost sale.</p>
              )
            )}
          </section>

          {/* 3. Delivery */}
          <section className="space-y-1">
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500">3. Delivery notes on the order</p>
            <textarea value={deliveryNotes} onChange={(e) => setDeliveryNotes(e.target.value)} className="w-full rounded-md border border-slate-200 p-2" aria-label="Delivery notes" />
            <p className="text-[10px] text-slate-400">Request notes stay on the request; only this text goes to the order.</p>
          </section>

          {error && (
            <div className="flex items-start gap-2 rounded-lg border border-red-100 bg-red-50 p-3 text-red-700">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
              <p>{error} Nothing was created; the request is still confirmed.</p>
            </div>
          )}
        </div>

        <div className="flex justify-end gap-2 border-t border-slate-100 px-6 py-4">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button onClick={convert} disabled={!canSubmit}>
            {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            {overrideLines.length > 0 ? "Create order with price override" : "Create order"}
          </Button>
        </div>
      </div>
    </div>
  );
}
