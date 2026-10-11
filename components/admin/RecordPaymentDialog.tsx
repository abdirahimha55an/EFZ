"use client";

/**
 * The one Record Payment dialog for existing orders. Moved unchanged from the
 * Customer Database page so Customer Database and Financial Management share
 * the same workflow: the same validation, record_payment() via
 * db.orders.addPayment (the database checks permission, amount and status and
 * maintains amount_paid / outstanding_balance / payment_status), and the same
 * FINANCIAL audit line. Nothing here computes a balance the database owns.
 */

import { useState } from "react";
import { Loader2, X } from "lucide-react";
import type { Order } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { efzToday } from "@/lib/dates";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

/** Who may record a payment on an existing order: record_payment() requires create_orders or edit_orders. */
export const canRecordPayment = (perms: { createOrders: boolean; editOrders: boolean }) => perms.createOrders || perms.editOrders;

type Props = {
  order: Order;
  /** Only a Super Admin may date a payment before today. */
  canBackdate: boolean;
  onClose: () => void;
  /** Called after the payment and its audit line are recorded; the page reloads its data here. */
  onRecorded: () => Promise<void> | void;
  notify: (type: "success" | "error", message: string) => void;
};

const emptyForm = () => ({ amount: "", paymentDate: efzToday(), paymentMethod: "Cash", reference: "", note: "" });

export function RecordPaymentDialog({ order, canBackdate, onClose, onRecorded, notify }: Props) {
  const [paymentForm, setPaymentForm] = useState(emptyForm);
  const [isSaving, setIsSaving] = useState(false);

  const total = Number(order.total || 0);
  const collected = Number(order.amountPaid ?? order.payments?.reduce((sum, payment) => sum + Number(payment.amount || 0), 0) ?? 0);
  const outstanding = Math.max(0, total - collected);

  const recordPayment = async () => {
    const dbOutstanding = Math.max(0, Number(order.outstandingBalance ?? 0));
    const amountValue = Number(paymentForm.amount);

    // Checked here for an instant answer; record_payment() checks it again and
    // is the one that actually decides.
    if (!paymentForm.amount || Number.isNaN(amountValue) || amountValue <= 0 || amountValue > dbOutstanding) {
      notify("error", "Payment amount must be greater than zero and cannot exceed the current outstanding balance.");
      return;
    }

    try {
      setIsSaving(true);
      const db = getDb();

      // Only a Super Admin may date a payment before today; everyone else's is
      // dated today (Mogadishu) by the database.
      const today = efzToday();
      if (canBackdate && paymentForm.paymentDate > today) {
        notify("error", "A payment cannot be dated in the future.");
        return;
      }
      const paymentDate = canBackdate && paymentForm.paymentDate && paymentForm.paymentDate !== today
        ? paymentForm.paymentDate
        : undefined;

      await db.orders.addPayment({
        orderId: order.id,
        amount: amountValue,
        paymentDate,
        paymentMethod: paymentForm.paymentMethod,
        reference: paymentForm.reference,
        notes: paymentForm.note,
      });

      await db.logs.write({
        category: "FINANCIAL",
        severity: "INFO",
        message: `Payment of $${amountValue} recorded against order ${order.id}`,
        targetId: order.id,
        metadata: { amount: amountValue, method: paymentForm.paymentMethod, reference: paymentForm.reference },
      });

      await onRecorded();
      setPaymentForm(emptyForm());
      onClose();
      notify("success", "Payment recorded successfully.");
    } catch (error) {
      notify("error", describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[120] bg-slate-900/60 flex items-center justify-center p-4" role="dialog" aria-label="Record payment" data-testid="record-payment-dialog">
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-xl p-6">
        <div className="flex items-center justify-between mb-4">
          <div>
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Record payment</p>
            <h3 className="text-xl font-bold text-slate-900">{order.customer}</h3>
          </div>
          <button type="button" aria-label="Close" onClick={onClose} className="rounded-full border border-slate-200 p-2 text-slate-500">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="grid grid-cols-2 gap-3 text-xs text-slate-600 mb-4">
          <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Order ID</span><strong className="text-slate-900">{order.id}</strong></div>
          <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Order Type</span><strong className="text-slate-900 uppercase">{order.orderType || "regular"}</strong></div>
          <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Order Total</span><strong className="text-slate-900">${total.toFixed(2)}</strong></div>
          <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Outstanding</span><strong className="text-slate-900">${outstanding.toFixed(2)}</strong></div>
        </div>

        <div className="space-y-3">
          <div>
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Payment Amount</label>
            <Input value={paymentForm.amount} onChange={e => setPaymentForm({ ...paymentForm, amount: e.target.value })} type="number" min="0" step="0.01" placeholder="0.00" className="h-11 rounded-xl" />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Payment Date</label>
              {canBackdate ? (
                <>
                  <Input value={paymentForm.paymentDate} max={efzToday()} onChange={e => setPaymentForm({ ...paymentForm, paymentDate: e.target.value })} type="date" className="h-11 rounded-xl" />
                  {paymentForm.paymentDate < efzToday() && (
                    <p className="mt-1 text-[10px] font-bold text-amber-600">Backdated payment - recorded in the audit log.</p>
                  )}
                </>
              ) : (
                <div className="flex h-11 items-center rounded-xl border border-slate-200 bg-slate-50 px-3 text-sm text-slate-600" title="Only a Super Admin can record an earlier payment date">
                  Today ({efzToday()})
                </div>
              )}
            </div>
            <div>
              <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Payment Method</label>
              <select value={paymentForm.paymentMethod} onChange={e => setPaymentForm({ ...paymentForm, paymentMethod: e.target.value })} className="h-11 w-full rounded-xl border border-slate-200 bg-slate-50 px-3 text-sm">
                <option>Cash</option>
                <option>EVC</option>
                <option>eDahab</option>
                <option>Bank</option>
              </select>
            </div>
          </div>
          <div>
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Reference / Note</label>
            <Input value={paymentForm.reference} onChange={e => setPaymentForm({ ...paymentForm, reference: e.target.value })} placeholder="INV-001" className="h-11 rounded-xl" />
          </div>
          <div>
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Note</label>
            <Input value={paymentForm.note} onChange={e => setPaymentForm({ ...paymentForm, note: e.target.value })} placeholder="Optional note" className="h-11 rounded-xl" />
          </div>
        </div>

        <div className="mt-6 flex gap-3">
          <Button type="button" variant="outline" onClick={onClose} className="flex-1 h-11 rounded-xl">Cancel</Button>
          <Button type="button" disabled={isSaving} onClick={recordPayment} className="flex-1 h-11 rounded-xl bg-slate-900 text-white">{isSaving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Record Payment</Button>
        </div>
      </div>
    </div>
  );
}
