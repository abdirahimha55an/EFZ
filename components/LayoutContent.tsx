"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { Navbar } from "@/components/Navbar";
import { Footer } from "@/components/Footer";
import { FloatingWhatsApp } from "@/components/FloatingWhatsApp";
import { usePublicSettings } from "@/lib/settings";

export function LayoutContent({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const settings = usePublicSettings();

  // Applies the configured brand colours and favicon to the document. Keyed on
  // the settings themselves rather than the route, so it runs once when they
  // load instead of on every navigation.
  useEffect(() => {
    if (settings.primaryColor) {
      document.documentElement.style.setProperty('--brand-blue', settings.primaryColor);
      document.documentElement.style.setProperty('--brand-blue-dark', settings.primaryColor);
    }
    if (settings.secondaryColor) {
      document.documentElement.style.setProperty('--brand-green', settings.secondaryColor);
    }

    if (settings.favicon) {
      let link: HTMLLinkElement | null = document.querySelector("link[rel*='icon']");
      if (!link) {
        link = document.createElement('link');
        link.rel = 'icon';
        document.getElementsByTagName('head')[0].appendChild(link);
      }
      link.href = settings.favicon;
    }
  }, [settings.primaryColor, settings.secondaryColor, settings.favicon]);

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
