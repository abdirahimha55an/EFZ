"use client";

import { useState, useEffect } from "react";
import { usePathname } from "next/navigation";
import { Navbar } from "@/components/Navbar";
import { Footer } from "@/components/Footer";
import { FloatingWhatsApp } from "@/components/FloatingWhatsApp";
import { storage } from "@/lib/storage";

export function LayoutContent({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const [isMounted, setIsMounted] = useState(false);
  
  useEffect(() => {
    setIsMounted(true);
    const settings = storage.getSettings();
    
    // Inject brand colors
    if (settings.primaryColor) {
      document.documentElement.style.setProperty('--brand-blue', settings.primaryColor);
      document.documentElement.style.setProperty('--brand-blue-dark', settings.primaryColor);
    }
    if (settings.secondaryColor) {
      document.documentElement.style.setProperty('--brand-green', settings.secondaryColor);
    }

    // Inject favicon
    if (settings.favicon) {
      let link: HTMLLinkElement | null = document.querySelector("link[rel*='icon']");
      if (!link) {
        link = document.createElement('link');
        link.rel = 'icon';
        document.getElementsByTagName('head')[0].appendChild(link);
      }
      link.href = settings.favicon;
    }
  }, [pathname]); // Update on route change in case settings changed

  // Check if current route is an admin route
  const isAdmin = pathname.startsWith("/admin");

  if (isAdmin) {
    return (
      <main className="flex-grow">
        {children}
      </main>
    );
  }

  return (
    <>
      <Navbar />
      <main className="flex-grow">
        {children}
      </main>
      <Footer />
      <FloatingWhatsApp />
    </>
  );
}
