"use client";

import Link from "next/link";
import { MapPin, Phone, Mail } from "lucide-react";
import { usePublicSettings } from "@/lib/settings";

export function Footer() {
  // The spinner this used to show has gone: the defaults are real content, so
  // the footer can render immediately and update in place.
  const settings = usePublicSettings();

  return (
    <footer className="bg-brand-blue-dark text-slate-300">
      <div className="container mx-auto px-4 py-12 md:px-6 lg:py-16">
        <div className="grid grid-cols-1 gap-8 md:grid-cols-4">
          {/* Brand */}
          <div className="space-y-4">
            <Link href="/" className="inline-block">
              <span className="font-heading text-2xl font-bold tracking-tight text-white">
                {settings.businessName}<span className="text-brand-green">.</span>
              </span>
            </Link>
            <p className="text-sm leading-relaxed">
              {settings.businessName} is Somalia&apos;s premier supplier of high-quality footballs and futsal balls for arenas, schools, and professional organizers.
            </p>
          </div>

          {/* Quick Links */}
          <div>
            <h3 className="mb-4 font-heading text-lg font-semibold text-white">Quick Links</h3>
            <ul className="space-y-2 text-sm">
              <li>
                <Link href="/products" className="hover:text-white transition-colors">Products</Link>
              </li>
              <li>
                <Link href="/wholesale" className="hover:text-white transition-colors">Wholesale & Arenas</Link>
              </li>
              <li>
                <Link href="/about" className="hover:text-white transition-colors">About Us</Link>
              </li>
              <li>
                <Link href="/contact" className="hover:text-white transition-colors">Contact</Link>
              </li>
            </ul>
          </div>

          {/* Categories */}
          <div>
            <h3 className="mb-4 font-heading text-lg font-semibold text-white">Categories</h3>
            <ul className="space-y-2 text-sm">
              <li>
                <Link href="/products" className="hover:text-white transition-colors">All Products</Link>
              </li>
              <li>
                <Link href="/wholesale" className="hover:text-white transition-colors">Bulk Orders</Link>
              </li>
            </ul>
          </div>

          {/* Contact */}
          <div>
            <h3 className="mb-4 font-heading text-lg font-semibold text-white">Contact Us</h3>
            <ul className="space-y-4 text-sm">
              <li className="flex items-start gap-3">
                <MapPin className="h-5 w-5 text-brand-green shrink-0" />
                <span>Maka Al Mukarama Road<br />Mogadishu, Somalia</span>
              </li>
              {settings.whatsappNumber.trim() && (
                <li className="flex items-center gap-3">
                  <Phone className="h-5 w-5 text-brand-green shrink-0" />
                  <span>{settings.whatsappNumber}</span>
                </li>
              )}
              <li className="flex items-center gap-3">
                <Mail className="h-5 w-5 text-brand-green shrink-0" />
                <span>{settings.contactEmail}</span>
              </li>
            </ul>
          </div>
        </div>

        <div className="mt-12 border-t border-slate-700 pt-8 text-center text-sm text-slate-400">
          <p>&copy; {new Date().getFullYear()} {settings.businessName}. All rights reserved.</p>
        </div>
      </div>
    </footer>
  );
}
