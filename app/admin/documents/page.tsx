"use client";

/**
 * Printable invoice / receipt (browser "Print → Save as PDF"; no PDF library).
 *   /admin/documents?type=invoice&order=<order id>
 *   /admin/documents?type=receipt&order=<order id>&payment=<payment id>
 *
 * Read only. The order comes from order_details, so RLS decides what this user
 * may see (a Marketing Officer only their own customers' orders). Access: staff
 * who can open orders, customers or reports. Cost is never shown. Printing is
 * recorded in the audit trail BEFORE the print dialog opens (Phase 12 rule).
 */

import { useEffect, useState } from "react";
import { AlertCircle, Loader2, Printer, Shield } from "lucide-react";
import type { AdminProfile, AdminSettings, Order } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { formatYmd } from "@/lib/analytics/period";
import { usd } from "@/components/analytics/primitives";
import { buildInvoice, buildReceipt, toDocOrder, type InvoiceDoc, type ReceiptDoc } from "@/lib/finance/documents";

type Req = { type: "invoice" | "receipt" | null; orderId: string | null; paymentId: string | null };
const readReq = (): Req => {
  if (typeof window === "undefined") return { type: null, orderId: null, paymentId: null };
  const q = new URLSearchParams(window.location.search);
  const t = q.get("type");
  return { type: t === "invoice" || t === "receipt" ? t : null, orderId: q.get("order"), paymentId: q.get("payment") };
};

