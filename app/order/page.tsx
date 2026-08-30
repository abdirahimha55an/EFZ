"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { MOCK_PRODUCTS } from "@/lib/data";
import { CheckCircle2, ShoppingCart } from "lucide-react";

export default function OrderPage() {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isSuccess, setIsSuccess] = useState(false);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setIsSubmitting(true);
    
    // Simulate API call to Supabase
    setTimeout(() => {
      setIsSubmitting(false);
      setIsSuccess(true);
    }, 1500);
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
                    <Input required placeholder="Full Name" />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Phone Number *</label>
                    <Input required placeholder="+252..." />
                  </div>
                  <div className="space-y-2 md:col-span-2">
                    <label className="text-sm font-medium">Arena / Company Name (Optional)</label>
                    <Input placeholder="If ordering for an organization" />
                  </div>
                </div>
              </div>

              {/* Product Details */}
              <div className="space-y-4">
                <h3 className="font-heading text-lg font-semibold text-slate-900 border-b pb-2">2. Product Selection</h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Product *</label>
                    <select required className="flex h-10 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green">
                      <option value="">Select a product...</option>
                      {MOCK_PRODUCTS.map(p => (
                        <option key={p.id} value={p.id}>{p.name} - ${p.price}</option>
                      ))}
                    </select>
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Quantity *</label>
                    <Input required type="number" min="1" placeholder="1" defaultValue="1" />
                  </div>
                </div>
              </div>

              {/* Delivery Details */}
              <div className="space-y-4">
                <h3 className="font-heading text-lg font-semibold text-slate-900 border-b pb-2">3. Delivery Information</h3>
                <div className="space-y-4">
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Delivery Location *</label>
                    <Input required placeholder="Neighborhood, Street, or Landmark" />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium">Additional Notes</label>
                    <textarea 
                      className="flex min-h-[80px] w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green" 
                      placeholder="Any specific instructions..."
                    />
                  </div>
                </div>
              </div>

              <Button type="submit" size="lg" className="w-full" disabled={isSubmitting}>
                {isSubmitting ? "Submitting Order..." : "Submit Order Request"}
              </Button>
            </form>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
