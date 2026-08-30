"use client";

import Image from "next/image";
import { CheckCircle, Factory, TrendingUp, Truck, ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";

export default function WholesalePage() {
  return (
    <div className="bg-slate-50 min-h-screen">
      {/* Header */}
      <div className="bg-brand-blue-dark py-20 text-white">
        <div className="container mx-auto px-4 md:px-6 text-center max-w-3xl">
          <h1 className="font-heading text-4xl md:text-5xl lg:text-6xl font-bold mb-6">
            Arena & Wholesale <span className="text-brand-green">Partnerships</span>
          </h1>
          <p className="text-lg text-slate-300 md:text-xl">
            We supply Mogadishu&apos;s top arenas, academies, and retailers with reliable, high-quality sports equipment at unbeatable wholesale rates.
          </p>
        </div>
      </div>

      <div className="container mx-auto px-4 md:px-6 py-16">
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 items-center mb-24">
          <div>
            <h2 className="font-heading text-3xl font-bold text-slate-900 mb-6">Why Partner With EFZ?</h2>
            <div className="space-y-6">
              {[
                { icon: TrendingUp, title: "Wholesale Pricing", desc: "Enjoy significant discounts on bulk orders to maximize your profit margins or reduce operational costs." },
                { icon: ShieldCheck, title: "Guaranteed Quality", desc: "Our balls are tested on local surfaces. If a batch fails prematurely, we replace it under our partner warranty." },
                { icon: Truck, title: "Priority Delivery", desc: "Partners get fast-tracked, free delivery within Mogadishu for monthly supply drops." },
                { icon: Factory, title: "Custom Branding (Coming Soon)", desc: "Option to co-brand equipment for large academies and tournaments." }
              ].map((benefit, idx) => (
                <div key={idx} className="flex">
                  <div className="flex-shrink-0 mt-1">
                    <div className="w-10 h-10 rounded-full bg-green-100 flex items-center justify-center text-brand-green">
                      <benefit.icon className="h-5 w-5" />
                    </div>
                  </div>
                  <div className="ml-4">
                    <h3 className="text-xl font-semibold text-slate-900 mb-1">{benefit.title}</h3>
                    <p className="text-slate-600 leading-relaxed">{benefit.desc}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div className="relative aspect-square md:aspect-[4/3] rounded-2xl overflow-hidden shadow-xl border border-slate-200">
            <Image
              src="https://images.unsplash.com/photo-1579952363873-27f3bade9f55?auto=format&fit=crop&q=80&w=1200"
              alt="Wholesale footballs"
              fill
              sizes="(max-width: 768px) 100vw, 50vw"
              className="object-cover"
            />
          </div>
        </div>

        {/* Inquiry Form */}
        <div className="max-w-3xl mx-auto">
          <Card className="shadow-lg border-none ring-1 ring-slate-200/50">
            <div className="bg-brand-blue rounded-t-xl p-6 text-white text-center">
              <h2 className="font-heading text-2xl font-bold">Request a Wholesale Quote</h2>
              <p className="text-slate-300 text-sm mt-2">Fill out the form below and our B2B team will contact you within 24 hours.</p>
            </div>
            <CardContent className="p-8">
              <form className="space-y-6" onSubmit={(e) => e.preventDefault()}>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <div className="space-y-2">
                    <label className="text-sm font-medium text-slate-900">Organization / Arena Name *</label>
                    <Input placeholder="E.g., Mogadishu Sports Arena" required />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium text-slate-900">Contact Person *</label>
                    <Input placeholder="Full Name" required />
                  </div>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <div className="space-y-2">
                    <label className="text-sm font-medium text-slate-900">Phone Number *</label>
                    <Input placeholder="E.g., +252 61..." required />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium text-slate-900">Business Type</label>
                    <select className="flex h-10 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green">
                      <option>Futsal Arena</option>
                      <option>Football Academy/School</option>
                      <option>Sports Retailer</option>
                      <option>Tournament Organizer</option>
                      <option>Other</option>
                    </select>
                  </div>
                </div>

                <div className="space-y-2">
                  <label className="text-sm font-medium text-slate-900">What products are you interested in?</label>
                  <textarea 
                    className="flex min-h-[100px] w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green" 
                    placeholder="E.g., We need 50 futsal balls per month..."
                  />
                </div>

                <Button type="submit" size="lg" className="w-full">Submit Inquiry</Button>
              </form>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}
