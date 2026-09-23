"use client";

import Image from "next/image";
import Link from "next/link";
import { motion, useMotionValue, useSpring, useTransform, useReducedMotion } from "framer-motion";
import { ArrowRight, CheckCircle2, Shield, Zap, TrendingUp, Users, Trophy, Truck, Headphones, MessageCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Product } from "@/lib/types";
import { getDb } from "@/lib/supabase/db";
import { toPublicProduct, type Testimonial } from "@/lib/supabase/mappers";
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
      staggerChildren: 0.15
    }
  }
};

const slideUp = {
  hidden: { opacity: 0, y: 40 },
  visible: { opacity: 1, y: 0, transition: { duration: 0.8 } }
};

function ArenaInteractiveImage() {
  const [glarePos, setGlarePos] = useState({ x: 50, y: 50 });
  const [isHovered, setIsHovered] = useState(false);
  const shouldReduceMotion = useReducedMotion();

  const mouseX = useMotionValue(0);
  const mouseY = useMotionValue(0);

  const springConfig = { damping: 25, stiffness: 180, mass: 0.5 };
  const smoothMouseX = useSpring(mouseX, springConfig);
  const smoothMouseY = useSpring(mouseY, springConfig);

  const rotateX = useTransform(smoothMouseY, [-0.5, 0.5], [5, -5]);
  const rotateY = useTransform(smoothMouseX, [-0.5, 0.5], [-5, 5]);

  const imageTranslateX = useTransform(smoothMouseX, [-0.5, 0.5], [-6, 6]);
  const imageTranslateY = useTransform(smoothMouseY, [-0.5, 0.5], [-6, 6]);

  const handleMouseMove = (e: React.MouseEvent<HTMLDivElement>) => {
    if (shouldReduceMotion) return;
    const rect = e.currentTarget.getBoundingClientRect();
    if (!rect.width || !rect.height) return;

    const xPct = (e.clientX - rect.left) / rect.width - 0.5;
    const yPct = (e.clientY - rect.top) / rect.height - 0.5;

    mouseX.set(xPct);
    mouseY.set(yPct);
    setGlarePos({
      x: ((e.clientX - rect.left) / rect.width) * 100,
      y: ((e.clientY - rect.top) / rect.height) * 100,
    });
  };

  const handleMouseEnter = () => {
    if (!shouldReduceMotion) {
      setIsHovered(true);
    }
  };

  const handleMouseLeave = () => {
    setIsHovered(false);
    mouseX.set(0);
    mouseY.set(0);
  };

  return (
    <div
      className="relative [perspective:1000px] select-none"
      onMouseMove={handleMouseMove}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      <motion.div
        style={{
          rotateX: shouldReduceMotion ? 0 : rotateX,
          rotateY: shouldReduceMotion ? 0 : rotateY,
          transformStyle: "preserve-3d",
        }}
        animate={{
          scale: !shouldReduceMotion && isHovered ? 1.03 : 1,
        }}
        transition={{ duration: 0.35, ease: "easeOut" }}
        className="relative aspect-square rounded-3xl overflow-hidden shadow-2xl border-4 border-white/20 will-change-transform"
      >
        <motion.div
          className="absolute -inset-3 w-[calc(100%+1.5rem)] h-[calc(100%+1.5rem)]"
          style={{
            x: shouldReduceMotion ? 0 : imageTranslateX,
            y: shouldReduceMotion ? 0 : imageTranslateY,
          }}
        >
          <Image
            src="https://images.unsplash.com/photo-1589487391730-58f20eb2c308?auto=format&fit=crop&q=80&w=1000"
            alt="Professional futsal arena"
            fill
            sizes="(max-width: 768px) 100vw, 50vw"
            className="object-cover"
          />
        </motion.div>

        {/* Ambient & contrast overlay */}
        <div className="absolute inset-0 bg-gradient-to-t from-brand-green/40 to-transparent pointer-events-none" />

        {/* Subtle cursor-following light/highlight */}
        {!shouldReduceMotion && (
          <div
            className="absolute inset-0 pointer-events-none transition-opacity duration-300"
            style={{
              opacity: isHovered ? 1 : 0,
              background: `radial-gradient(circle 280px at ${glarePos.x}% ${glarePos.y}%, rgba(255, 255, 255, 0.18) 0%, transparent 65%)`,
            }}
          />
        )}
      </motion.div>
    </div>
  );
}

