"use client";

import Link from "next/link";
import { CheckCircle, MapPin, Package, ShieldCheck, TrendingUp, Trophy, Truck, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { usePublicSettings } from "@/lib/settings";

/**
 * Every statement here is one EFZ already publishes elsewhere on this site (Home, Wholesale, Contact, the footer and the
 * wholesale form). Nothing is invented: no founding year, team, client names, figures or superlatives. Commercial promises
 * that belong to the Wholesale page (discounts, warranty, free delivery) are linked to, not repeated, so they live in one place.
 * Styling uses the same utility classes as the other public pages, so the admin-selected dark theme (a `dark` class on <html>) remaps it too.
 */
const VALUES = [
  { icon: Trophy, title: "Quality", desc: "Products selected for real game conditions. Tested on local surfaces." },
  { icon: Truck, title: "Consistency", desc: "Reliable supply for arenas and teams. Dependable partnerships." },
  { icon: TrendingUp, title: "Value", desc: "Competitive pricing without compromising quality." },
  { icon: Users, title: "Partnership", desc: "We build long-term relationships with arenas and football communities." },
];

const ARENA_POINTS = [
  "Wholesale pricing on bulk orders",
  "Regular monthly supply schedule",
  "Arena-focused service and support",
  "Bulk order flexibility",
  "Dedicated account support",
];

const STEPS = [
  { num: "01", title: "Choose", desc: "Select the products your arena, team or game needs." },
  { num: "02", title: "Order", desc: "Place your order directly with EFZ via WhatsApp or the online order form." },
  { num: "03", title: "Play", desc: "Receive your products and get back to the game." },
];

const CUSTOMER_TYPES = ["Futsal arenas", "Football academies and schools", "Sports retailers", "Tournament organizers"];

export default function AboutPage() {
  const settings = usePublicSettings();
  const name = settings.businessName;

  return (
    <div className="min-h-screen bg-slate-50">
      {/* Header */}
      <div className="bg-brand-blue-dark py-20 text-white">
        <div className="container mx-auto max-w-3xl px-4 text-center md:px-6">
          <h1 className="mb-6 font-heading text-4xl font-bold md:text-5xl lg:text-6xl">
            About <span className="text-brand-green">{name}</span>
          </h1>
          <p className="text-lg text-slate-300 md:text-xl">
            {name} supplies footballs and futsal balls in Mogadishu, Somalia, for players, arenas, academies and teams.
          </p>
        </div>
      </div>

      <div className="container mx-auto px-4 py-16 md:px-6">
        {/* Who we are */}
        <section className="mx-auto mb-20 max-w-3xl" aria-labelledby="about-more-than-a-ball">
          <h2 id="about-more-than-a-ball" className="mb-6 font-heading text-3xl font-bold text-slate-900 md:text-4xl">More than a ball</h2>
          <p className="mb-4 text-lg leading-relaxed text-slate-600">
            {name} exists to support the game at every level, from individual players to the arenas where football communities come together.
            We believe in quality, reliability, and building partnerships that last.
          </p>
          <p className="text-lg leading-relaxed text-slate-500">
            Whether you are running an arena, training the next generation, or organizing tournaments, {name} is your trusted partner for football products.
          </p>
        </section>

        {/* What we supply */}
        <section className="mx-auto mb-20 grid max-w-5xl grid-cols-1 gap-6 md:grid-cols-2" aria-labelledby="about-what-we-supply">
          <Card className="border-none shadow-sm">
            <CardContent className="p-6">
              <Package className="mb-4 h-7 w-7 text-brand-green" aria-hidden="true" />
              <h2 id="about-what-we-supply" className="mb-2 font-heading text-2xl font-semibold text-slate-900">What we supply</h2>
              <p className="mb-4 text-slate-600">
                Footballs and futsal balls: reliable products for players, arenas and teams, handpicked for performance and durability and built for demanding play.
                The current range and prices are on the Products page.
              </p>
              <Link href="/products" className="text-sm font-medium text-brand-green hover:underline">View the product range</Link>
            </CardContent>
          </Card>

          <Card className="border-none shadow-sm">
            <CardContent className="p-6">
              <Users className="mb-4 h-7 w-7 text-brand-green" aria-hidden="true" />
              <h2 className="mb-2 font-heading text-2xl font-semibold text-slate-900">Who we work with</h2>
              <ul className="list-disc space-y-1 pl-5 text-slate-600">
                {CUSTOMER_TYPES.map((t) => (
                  <li key={t}>{t}</li>
                ))}
              </ul>
            </CardContent>
          </Card>
        </section>

        {/* Arena supply */}
        <section className="mx-auto mb-20 max-w-5xl rounded-2xl bg-brand-blue-dark p-8 text-white md:p-12" aria-labelledby="about-arenas">
          <span className="text-xs font-bold uppercase tracking-widest text-brand-green">For arenas</span>
          <h2 id="about-arenas" className="mb-4 mt-2 font-heading text-3xl font-bold md:text-4xl">Built for arenas</h2>
          <p className="mb-8 max-w-2xl text-lg leading-relaxed text-slate-300">
            Keep your arena ready for every game with reliable football products and direct supply from {name}.
          </p>
          <ul className="mb-8 grid gap-3 sm:grid-cols-2">
            {ARENA_POINTS.map((p) => (
              <li key={p} className="flex items-start gap-3">
                <CheckCircle className="mt-0.5 h-5 w-5 shrink-0 text-brand-green" aria-hidden="true" />
                <span className="text-slate-100">{p}</span>
              </li>
            ))}
          </ul>
          <div className="flex flex-col gap-3 sm:flex-row">
            <Link href="/wholesale">
              <Button size="lg" className="w-full bg-brand-green font-semibold text-white hover:bg-brand-green/90 sm:w-auto">Arena and wholesale partnerships</Button>
            </Link>
          </div>
        </section>

        {/* Why EFZ */}
        <section className="mx-auto mb-20 max-w-5xl" aria-labelledby="about-why">
          <h2 id="about-why" className="mb-8 text-center font-heading text-3xl font-bold text-slate-900 md:text-4xl">Why {name}?</h2>
          <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-4">
            {VALUES.map((v) => (
              <Card key={v.title} className="border-none shadow-sm">
                <CardContent className="p-6">
                  <v.icon className="mb-4 h-7 w-7 text-brand-green" aria-hidden="true" />
                  <h3 className="mb-2 font-heading text-xl font-semibold text-slate-900">{v.title}</h3>
                  <p className="text-slate-600">{v.desc}</p>
                </CardContent>
              </Card>
            ))}
          </div>
        </section>

        {/* How it works */}
        <section className="mx-auto mb-20 max-w-5xl" aria-labelledby="about-how">
          <h2 id="about-how" className="mb-8 text-center font-heading text-3xl font-bold text-slate-900 md:text-4xl">How it works</h2>
          <div className="grid grid-cols-1 gap-6 md:grid-cols-3">
            {STEPS.map((s) => (
              <Card key={s.num} className="border-none shadow-sm">
                <CardContent className="p-6">
                  <span className="font-heading text-3xl font-bold text-brand-green">{s.num}</span>
                  <h3 className="mb-2 mt-2 font-heading text-xl font-semibold text-slate-900">{s.title}</h3>
                  <p className="text-slate-600">{s.desc}</p>
                </CardContent>
              </Card>
            ))}
          </div>
        </section>

        {/* Find us */}
        <section className="mx-auto mb-12 max-w-5xl" aria-labelledby="about-find-us">
          <Card className="border-none shadow-sm">
            <CardContent className="flex flex-col gap-6 p-6 md:flex-row md:items-center md:justify-between md:p-8">
              <div className="flex items-start gap-4">
                <MapPin className="mt-1 h-7 w-7 shrink-0 text-brand-green" aria-hidden="true" />
                <div>
                  <h2 id="about-find-us" className="mb-1 font-heading text-2xl font-semibold text-slate-900">Where to find us</h2>
                  <p className="text-slate-600">
                    Maka Al Mukarama Road
                    <br />
                    Mogadishu, Somalia
                  </p>
                  <Link href="/contact" className="mt-2 inline-block text-sm font-medium text-brand-green hover:underline">Contact and opening hours</Link>
                </div>
              </div>
              <ShieldCheck className="hidden h-12 w-12 text-brand-green/40 md:block" aria-hidden="true" />
            </CardContent>
          </Card>
        </section>

        {/* Next steps */}
        <div className="mx-auto flex max-w-5xl flex-col gap-3 sm:flex-row sm:justify-center">
          <Link href="/products">
            <Button size="lg" className="w-full bg-brand-green font-semibold text-white hover:bg-brand-green/90 sm:w-auto">View Products</Button>
          </Link>
          <Link href="/order">
            <Button size="lg" variant="outline" className="w-full font-semibold sm:w-auto">Request an order</Button>
          </Link>
          <Link href="/wholesale">
            <Button size="lg" variant="outline" className="w-full font-semibold sm:w-auto">Wholesale enquiries</Button>
          </Link>
        </div>
      </div>
    </div>
  );
}
