"use client";

import { MapPin, Phone, Mail, Clock } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { getWhatsAppUrl, EFZ_WHATSAPP_NUMBER } from "@/lib/utils";
import { storage } from "@/lib/storage";
import Link from "next/link";
import { useEffect, useState } from "react";

export default function ContactPage() {
  const [whatsappNumber, setWhatsappNumber] = useState(EFZ_WHATSAPP_NUMBER);

  useEffect(() => {
    const settings = storage.getSettings();
    const cleanNumber = settings.whatsappNumber.replace(/\D/g, '');
    setWhatsappNumber(cleanNumber || EFZ_WHATSAPP_NUMBER);
  }, []);

  const waUrl = getWhatsAppUrl(whatsappNumber, "Hello EFZ, I have a general inquiry.");

  return (
    <div className="bg-slate-50 min-h-screen py-12">
      <div className="container mx-auto px-4 md:px-6">
        <div className="text-center max-w-3xl mx-auto mb-16">
          <h1 className="font-heading text-4xl font-bold text-slate-900 md:text-5xl mb-4">Get in Touch</h1>
          <p className="text-lg text-slate-600">Have a question about our products, want to become a partner, or need support? We&apos;re here to help.</p>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 max-w-6xl mx-auto">
          {/* Contact Information */}
          <div className="lg:col-span-1 space-y-6">
            <Card className="border-none shadow-sm">
              <CardContent className="p-6">
                <h3 className="font-heading text-xl font-semibold mb-6">Contact Information</h3>
                <div className="space-y-6">
                  <div className="flex items-start">
                    <MapPin className="h-6 w-6 text-brand-green mt-1 shrink-0" />
                    <div className="ml-4">
                      <h4 className="font-medium text-slate-900">Our Office</h4>
                      <p className="text-slate-600 mt-1">Maka Al Mukarama Road<br />Mogadishu, Somalia</p>
                    </div>
                  </div>
                  <div className="flex items-start">
                    <Phone className="h-6 w-6 text-brand-green mt-1 shrink-0" />
                    <div className="ml-4">
                      <h4 className="font-medium text-slate-900">Phone & WhatsApp</h4>
                      <p className="text-slate-600 mt-1">{whatsappNumber}</p>
                      <Link href={waUrl} target="_blank" rel="noopener noreferrer" className="text-brand-green text-sm font-medium hover:underline mt-1 inline-block">
                        Chat on WhatsApp
                      </Link>
                    </div>
                  </div>
                  <div className="flex items-start">
                    <Mail className="h-6 w-6 text-brand-green mt-1 shrink-0" />
                    <div className="ml-4">
                      <h4 className="font-medium text-slate-900">Email</h4>
                      <p className="text-slate-600 mt-1">info@efz.so</p>
                      <p className="text-slate-600">sales@efz.so</p>
                    </div>
                  </div>
                  <div className="flex items-start">
                    <Clock className="h-6 w-6 text-brand-green mt-1 shrink-0" />
                    <div className="ml-4">
                      <h4 className="font-medium text-slate-900">Business Hours</h4>
                      <p className="text-slate-600 mt-1">Saturday - Thursday<br />8:00 AM - 6:00 PM</p>
                    </div>
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>

          {/* Contact Form */}
          <div className="lg:col-span-2">
            <Card className="border-none shadow-sm">
              <CardContent className="p-6 md:p-8">
                <h3 className="font-heading text-2xl font-semibold mb-6">Send us a Message</h3>
                <form className="space-y-6" onSubmit={(e) => e.preventDefault()}>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <div className="space-y-2">
                      <label className="text-sm font-medium text-slate-900">Full Name *</label>
                      <Input placeholder="John Doe" required />
                    </div>
                    <div className="space-y-2">
                      <label className="text-sm font-medium text-slate-900">Email Address</label>
                      <Input type="email" placeholder="john@example.com" />
                    </div>
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium text-slate-900">Subject *</label>
                    <Input placeholder="How can we help you?" required />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-medium text-slate-900">Message *</label>
                    <textarea 
                      className="flex min-h-[150px] w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-green" 
                      placeholder="Your message here..."
                      required
                    />
                  </div>
                  <Button type="submit" size="lg" className="w-full md:w-auto">Send Message</Button>
                </form>
              </CardContent>
            </Card>
          </div>
        </div>
      </div>
    </div>
  );
}