export default function Home() {
  const [isMounted, setIsMounted] = useState(false);
  const [products, setProducts] = useState<Product[]>([]);
  const [testimonials, setTestimonials] = useState<Testimonial[]>([]);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const db = getDb();
        // Both tables are readable by anon, so a signed-out visitor gets the
        // real catalog and the real quotes.
        const [rows, quotes] = await Promise.all([
          db.products.listPublic(),
          db.testimonials.list(),
        ]);
        if (cancelled) return;
        setProducts(rows.map(toPublicProduct));
        setTestimonials(quotes);
      } catch {
        if (!cancelled) {
          setProducts([]);
          setTestimonials([]);
        }
      } finally {
        if (!cancelled) setIsMounted(true);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  const featuredProducts = products.slice(0, 3);

  if (!isMounted) return null;

  return (
    <div className="flex flex-col">
      {/* ============ 1. HERO SECTION ============ */}
      <section className="relative overflow-hidden bg-gradient-to-br from-brand-blue-dark via-brand-blue to-brand-blue-dark py-24 lg:py-40">
        <div className="absolute inset-0 z-0">
          <Image
            src="https://images.unsplash.com/photo-1579952363873-27f3bade9f55?auto=format&fit=crop&q=80&w=2000"
            alt="Football field at night"
            fill
            sizes="100vw"
            className="object-cover opacity-15"
            priority
          />
          <div className="absolute inset-0 bg-gradient-to-r from-brand-blue-dark via-brand-blue-dark/70 to-transparent" />
          <div className="absolute top-20 right-0 w-96 h-96 bg-brand-green/10 rounded-full blur-3xl" />
        </div>

        <div className="container relative z-10 mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            animate="visible"
            variants={staggerContainer}
            className="max-w-4xl"
          >
            <motion.div variants={fadeIn} className="inline-block mb-6">
              <span className="text-brand-green text-sm font-bold uppercase tracking-widest">Elite Football Zone</span>
            </motion.div>

            <motion.h1 variants={fadeIn} className="font-heading text-5xl sm:text-6xl lg:text-7xl font-bold tracking-tight text-white leading-tight">
              The Heart of <span className="text-brand-green block lg:inline">Every Game</span>
            </motion.h1>

            <motion.p variants={fadeIn} className="mt-8 text-lg sm:text-xl text-slate-200 max-w-2xl leading-relaxed">
              Premium football and futsal products built for the game, trusted by players and arenas. Direct supply. Professional quality. Built to perform.
            </motion.p>

            <motion.div variants={fadeIn} className="mt-12 flex flex-col sm:flex-row gap-4">
              <Link href="/products">
                <Button size="lg" className="w-full sm:w-auto bg-brand-green hover:bg-brand-green/90 text-white font-semibold">
                  Shop Products <ArrowRight className="ml-2 h-5 w-5" />
                </Button>
              </Link>
              <Link href="/wholesale">
                <Button size="lg" variant="outline" className="w-full sm:w-auto border-slate-300 text-white hover:bg-white hover:text-brand-blue-dark font-semibold">
                  Partner with EFZ
                </Button>
              </Link>
            </motion.div>
          </motion.div>
        </div>
      </section>

      {/* ============ 2. TRUST / VALUE STRIP ============ */}
      <section className="bg-white border-b border-slate-200">
        <div className="container mx-auto px-4 md:px-6 py-12">
          <motion.div
            initial="hidden"
            animate="visible"
            variants={staggerContainer}
            className="grid grid-cols-2 gap-6 md:grid-cols-4 gap-8"
          >
            {[
              { icon: Trophy, label: "Quality Products", desc: "Built for demanding play" },
              { icon: Truck, label: "Arena Ready", desc: "Designed for regular futsal use" },
              { icon: Users, label: "Direct Supply", desc: "Reliable wholesale partnerships" },
              { icon: Headphones, label: "Customer Focused", desc: "Service built around the game" },
            ].map((item, idx) => (
              <motion.div key={idx} variants={fadeIn} className="flex flex-col items-center text-center">
                <div className="h-12 w-12 rounded-xl bg-brand-green/10 text-brand-green flex items-center justify-center mb-3">
                  <item.icon className="h-6 w-6" />
                </div>
                <h3 className="font-semibold text-slate-900 text-sm md:text-base">{item.label}</h3>
                <p className="text-xs md:text-sm text-slate-500 mt-1">{item.desc}</p>
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ============ 3. FEATURED PRODUCTS ============ */}
      <section className="py-20 bg-background">
        <div className="container mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={slideUp}
            className="mb-16"
          >
            <div className="inline-block mb-3">
              <span className="text-brand-green text-xs font-bold uppercase tracking-widest">Our Range</span>
            </div>
            <h2 className="font-heading text-4xl md:text-5xl font-bold text-slate-900 mb-4">Built for the Game</h2>
            <p className="text-lg text-slate-600 max-w-2xl">
              Reliable football products for players, arenas and teams. Handpicked for performance and durability.
            </p>
          </motion.div>

          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={staggerContainer}
            className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3"
          >
            {featuredProducts.map((product) => (
              <motion.div key={product.id} variants={fadeIn}>
                <Card className="overflow-hidden group h-full flex flex-col hover:shadow-xl transition-shadow duration-300">
                  <div className="relative aspect-square overflow-hidden bg-slate-100">
                    <Image
                      src={product.imageUrl}
                      alt={product.name}
                      fill
                      sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 33vw"
                      className="object-cover transition-transform duration-500 group-hover:scale-110"
                      unoptimized={product.imageUrl?.startsWith('data:')}
                    />
                    <div className="absolute inset-0 bg-black/0 group-hover:bg-black/10 transition-colors duration-300" />
                    <div className="absolute top-4 left-4 bg-brand-green text-white text-xs font-bold px-3 py-1 rounded-full uppercase tracking-wide">
                      {product.category}
                    </div>
                  </div>
                  <CardContent className="p-6 flex flex-col flex-grow">
                    <h3 className="font-heading text-xl font-semibold text-slate-900 mb-2">{product.name}</h3>
                    <p className="text-slate-600 text-sm mb-4 leading-relaxed line-clamp-2">{product.description}</p>

                    <div className="mt-auto pt-6 border-t border-slate-100 flex items-end justify-between">
                      <div>
                        <p className="text-xs text-slate-500 uppercase tracking-wide mb-1">Price</p>
                        <span className="font-bold text-2xl text-brand-blue">${product.price.toFixed(2)}</span>
                      </div>
                      <Link href="/products">
                        <Button size="sm" className="bg-brand-green hover:bg-brand-green/90">Order Now</Button>
                      </Link>
                    </div>
                  </CardContent>
                </Card>
              </motion.div>
            ))}
          </motion.div>

          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={fadeIn}
            className="mt-12 text-center"
          >
            <Link href="/products">
              <Button size="lg" variant="outline" className="border-brand-green text-brand-green hover:bg-brand-green hover:text-white">
                View All Products <ArrowRight className="ml-2 h-4 w-4" />
              </Button>
            </Link>
          </motion.div>
        </div>
      </section>

      {/* ============ 4. WHY EFZ ============ */}
      <section className="py-20 bg-white">
        <div className="container mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={slideUp}
            className="mb-16"
          >
            <div className="inline-block mb-3">
              <span className="text-brand-green text-xs font-bold uppercase tracking-widest">Our Advantage</span>
            </div>
            <h2 className="font-heading text-4xl md:text-5xl font-bold text-slate-900">Why EFZ?</h2>
          </motion.div>

          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={staggerContainer}
            className="grid grid-cols-1 md:grid-cols-2 gap-12 max-w-5xl"
          >
            {[
              {
                title: "Quality",
                desc: "Products selected for real game conditions. Tested on local surfaces.",
                icon: Trophy
              },
              {
                title: "Consistency",
                desc: "Reliable supply for arenas and teams. Dependable partnerships.",
                icon: Truck
              },
              {
                title: "Value",
                desc: "Competitive pricing without compromising quality. Better margins for you.",
                icon: TrendingUp
              },
              {
                title: "Partnership",
                desc: "We build long-term relationships with arenas and football communities.",
                icon: Users
              },
            ].map((item, idx) => (
              <motion.div key={idx} variants={fadeIn} className="flex gap-6">
                <div className="flex-shrink-0">
                  <div className="h-14 w-14 rounded-xl bg-brand-green/10 text-brand-green flex items-center justify-center">
                    <item.icon className="h-7 w-7" />
                  </div>
                </div>
                <div>
                  <h3 className="font-heading text-2xl font-bold text-slate-900 mb-3">{item.title}</h3>
                  <p className="text-slate-600 leading-relaxed text-lg">{item.desc}</p>
                </div>
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ============ 5. ARENA PARTNERSHIP SECTION ============ */}
      <section className="relative py-24 overflow-hidden bg-gradient-to-br from-brand-green to-brand-green/90 text-white">
        <div className="absolute inset-0 opacity-10">
          <svg className="w-full h-full" viewBox="0 0 1200 600" preserveAspectRatio="none">
            <circle cx="100" cy="50" r="300" fill="white" opacity="0.1" />
            <circle cx="1100" cy="500" r="400" fill="white" opacity="0.1" />
          </svg>
        </div>

        <div className="container relative z-10 mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={staggerContainer}
            className="grid md:grid-cols-2 gap-12 items-center"
          >
            <motion.div variants={fadeIn}>
              <div className="inline-block mb-4">
                <span className="text-green-100 text-xs font-bold uppercase tracking-widest">For Arenas</span>
              </div>
              <h2 className="font-heading text-4xl md:text-5xl font-bold mb-6">Built for Arenas</h2>
              <p className="text-green-50 text-xl mb-10 leading-relaxed max-w-xl">
                Keep your arena ready for every game with reliable football products and direct supply from EFZ.
              </p>

              <motion.ul variants={staggerContainer} className="space-y-4 mb-10">
                {[
                  "Wholesale pricing with guaranteed margins",
                  "Regular monthly supply schedule",
                  "Arena-focused service and support",
                  "Bulk order flexibility",
                  "Dedicated account support",
                ].map((item, i) => (
                  <motion.li key={i} variants={fadeIn} className="flex items-center text-green-50 text-lg">
                    <CheckCircle2 className="h-6 w-6 mr-3 flex-shrink-0 text-green-200" />
                    {item}
                  </motion.li>
                ))}
              </motion.ul>

              <motion.div variants={fadeIn}>
                <Link href="/wholesale">
                  <Button size="lg" className="bg-white text-brand-green hover:bg-slate-100 font-semibold">
                    Become an EFZ Arena Partner
                  </Button>
                </Link>
              </motion.div>
            </motion.div>

            <motion.div variants={fadeIn}>
              <ArenaInteractiveImage />
            </motion.div>
          </motion.div>
        </div>
      </section>

      {/* ============ 7. HOW IT WORKS ============ */}
      <section className="py-20 bg-background">
        <div className="container mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={slideUp}
            className="mb-16 text-center"
          >
            <div className="inline-block mb-3">
              <span className="text-brand-green text-xs font-bold uppercase tracking-widest">Simple Process</span>
            </div>
            <h2 className="font-heading text-4xl md:text-5xl font-bold text-slate-900">How It Works</h2>
          </motion.div>

          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={staggerContainer}
            className="grid grid-cols-1 md:grid-cols-3 gap-8 max-w-4xl mx-auto"
          >
            {[
              { num: "01", title: "Choose", desc: "Select the products your arena, team or game needs." },
              { num: "02", title: "Order", desc: "Place your order directly with EFZ via WhatsApp or portal." },
              { num: "03", title: "Play", desc: "Receive your products and get back to the game." },
            ].map((step, idx) => (
              <motion.div key={idx} variants={fadeIn} className="text-center">
                <div className="inline-block mb-6">
                  <div className="w-20 h-20 rounded-full bg-brand-green text-white flex items-center justify-center">
                    <span className="font-heading text-4xl font-bold">{step.num}</span>
                  </div>
                </div>
                <h3 className="font-heading text-2xl font-bold text-slate-900 mb-3">{step.title}</h3>
                <p className="text-slate-600 text-lg leading-relaxed">{step.desc}</p>
                {idx < 2 && <div className="hidden md:block absolute right-0 top-1/2 transform translate-x-1/2 -translate-y-1/2">
                  <ArrowRight className="h-8 w-8 text-brand-green/30" />
                </div>}
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ============ 8. BRAND / STORY SECTION ============ */}
      <section className="py-20 bg-slate-50">
        <div className="container mx-auto px-4 md:px-6">
          <div className="max-w-3xl mx-auto text-center">
            <motion.div
              initial="hidden"
              whileInView="visible"
              viewport={{ once: true }}
              variants={slideUp}
            >
              <h2 className="font-heading text-4xl md:text-5xl font-bold text-slate-900 mb-6">
                More Than a Ball
              </h2>
              <p className="text-xl text-slate-600 leading-relaxed mb-8">
                EFZ exists to support the game at every level — from individual players to the arenas where football communities come together. 
                We believe in quality, reliability, and building partnerships that last.
              </p>
              <p className="text-lg text-slate-500 leading-relaxed">
                Whether you&apos;re running a professional arena, training the next generation, or organizing tournaments, 
                EFZ is your trusted partner for premium football products.
              </p>
            </motion.div>
          </div>
        </div>
      </section>

      {/* ============ 9. SOCIAL PROOF ============ */}
      <section className="py-20 bg-white">
        <div className="container mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={slideUp}
            className="mb-16 text-center"
          >
            <div className="inline-block mb-3">
              <span className="text-brand-green text-xs font-bold uppercase tracking-widest">Testimonials</span>
            </div>
            <h2 className="font-heading text-4xl md:text-5xl font-bold text-slate-900">Trusted by the Game</h2>
          </motion.div>

          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={staggerContainer}
            className="grid grid-cols-1 md:grid-cols-3 gap-8"
          >
            {testimonials.map((testimonial) => (
              <motion.div key={testimonial.id} variants={fadeIn}>
                <Card className="bg-slate-50 border-2 border-slate-100 h-full hover:border-brand-green transition-colors duration-300">
                  <CardContent className="p-8 flex flex-col h-full">
                    <div className="flex mb-6">
                      {[1,2,3,4,5].map(star => (
                        <svg key={star} className="w-5 h-5 text-brand-green fill-current" viewBox="0 0 20 20">
                          <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z" />
                        </svg>
                      ))}
                    </div>
                    <p className="text-slate-700 text-lg italic mb-6 flex-grow">&quot;{testimonial.content}&quot;</p>
                    <div className="pt-6 border-t border-slate-200">
                      <h4 className="font-semibold text-slate-900">{testimonial.name}</h4>
                      <p className="text-sm text-slate-500">{testimonial.role}</p>
                    </div>
                  </CardContent>
                </Card>
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ============ 10. CTA SECTION ============ */}
      <section className="relative py-24 overflow-hidden bg-gradient-to-r from-brand-blue via-brand-blue-dark to-brand-green text-white">
        <div className="absolute inset-0">
          <div className="absolute top-10 right-20 w-72 h-72 bg-white/5 rounded-full blur-3xl" />
          <div className="absolute bottom-10 left-20 w-96 h-96 bg-white/5 rounded-full blur-3xl" />
        </div>

        <div className="container relative z-10 mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={slideUp}
            className="text-center max-w-3xl mx-auto"
          >
            <h2 className="font-heading text-4xl md:text-5xl lg:text-6xl font-bold mb-6 leading-tight">
              Ready for the Next Game?
            </h2>
            <p className="text-xl text-slate-100 mb-12 max-w-2xl mx-auto leading-relaxed">
              Whether you&apos;re an arena, team or player, EFZ is ready to supply what you need. 
              Premium quality. Wholesale pricing. Direct delivery.
            </p>

            <motion.div
              initial="hidden"
              whileInView="visible"
              viewport={{ once: true }}
              variants={staggerContainer}
              className="flex flex-col sm:flex-row gap-4 justify-center"
            >
              <motion.div variants={fadeIn}>
                <Link href="/products">
                  <Button size="lg" className="w-full sm:w-auto bg-white text-brand-blue hover:bg-slate-100 font-semibold">
                    Shop Products
                  </Button>
                </Link>
              </motion.div>
              <motion.div variants={fadeIn}>
                <Link href="/wholesale">
                  <Button size="lg" variant="outline" className="w-full sm:w-auto border-white text-white hover:bg-white hover:text-brand-blue font-semibold">
                    Partner with EFZ
                  </Button>
                </Link>
              </motion.div>
            </motion.div>
          </motion.div>
        </div>
      </section>

      {/* ============ 11. CONTACT / WHATSAPP ============ */}
      <section className="py-20 bg-background">
        <div className="container mx-auto px-4 md:px-6">
          <motion.div
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true }}
            variants={slideUp}
            className="text-center max-w-2xl mx-auto"
          >
            <div className="inline-block mb-4">
              <span className="text-brand-green text-xs font-bold uppercase tracking-widest">Get in Touch</span>
            </div>
            <h2 className="font-heading text-4xl md:text-5xl font-bold text-slate-900 mb-6">
              Quick Support
            </h2>
            <p className="text-lg text-slate-600 mb-10">
              Have questions? Need bulk pricing? Get in touch with our team via WhatsApp for instant support.
            </p>

            <motion.div
              initial="hidden"
              whileInView="visible"
              viewport={{ once: true }}
              variants={staggerContainer}
              className="flex flex-col sm:flex-row gap-4 justify-center"
            >
              <motion.div variants={fadeIn}>
                <a href="https://wa.me/252614129991" target="_blank" rel="noopener noreferrer">
                  <Button size="lg" className="w-full sm:w-auto bg-brand-green hover:bg-brand-green/90 text-white font-semibold">
                    <MessageCircle className="mr-2 h-5 w-5" />
                    Chat on WhatsApp
                  </Button>
                </a>
              </motion.div>
              <motion.div variants={fadeIn}>
                <Link href="/contact">
                  <Button size="lg" variant="outline" className="w-full sm:w-auto border-brand-green text-brand-green hover:bg-brand-green hover:text-white font-semibold">
                    Contact Form
                  </Button>
                </Link>
              </motion.div>
            </motion.div>
          </motion.div>
        </div>
      </section>
    </div>
  );
}
