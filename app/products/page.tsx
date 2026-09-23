"use client";

import { useState } from "react";
import Image from "next/image";
import { Search, Filter, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { Product } from "@/lib/types";
import { getDb } from "@/lib/supabase/db";
import { toPublicProduct } from "@/lib/supabase/mappers";
import { usePublicSettings } from "@/lib/settings";
import { getWhatsAppUrl, EFZ_WHATSAPP_NUMBER } from "@/lib/utils";
import Link from "next/link";
import { useEffect } from "react";

export default function ProductsPage() {
  const [isMounted, setIsMounted] = useState(false);
  const [products, setProducts] = useState<Product[]>([]);
  const [searchTerm, setSearchTerm] = useState("");
  const [categoryFilter, setCategoryFilter] = useState<string>("All");
  const settings = usePublicSettings();

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        // public_products, not products: the view has no cost_price column at
        // all, so there is nothing for a visitor to read even by accident.
        const rows = await getDb().products.listPublic();
        if (!cancelled) setProducts(rows.map(toPublicProduct));
      } catch {
        if (!cancelled) setProducts([]);
      } finally {
        if (!cancelled) setIsMounted(true);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  const cleanWa = settings.whatsappNumber.replace(/\D/g, '') || EFZ_WHATSAPP_NUMBER;

  if (!isMounted) {
    return (
      <div className="bg-slate-50 min-h-screen flex flex-col items-center justify-center gap-3 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading catalog…</p>
      </div>
    );
  }

  const categories = ["All", "Football", "Futsal", "Accessories"];

  const filteredProducts = products.filter((product) => {
    const matchesSearch = product.name.toLowerCase().includes(searchTerm.toLowerCase());
    const matchesCategory = categoryFilter === "All" || product.category === categoryFilter;
    return matchesSearch && matchesCategory;
  });

  return (
    <div className="bg-slate-50 min-h-screen py-12">
      <div className="container mx-auto px-4 md:px-6">
        <div className="mb-12">
          <h1 className="font-heading text-4xl font-bold text-slate-900 md:text-5xl mb-4">Our Equipment</h1>
          <p className="text-lg text-slate-600 max-w-2xl">Browse our collection of premium footballs and futsal balls. Selected specifically for the playing conditions in Somalia.</p>
        </div>

        {/* Filters and Search */}
        <div className="flex flex-col md:flex-row gap-4 mb-8 justify-between items-center bg-white p-4 rounded-xl shadow-sm border border-slate-200">
          <div className="flex w-full md:w-auto overflow-x-auto pb-2 md:pb-0 gap-2 hide-scrollbar">
            {categories.map((cat) => (
              <Button
                key={cat}
                variant={categoryFilter === cat ? "default" : "outline"}
                size="sm"
                onClick={() => setCategoryFilter(cat)}
                className="whitespace-nowrap"
              >
                {cat}
              </Button>
            ))}
          </div>
          <div className="relative w-full md:w-72">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
            <Input
              type="text"
              placeholder="Search products..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="pl-9"
            />
          </div>
        </div>

        {/* Products Grid */}
        {filteredProducts.length > 0 ? (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
            {filteredProducts.map((product) => {
              const orderMessage = `Hello ${settings.businessName}, I want to order the ${product.name} (${product.size}).`;
              const waUrl = getWhatsAppUrl(cleanWa, orderMessage);

              return (
                <Card key={product.id} className="overflow-hidden group flex flex-col h-full bg-white">
                  <div className="relative aspect-square overflow-hidden bg-slate-100">
                    <Image
                      src={product.imageUrl}
                      alt={product.name}
                      fill
                      sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 33vw"
                      className="object-cover transition-transform duration-500 group-hover:scale-105"
                      unoptimized={product.imageUrl?.startsWith('data:')}
                    />
                    <div className="absolute top-3 left-3 bg-brand-blue text-white text-xs font-bold px-2 py-1 rounded shadow-sm">
                      {product.category}
                    </div>
                  </div>
                  <CardContent className="p-5 flex flex-col flex-grow">
                    <div className="flex justify-between items-start mb-2 gap-2">
                      <h3 className="font-heading text-lg font-bold leading-tight">{product.name}</h3>
                      <span className="font-bold text-brand-green">${product.price.toFixed(2)}</span>
                    </div>
                    
                    <div className="space-y-1 mb-4 text-xs text-slate-600">
                      <p><span className="font-semibold text-slate-900">Size:</span> {product.size}</p>
                      <p><span className="font-semibold text-slate-900">Surface:</span> {product.surfaceType}</p>
                      <p><span className="font-semibold text-slate-900">Durability:</span> {product.durability}</p>
                    </div>

                    <div className="mt-auto pt-4 flex gap-2">
                      <Link href={waUrl} target="_blank" rel="noopener noreferrer" className="flex-1">
                        <Button variant="whatsapp" className="w-full text-xs sm:text-sm">
                          Order on WhatsApp
                        </Button>
                      </Link>
                    </div>
                  </CardContent>
                </Card>
              );
            })}
          </div>
        ) : (
          <div className="text-center py-20 bg-white rounded-xl border border-slate-200">
            <div className="inline-flex h-16 w-16 items-center justify-center rounded-full bg-slate-100 mb-4">
              <Filter className="h-8 w-8 text-slate-400" />
            </div>
            <h3 className="text-xl font-heading font-semibold text-slate-900">No products found</h3>
            <p className="text-slate-500 mt-2">Try adjusting your search or category filter.</p>
            <Button 
              variant="outline" 
              className="mt-6"
              onClick={() => {
                setSearchTerm("");
                setCategoryFilter("All");
              }}
            >
              Clear Filters
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
