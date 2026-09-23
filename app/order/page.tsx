"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { Product } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { toPublicProduct } from "@/lib/supabase/mappers";
import { CheckCircle2, ShoppingCart, AlertCircle, Loader2 } from "lucide-react";

const EMPTY_FORM = {
  customerName: "",
  phone: "",
  organization: "",
  productId: "",
  quantity: "1",
  deliveryLocation: "",
  notes: "",
};

export default function OrderPage() {
  const [products, setProducts] = useState<Product[]>([]);
  const [form, setForm] = useState(EMPTY_FORM);
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
        if (!cancelled) setProducts([]);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  /**
   * Writes to `order_requests`, not `orders`.
   *
   * A stranger on the internet must not be able to create a real order: that
   * would deduct stock and book revenue. This is a request the team reviews,
   * then converts with convert_order_request() once they have confirmed it.
   * The insert policy is the only write anon is granted anywhere.
   */
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsSubmitting(true);
    setSubmitError(null);

    try {
      const product = products.find(p => p.id === form.productId);

      await getDb().orderRequests.submit({
        customerName: form.customerName.trim(),
        phone: form.phone.trim(),
        organization: form.organization.trim(),
        productId: form.productId || undefined,
        productName: product?.name ?? "",
        quantity: Math.max(1, Number(form.quantity) || 1),
        deliveryLocation: form.deliveryLocation.trim(),
        notes: form.notes.trim(),
      });

      setForm(EMPTY_FORM);
      setIsSuccess(true);
    } catch (error) {
      setSubmitError(describeDbError(error));
    } finally {
      setIsSubmitting(false);
    }
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
            <Button onClick={() => setIsSuccess(false)} variant="outline">
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
                      placeholder="Full Name"
                      value={form.customerName}
                      onChange={e => setForm({ ...form, customerName: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Phone Number *</label>
                    <Input
                      required
                      placeholder="+252..."
                      value={form.phone}
                      onChange={e => setForm({ ...form, phone: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2 md:col-span-2">
                    <label className="text-sm font-medium">Arena / Company Name (Optional)</label>
                    <Input
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
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Product *</label>
                    <select
                      required
                      className="flex h-10 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green"
                      value={form.productId}
                      onChange={e => setForm({ ...form, productId: e.target.value })}
                    >
                      <option value="">{products.length ? "Select a product..." : "Loading products..."}</option>
                      {products.map(p => (
                        <option key={p.id} value={p.id}>{p.name} - ${p.price}</option>
                      ))}
                    </select>
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Quantity *</label>
                    <Input
                      required
                      type="number"
                      min="1"
                      placeholder="1"
                      value={form.quantity}
                      onChange={e => setForm({ ...form, quantity: e.target.value })}
                    />
                  </div>
                </div>
              </div>

              {/* Delivery Details */}
              <div className="space-y-4">
                <h3 className="font-heading text-lg font-semibold text-slate-900 border-b pb-2">3. Delivery Information</h3>
                <div className="space-y-4">
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Delivery Location *</label>
                    <Input
                      required
                      placeholder="Neighborhood, Street, or Landmark"
                      value={form.deliveryLocation}
                      onChange={e => setForm({ ...form, deliveryLocation: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Additional Notes</label>
                    <textarea
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
