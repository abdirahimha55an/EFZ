"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { Product } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { toPublicProduct } from "@/lib/supabase/mappers";
import { isAcceptedRequestPhone, PHONE_HINT } from "@/lib/phone";
import { CheckCircle2, ShoppingCart, AlertCircle, Loader2, Plus, Trash2 } from "lucide-react";

const MAX_LINES = 20;

type Line = { key: number; productId: string; quantity: string };

const EMPTY_FORM = {
  customerName: "",
  phone: "",
  organization: "",
  deliveryLocation: "",
  notes: "",
};

const newKey = () => globalThis.crypto?.randomUUID?.() ?? undefined;

export default function OrderPage() {
  const [products, setProducts] = useState<Product[]>([]);
  const [productsFailed, setProductsFailed] = useState(false);
  const [form, setForm] = useState(EMPTY_FORM);
  const [lines, setLines] = useState<Line[]>([{ key: 1, productId: "", quantity: "1" }]);
  const [nextLineKey, setNextLineKey] = useState(2);
  // One key per filled-in form: a double click or a network retry resubmits the
  // same key, and the database returns the first request instead of a second one.
  const [submissionKey, setSubmissionKey] = useState<string | undefined>(newKey);
  const [phoneError, setPhoneError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isSuccess, setIsSuccess] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const rows = await getDb().products.listPublic();
        if (!cancelled) setProducts(rows.map(toPublicProduct));
      } catch {
        if (!cancelled) {
          setProducts([]);
          setProductsFailed(true);
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  const updateLine = (key: number, patch: Partial<Line>) =>
    setLines(current => current.map(l => (l.key === key ? { ...l, ...patch } : l)));

  const addLine = () => {
    if (lines.length >= MAX_LINES) return;
    setLines(current => [...current, { key: nextLineKey, productId: "", quantity: "1" }]);
    setNextLineKey(k => k + 1);
  };

  const removeLine = (key: number) => setLines(current => (current.length > 1 ? current.filter(l => l.key !== key) : current));

  /**
   * Calls submit_order_request(), which stores the request and all its lines
   * together - a request the team reviews, never an order. Stock, prices and
   * payments are only involved once staff convert it into an order.
   */
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (isSubmitting) return;
    setSubmitError(null);

    if (!isAcceptedRequestPhone(form.phone)) {
      setPhoneError(PHONE_HINT);
      return;
    }
    setPhoneError(null);

    const chosen = lines.filter(l => l.productId);
    if (chosen.length === 0) {
      setSubmitError("Please choose at least one product.");
      return;
    }

    setIsSubmitting(true);
    try {
      await getDb().orderRequests.submit({
        customerName: form.customerName.trim(),
        phone: form.phone.trim(),
        organization: form.organization.trim(),
        deliveryLocation: form.deliveryLocation.trim(),
        notes: form.notes.trim(),
        lines: chosen.map(l => ({ productId: l.productId, quantity: Math.max(1, Math.round(Number(l.quantity) || 1)) })),
        submissionKey,
      });

      setForm(EMPTY_FORM);
      setLines([{ key: nextLineKey, productId: "", quantity: "1" }]);
      setNextLineKey(k => k + 1);
      setIsSuccess(true);
    } catch (error) {
      setSubmitError(describeDbError(error));
    } finally {
      setIsSubmitting(false);
    }
  };

  const placeAnother = () => {
    setSubmissionKey(newKey());
    setIsSuccess(false);
  };

  if (isSuccess) {
    return (
      <div className="bg-slate-50 min-h-screen py-20">
        <div className="container mx-auto px-4 max-w-2xl text-center">
          <div className="bg-white p-10 rounded-2xl shadow-sm border border-slate-200">
            <div className="flex justify-center mb-6">
              <CheckCircle2 className="h-20 w-20 text-brand-green" />
            </div>
            <h1 className="font-heading text-3xl font-bold text-slate-900 mb-4">Order Request Received!</h1>
            <p className="text-slate-600 mb-8 text-lg">
              Thank you for your order. Our team will review your request and contact you via WhatsApp shortly to confirm payment and delivery details.
            </p>
            <Button onClick={placeAnother} variant="outline">
              Place Another Order
            </Button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-slate-50 min-h-screen py-12">
      <div className="container mx-auto px-4 max-w-3xl">
        <div className="text-center mb-10">
          <div className="inline-flex h-16 w-16 items-center justify-center rounded-full bg-blue-100 text-brand-blue mb-4">
            <ShoppingCart className="h-8 w-8" />
          </div>
          <h1 className="font-heading text-4xl font-bold text-slate-900 mb-4">Place an Order</h1>
          <p className="text-slate-600">Fill out the details below to request products. We will confirm availability and delivery with you.</p>
        </div>

        <Card className="border-none shadow-md">
          <CardContent className="p-6 md:p-8">
            <form className="space-y-6" onSubmit={handleSubmit}>
              {/* Customer Details */}
              <div className="space-y-4">
                <h3 className="font-heading text-lg font-semibold text-slate-900 border-b pb-2">1. Customer Details</h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Customer Name *</label>
                    <Input
                      required
                      maxLength={200}
                      placeholder="Full Name"
                      value={form.customerName}
                      onChange={e => setForm({ ...form, customerName: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Phone Number *</label>
                    <Input
                      required
                      type="tel"
                      maxLength={50}
                      placeholder="061 234 5678"
                      value={form.phone}
                      onChange={e => {
                        setForm({ ...form, phone: e.target.value });
                        if (phoneError) setPhoneError(null);
                      }}
                      onBlur={() => setPhoneError(form.phone && !isAcceptedRequestPhone(form.phone) ? PHONE_HINT : null)}
                      aria-invalid={Boolean(phoneError)}
                    />
                    {phoneError && <p className="text-xs font-medium text-red-600">{phoneError}</p>}
                  </div>
                  <div className="space-y-2 md:col-span-2">
                    <label className="text-sm font-medium">Arena / Company Name (Optional)</label>
                    <Input
                      maxLength={200}
                      placeholder="If ordering for an organization"
                      value={form.organization}
                      onChange={e => setForm({ ...form, organization: e.target.value })}
                    />
                  </div>
                </div>
              </div>

              {/* Product Details */}
              <div className="space-y-4">
                <h3 className="font-heading text-lg font-semibold text-slate-900 border-b pb-2">2. Product Selection</h3>
                {productsFailed && (
                  <p className="text-sm text-red-600">Products could not be loaded. Please refresh the page or contact us on WhatsApp.</p>
                )}
                <div className="space-y-3">
                  {lines.map((line, index) => {
                    const takenElsewhere = new Set(lines.filter(l => l.key !== line.key).map(l => l.productId));
                    return (
                      <div key={line.key} className="grid grid-cols-[1fr_6rem_auto] items-end gap-3">
                        <div className="space-y-2 min-w-0">
                          {index === 0 && <label className="text-sm font-medium">Product *</label>}
                          <select
                            required={index === 0}
                            aria-label={`Product ${index + 1}`}
                            className="flex h-10 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green"
                            value={line.productId}
                            onChange={e => updateLine(line.key, { productId: e.target.value })}
                          >
                            <option value="">{products.length ? "Select a product..." : productsFailed ? "Products unavailable" : "Loading products..."}</option>
                            {products.map(p => (
                              <option key={p.id} value={p.id} disabled={takenElsewhere.has(p.id)}>{p.name} - ${p.price}</option>
                            ))}
                          </select>
                        </div>
                        <div className="space-y-2">
                          {index === 0 && <label className="text-sm font-medium">Quantity *</label>}
                          <Input
                            required
                            type="number"
                            min="1"
                            max="100000"
                            step="1"
                            aria-label={`Quantity ${index + 1}`}
                            value={line.quantity}
                            onChange={e => updateLine(line.key, { quantity: e.target.value })}
                          />
                        </div>
                        <button
                          type="button"
                          onClick={() => removeLine(line.key)}
                          disabled={lines.length === 1}
                          aria-label={`Remove product ${index + 1}`}
                          className="mb-0.5 flex h-10 w-10 items-center justify-center rounded-md text-slate-400 hover:bg-red-50 hover:text-red-600 disabled:opacity-30 disabled:hover:bg-transparent"
                        >
                          <Trash2 className="h-4 w-4" />
                        </button>
                      </div>
                    );
                  })}
                </div>
                {lines.length < MAX_LINES && (
                  <Button type="button" variant="outline" size="sm" onClick={addLine}>
                    <Plus className="mr-1.5 h-4 w-4" /> Add another product
                  </Button>
                )}
              </div>

              {/* Delivery Details */}
              <div className="space-y-4">
                <h3 className="font-heading text-lg font-semibold text-slate-900 border-b pb-2">3. Delivery Information</h3>
                <div className="space-y-4">
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Delivery Location *</label>
                    <Input
                      required
                      maxLength={500}
                      placeholder="Neighborhood, Street, or Landmark"
                      value={form.deliveryLocation}
                      onChange={e => setForm({ ...form, deliveryLocation: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Additional Notes</label>
                    <textarea
                      maxLength={2000}
                      className="flex min-h-[80px] w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green"
                      placeholder="Any specific instructions..."
                      value={form.notes}
                      onChange={e => setForm({ ...form, notes: e.target.value })}
                    />
                  </div>
                </div>
              </div>

              {submitError && (
                <div className="flex items-start gap-3 rounded-lg border border-red-100 bg-red-50 p-3">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-red-600" />
                  <p className="text-sm font-medium text-red-700">{submitError}</p>
                </div>
              )}

              <Button type="submit" size="lg" className="w-full" disabled={isSubmitting}>
                {isSubmitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                {isSubmitting ? "Submitting Order..." : "Submit Order Request"}
              </Button>
            </form>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
