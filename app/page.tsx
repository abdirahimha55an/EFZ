"use client";

import Image from "next/image";
import Link from "next/link";
import { motion } from "framer-motion";
import { ArrowRight, CheckCircle2, Shield, Zap, TrendingUp } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { MOCK_PRODUCTS, MOCK_TESTIMONIALS, Product } from "@/lib/data";
import { storage } from "@/lib/storage";
import { useEffect, useState } from "react";

const fadeIn = {
  hidden: { opacity: 0, y: 20 },
  visible: { opacity: 1, y: 0, transition: { duration: 0.6 } }
};

const staggerContainer = {
  hidden: { opacity: 0 },
  visible: {
    opacity: 1,
    transition: {
      staggerChildren: 0.2
    }
  }
};

export default function Home() {
  const [isMounted, setIsMounted] = useState(false);
  const [products, setProducts] = useState<Product[]>([]);

  useEffect(() => {
    setIsMounted(true);
    setProducts(storage.getProducts());
  }, []);

  const featuredProducts = products.slice(0, 3);

  if (!isMounted) return null;

  return (
    <div className="flex flex-col">
      {/* Hero Section */}
      <section className="relative overflow-hidden bg-brand-blue-dark py-20 lg:py-32">
        <div className="absolute inset-0 z-0">
          <Image
            src="https://images.unsplash.com/photo-1579952363873-27f3bade9f55?auto=format&fit=crop&q=80&w=2000"
            alt="Football field at night"
            fill
            sizes="100vw"
            className="object-cover opacity-20"
            priority
          />
          <div className="absolute inset-0 bg-gradient-to-r from-brand-blue-dark via-brand-blue-dark/80 to-transparent" />
        </div>

        <div className="container relative z-10 mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            animate="visible"
            variants={staggerContainer}
            className="max-w-3xl"
          >
            <motion.h1 variants={fadeIn} className="font-heading text-4xl font-bold tracking-tight text-white sm:text-5xl lg:text-7xl">
              Precision in <span className="text-brand-green">Every Touch</span>.
            </motion.h1>
            <motion.p variants={fadeIn} className="mt-6 text-lg text-slate-300 sm:text-xl">
              Equip your arena, academy, or tournament with Somalia&apos;s finest footballs and futsal balls. Built for durability, engineered for performance.
            </motion.p>
            <motion.div variants={fadeIn} className="mt-10 flex flex-col gap-4 sm:flex-row">
              <Link href="/products">
                <Button size="lg" className="w-full sm:w-auto">
                  View Products <ArrowRight className="ml-2 h-5 w-5" />
                </Button>
              </Link>
              <Link href="/wholesale">
                <Button size="lg" variant="outline" className="w-full sm:w-auto border-slate-300 text-slate-100 hover:bg-slate-100 hover:text-brand-blue-dark">
                  Arena Partnerships
                </Button>
              </Link>
            </motion.div>
          </motion.div>
        </div>
      </section>

      {/* Featured Products */}
      <section className="py-20 bg-background">
        <div className="container mx-auto px-4 md:px-6">
          <div className="flex flex-col items-center justify-between gap-4 md:flex-row md:items-end mb-12">
            <div>
              <h2 className="font-heading text-3xl font-bold text-slate-900 md:text-4xl">Featured Equipment</h2>
              <p className="mt-2 text-slate-600">Our most popular balls for professional and training use.</p>
            </div>
            <Link href="/products">
              <Button variant="ghost" className="hidden md:flex">
                View all <ArrowRight className="ml-2 h-4 w-4" />
              </Button>
            </Link>
          </div>

          <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
            {featuredProducts.map((product) => (
              <Card key={product.id} className="overflow-hidden group flex flex-col">
                <div className="relative aspect-square overflow-hidden bg-slate-100">
                  <Image
                    src={product.imageUrl}
                    alt={product.name}
                    fill
                    sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 33vw"
                    className="object-cover transition-transform duration-500 group-hover:scale-105"
                    unoptimized={product.imageUrl?.startsWith('data:')}
                  />
                  <div className="absolute top-4 left-4 bg-brand-blue text-white text-xs font-bold px-3 py-1 rounded-full uppercase tracking-wide">
                    {product.category}
                  </div>
                </div>
                <CardContent className="p-6 flex flex-col flex-grow">
                  <h3 className="font-heading text-xl font-semibold mb-2">{product.name}</h3>
                  <p className="text-slate-600 text-sm mb-4 line-clamp-2">{product.description}</p>
                  
                  <div className="mt-auto pt-4 border-t border-slate-100 flex items-center justify-between">
                    <span className="font-bold text-lg">${product.price.toFixed(2)}</span>
                    <Link href={`/products`}>
                      <Button size="sm">Details</Button>
                    </Link>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
          <div className="mt-8 text-center md:hidden">
            <Link href="/products">
              <Button variant="outline" className="w-full">View all products</Button>
            </Link>
          </div>
        </div>
      </section>

      {/* Why Choose Us */}
      <section className="py-20 bg-slate-50">
        <div className="container mx-auto px-4 md:px-6">
          <div className="text-center mb-16">
            <h2 className="font-heading text-3xl font-bold text-slate-900 md:text-4xl">Why Choose EFZ?</h2>
            <p className="mt-4 text-slate-600 max-w-2xl mx-auto">We understand the demands of the game in Somalia. Our products are selected for maximum durability on all local surfaces.</p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            {[
              { icon: Shield, title: "Unmatched Durability", desc: "Engineered to withstand tough conditions on hard courts and artificial turf." },
              { icon: Zap, title: "Premium Performance", desc: "Perfect weight, low bounce for futsal, and consistent flight for footballs." },
              { icon: TrendingUp, title: "Wholesale Value", desc: "Special pricing and monthly supply partnerships for arenas and academies." }
            ].map((feature, i) => (
              <div key={i} className="flex flex-col items-center text-center p-6 bg-white rounded-2xl shadow-sm border border-slate-100">
                <div className="h-14 w-14 rounded-full bg-green-100 text-brand-green flex items-center justify-center mb-6">
                  <feature.icon className="h-7 w-7" />
                </div>
                <h3 className="font-heading text-xl font-semibold mb-3">{feature.title}</h3>
                <p className="text-slate-600 leading-relaxed">{feature.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Arena Partnerships */}
      <section className="py-24 relative overflow-hidden bg-brand-green text-white">
        <div className="absolute inset-0 opacity-10">
          <div className="absolute top-0 -left-1/4 w-1/2 h-full bg-white transform -skew-x-12" />
        </div>
        <div className="container relative z-10 mx-auto px-4 md:px-6 flex flex-col md:flex-row items-center justify-between">
          <div className="md:w-1/2 mb-10 md:mb-0">
            <h2 className="font-heading text-4xl font-bold mb-4">Supply Your Arena</h2>
            <p className="text-green-50 text-lg mb-8 max-w-lg">
              Join our monthly supply program. Get reliable stock, priority delivery, and significant discounts for your futsal or football arena.
            </p>
            <ul className="space-y-3 mb-8">
              {['Guaranteed monthly stock', 'Wholesale pricing tiers', 'Priority customer support'].map((item, i) => (
                <li key={i} className="flex items-center text-green-50">
                  <CheckCircle2 className="h-5 w-5 mr-3 text-white" />
                  {item}
                </li>
              ))}
            </ul>
            <Link href="/wholesale">
              <Button size="lg" className="bg-white text-brand-green hover:bg-slate-100">
                Become a Partner
              </Button>
            </Link>
          </div>
          <div className="md:w-5/12">
            <div className="relative aspect-[4/3] rounded-2xl overflow-hidden shadow-2xl border-4 border-white/20 transform md:rotate-3 transition-transform hover:rotate-0 duration-500">
              <Image 
                src="https://images.unsplash.com/photo-1589487391730-58f20eb2c308?auto=format&fit=crop&q=80&w=1000"
                alt="Futsal arena"
                fill
                sizes="(max-width: 768px) 100vw, 50vw"
                className="object-cover"
              />
            </div>
          </div>
        </div>
      </section>

      {/* Testimonials */}
      <section className="py-20 bg-background">
        <div className="container mx-auto px-4 md:px-6">
          <h2 className="text-center font-heading text-3xl font-bold text-slate-900 mb-16 md:text-4xl">Trusted by the Best</h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
            {MOCK_TESTIMONIALS.map((testimonial) => (
              <Card key={testimonial.id} className="bg-slate-50 border-none">
                <CardContent className="p-8">
                  <div className="flex mb-4">
                    {[1,2,3,4,5].map(star => (
                      <svg key={star} className="w-5 h-5 text-yellow-400 fill-current" viewBox="0 0 20 20">
                        <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z" />
                      </svg>
                    ))}
                  </div>
                  <p className="text-slate-700 italic mb-6">&quot;{testimonial.content}&quot;</p>
                  <div>
                    <h4 className="font-semibold text-slate-900">{testimonial.name}</h4>
                    <p className="text-sm text-slate-500">{testimonial.role}</p>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        </div>
      </section>
    </div>
  );
}