export default function DocumentPage() {
  const [req] = useState<Req>(readReq);
  const [state, setState] = useState<"loading" | "ready" | "denied" | "error">("loading");
  const [message, setMessage] = useState<string | null>(null);
  const [doc, setDoc] = useState<InvoiceDoc | ReceiptDoc | null>(null);
  const [settings, setSettings] = useState<AdminSettings | null>(null);
  const [printError, setPrintError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const db = getDb();
        const me: AdminProfile | null = await db.auth.getProfile();
        const p = derivePermissions(me);
        if (!me || !(p.accessOrdersModule || p.accessCustomerModule || p.viewReports)) { if (!cancelled) setState("denied"); return; }
        if (!req.type || !req.orderId || (req.type === "receipt" && !req.paymentId)) throw new Error("This document link is incomplete.");
        const [order, s]: [Order | null, AdminSettings] = await Promise.all([db.orders.get(req.orderId), db.settings.get()]);
        if (!order) throw new Error("Order not found, or not available to your account.");
        const o = toDocOrder(order);
        const built = req.type === "invoice" ? buildInvoice(o) : buildReceipt(o, req.paymentId as string);
        if ("error" in built) throw new Error(built.error);
        if (cancelled) return;
        setDoc(built); setSettings(s); setState("ready");
      } catch (error) {
        if (cancelled) return;
        setMessage(error instanceof Error && !("code" in error) ? error.message : describeDbError(error));
        setState("error");
      }
    })();
    return () => { cancelled = true; };
  }, [req]);

  const print = async () => {
    if (!doc) return;
    setPrintError(null);
    try {
      await getDb().logs.write({
        category: "FINANCIAL",
        severity: "INFO",
        message: `${"payment" in doc ? "Receipt" : "Invoice"} ${doc.number} printed for order ${doc.order.id}`,
        targetId: doc.order.id,
        metadata: { document: doc.number, order: doc.order.id },
      });
    } catch (error) {
      setPrintError(`Not printed: it could not be recorded in the audit trail (${describeDbError(error)}).`);
      return;
    }
    window.print();
  };

  if (state === "loading") return <div className="flex items-center justify-center gap-2 py-32 text-xs text-slate-400"><Loader2 className="h-5 w-5 animate-spin" /> Preparing document…</div>;
  if (state === "denied") return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3" data-testid="document-denied">
      <Shield className="h-12 w-12 text-slate-300" /><p className="text-sm text-slate-500">You do not have permission to view financial documents.</p>
    </div>
  );
  if (state === "error" || !doc || !settings) return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-2 rounded-xl border border-slate-200 bg-white py-12 text-center" data-testid="document-error">
      <AlertCircle className="h-7 w-7 text-amber-500" /><p className="text-sm font-semibold text-slate-800">No document</p><p className="px-4 text-xs text-slate-500">{message}</p>
    </div>
  );

  const isReceipt = "payment" in doc;
  const o = doc.order;
  return (
    <div className="space-y-4">
      <style>{`@media print { body * { visibility: hidden !important; } #efz-document, #efz-document * { visibility: visible !important; } #efz-document { position: absolute; left: 0; top: 0; width: 100%; box-shadow: none !important; border: 0 !important; } }`}</style>
      <div className="flex items-center justify-between gap-2 print:hidden">
        <p className="text-xs text-slate-500">Use Print and choose &quot;Save as PDF&quot; to download.</p>
        <button type="button" onClick={print} data-testid="document-print" className="inline-flex h-9 items-center gap-1.5 rounded-xl bg-slate-900 px-3 text-xs font-semibold text-white hover:bg-slate-800">
          <Printer className="h-3.5 w-3.5" /> Print / Save as PDF
        </button>
      </div>
      {printError && <p className="rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-800">{printError}</p>}

      <article id="efz-document" data-testid={isReceipt ? "receipt" : "invoice"} className="mx-auto max-w-3xl rounded-2xl border border-slate-200 bg-white p-8 text-slate-800 shadow-sm">
        <header className="flex items-start justify-between gap-6 border-b border-slate-200 pb-5">
          <div>
            <p className="text-lg font-bold text-slate-900">{settings.businessName}</p>
            {settings.contactEmail && <p className="text-xs text-slate-500">{settings.contactEmail}</p>}
            {settings.whatsappNumber && <p className="text-xs text-slate-500">WhatsApp {settings.whatsappNumber}</p>}
          </div>
          <div className="text-right">
            <p className="text-2xl font-bold tracking-tight text-slate-900">{isReceipt ? "RECEIPT" : "INVOICE"}</p>
            <p className="font-mono text-sm" data-testid="document-number">{doc.number}</p>
          </div>
        </header>

        <section className="grid grid-cols-2 gap-6 py-5 text-xs">
          <div>
            <p className="font-bold uppercase tracking-wider text-slate-400">{isReceipt ? "Received from" : "Bill to"}</p>
            <p className="mt-1 text-sm font-semibold text-slate-900">{o.customerName}</p>
            {o.phone && <p className="text-slate-500">{o.phone}</p>}
          </div>
          <dl className="grid grid-cols-2 gap-x-3 gap-y-1 text-right">
            {isReceipt ? (
              <>
                <dt className="text-slate-400">Payment date</dt><dd>{formatYmd((doc as ReceiptDoc).payment.date)}</dd>
                <dt className="text-slate-400">Order</dt><dd className="font-mono">{o.id}</dd>
                <dt className="text-slate-400">Invoice</dt><dd className="font-mono">{(doc as ReceiptDoc).invoiceNumber ?? "— (paid at sale)"}</dd>
              </>
            ) : (
              <>
                <dt className="text-slate-400">Issue date</dt><dd>{formatYmd((doc as InvoiceDoc).issueDate)}</dd>
                <dt className="text-slate-400">Order</dt><dd className="font-mono">{o.id}</dd>
                <dt className="text-slate-400">Status</dt><dd className="font-bold" data-testid="invoice-status">{(doc as InvoiceDoc).status}</dd>
              </>
            )}
          </dl>
        </section>

        {isReceipt ? (() => {
          const r = doc as ReceiptDoc;
          return (
            <section className="rounded-xl bg-slate-50 p-5 text-sm">
              <div className="flex items-baseline justify-between"><span className="text-slate-500">Amount received</span><span className="text-2xl font-bold text-slate-900" data-testid="receipt-amount">{usd(r.payment.amountCents)}</span></div>
              <dl className="mt-3 grid grid-cols-2 gap-y-1 text-xs">
                <dt className="text-slate-500">Payment method</dt><dd className="text-right">{r.payment.method || "Not recorded"}</dd>
                {r.payment.reference && (<><dt className="text-slate-500">Reference</dt><dd className="text-right">{r.payment.reference}</dd></>)}
                <dt className="text-slate-500">Order total</dt><dd className="text-right">{usd(o.totalCents)}</dd>
                <dt className="text-slate-500">Paid to date (including this payment)</dt><dd className="text-right" data-testid="receipt-paid-to-date">{usd(r.paidToDateCents)}</dd>
                <dt className="font-semibold text-slate-700">Balance after this payment</dt><dd className="text-right font-bold" data-testid="receipt-balance">{usd(r.balanceAfterCents)}</dd>
              </dl>
            </section>
          );
        })() : (() => {
          const inv = doc as InvoiceDoc;
          return (
            <>
              <table className="w-full text-xs">
                <thead><tr className="border-b border-slate-200 text-left text-[10px] uppercase tracking-wider text-slate-400"><th className="py-2">Item</th><th className="py-2 text-right">Qty</th><th className="py-2 text-right">Unit price</th><th className="py-2 text-right">Line total</th></tr></thead>
                <tbody className="divide-y divide-slate-100">
                  {o.lines.map((l, i) => (
                    <tr key={i}><td className="py-2">{l.name}</td><td className="py-2 text-right tabular-nums">{l.quantity}</td><td className="py-2 text-right tabular-nums">{usd(l.unitPriceCents)}</td><td className="py-2 text-right tabular-nums">{usd(l.lineTotalCents)}</td></tr>
                  ))}
                </tbody>
              </table>
              <dl className="ml-auto mt-4 grid w-72 grid-cols-2 gap-y-1 text-xs">
                <dt className="font-semibold">Invoice total</dt><dd className="text-right font-semibold tabular-nums" data-testid="invoice-total">{usd(inv.totalCents)}</dd>
                <dt className="text-slate-500">Payments received</dt><dd className="text-right tabular-nums" data-testid="invoice-paid">{usd(inv.paidCents)}</dd>
                <dt className="border-t border-slate-200 pt-1 font-bold">Balance due</dt><dd className="border-t border-slate-200 pt-1 text-right font-bold tabular-nums" data-testid="invoice-outstanding">{usd(inv.outstandingCents)}</dd>
              </dl>
              {inv.payments.length > 0 && (
                <div className="mt-6">
                  <p className="mb-1 text-[10px] font-bold uppercase tracking-wider text-slate-400">Payments</p>
                  <table className="w-full text-xs"><tbody className="divide-y divide-slate-100">
                    {inv.payments.map((p) => (
                      <tr key={p.id}><td className="py-1.5">{formatYmd(p.date)}</td><td className="py-1.5 font-mono">{p.receiptNumber}</td><td className="py-1.5">{p.method || "Not recorded"}</td><td className="py-1.5 text-right tabular-nums">{usd(p.amountCents)}</td></tr>
                    ))}
                  </tbody></table>
                </div>
              )}
            </>
          );
        })()}

        <footer className="mt-8 border-t border-slate-200 pt-3 text-[10px] text-slate-400">
          {isReceipt ? "Thank you for your payment." : "Amounts in US dollars at the agreed price per item."} {settings.shortName || settings.businessName}
        </footer>
      </article>
    </div>
  );
}
