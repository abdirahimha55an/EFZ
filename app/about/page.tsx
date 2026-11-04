"use client";

import Link from "next/link";
import { MapPin, Package, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { usePublicSettings } from "@/lib/settings";

/**
 * Only facts the business has already published on this site are stated here:
 * the name, the Mogadishu address, that EFZ supplies footballs and futsal balls,
 * and the kinds of customer the wholesale form is built for. No history, team,
 * numbers or superlatives: add those only when the owner supplies and confirms them.
 */
const CUSTOMER_TYPES = ["Futsal arenas", "Football academies and schools", "Sports retailers", "Tournament organizers"];

export default function AboutPage() {
  const settings = usePublicSettings();

  return (
    <div className="min-h-screen bg-slate-50 py-12">
      <div className="container mx-auto px-4 md:px-6">
        <div className="mx-auto mb-12 max-w-3xl text-center">
          <h1 className="mb-4 font-heading text-4xl font-bold text-slate-900 md:text-5xl">About {settings.businessName}</h1>
          <p className="text-lg text-slate-600">
            {settings.businessName} supplies footballs and futsal balls in Mogadishu, Somalia.
          </p>
        </div>

        <div className="mx-auto grid max-w-5xl grid-cols-1 gap-6 md:grid-cols-3">
          <Card className="border-none shadow-sm">
            <CardContent className="p-6">
              <Package className="mb-4 h-7 w-7 text-brand-green" aria-hidden="true" />
              <h2 className="mb-2 font-heading text-xl font-semibold text-slate-900">What we supply</h2>
              <p className="text-slate-600">Footballs and futsal balls. See the current range and prices on the Products page.</p>
            </CardContent>
          </Card>

          <Card className="border-none shadow-sm">
            <CardContent className="p-6">
              <Users className="mb-4 h-7 w-7 text-brand-green" aria-hidden="true" />
              <h2 className="mb-2 font-heading text-xl font-semibold text-slate-900">Who we work with</h2>
              <ul className="list-disc space-y-1 pl-5 text-slate-600">
                {CUSTOMER_TYPES.map((t) => (
                  <li key={t}>{t}</li>
                ))}
              </ul>
            </CardContent>
          </Card>

          <Card className="border-none shadow-sm">
            <CardContent className="p-6">
              <MapPin className="mb-4 h-7 w-7 text-brand-green" aria-hidden="true" />
              <h2 className="mb-2 font-heading text-xl font-semibold text-slate-900">Where to find us</h2>
              <p className="text-slate-600">
                Maka Al Mukarama Road
                <br />
                Mogadishu, Somalia
              </p>
              <Link href="/contact" className="mt-3 inline-block text-sm font-medium text-brand-green hover:underline">
                Contact and opening hours
              </Link>
            </CardContent>
          </Card>
        </div>

        <div className="mx-auto mt-12 flex max-w-5xl flex-col gap-3 sm:flex-row sm:justify-center">
          <Link href="/products">
            <Button size="lg" className="w-full bg-brand-green font-semibold text-white hover:bg-brand-green/90 sm:w-auto">
              View Products
            </Button>
          </Link>
          <Link href="/wholesale">
            <Button size="lg" variant="outline" className="w-full font-semibold sm:w-auto">
              Wholesale enquiries
            </Button>
          </Link>
        </div>
      </div>
    </div>
  );
}
