import { useState, useEffect } from "react";
import Link from "next/link";
import { Menu, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { storage } from "@/lib/storage";

const NAV_LINKS = [
  { name: "Home", href: "/" },
  { name: "Products", href: "/products" },
  { name: "Wholesale", href: "/wholesale" },
  { name: "Contact", href: "/contact" },
];

export function Navbar() {
  const [isOpen, setIsOpen] = useState(false);
  const [isMounted, setIsMounted] = useState(false);
  const [settings, setSettings] = useState({
    businessName: "Elite Football Zone",
    logo: ""
  });

  useEffect(() => {
    setIsMounted(true);
    const s = storage.getSettings();
    setSettings({
      businessName: s.businessName,
      logo: s.logo
    });
  }, []);

  return (
    <nav className="sticky top-0 z-40 w-full border-b border-slate-200 bg-white/80 backdrop-blur-md">
      <div className="container mx-auto px-4 md:px-6">
        <div className="flex h-16 items-center justify-between">
          {/* Logo */}
          <Link href="/" className="flex items-center gap-2">
            {!isMounted ? (
              <span className="font-heading text-2xl font-bold tracking-tight text-brand-blue">
                EFZ<span className="text-brand-green">.</span>
              </span>
            ) : settings.logo ? (
              <img src={settings.logo} alt={settings.businessName} className="h-10 w-auto object-contain" />
            ) : (
              <span className="font-heading text-2xl font-bold tracking-tight text-brand-blue">
                {settings.businessName}<span className="text-brand-green">.</span>
              </span>
            )}
          </Link>

          {/* Desktop Nav */}
          <div className="hidden md:flex md:items-center md:gap-8">
            {NAV_LINKS.map((link) => (
              <Link
                key={link.name}
                href={link.href}
                className="text-sm font-medium text-slate-600 transition-colors hover:text-brand-blue"
              >
                {link.name}
              </Link>
            ))}
            <Link href="/order">
              <span className="inline-flex h-9 items-center justify-center rounded-md bg-brand-blue px-4 py-2 text-sm font-medium text-white shadow transition-colors hover:bg-brand-blue-light">
                Order Now
              </span>
            </Link>
          </div>

          {/* Mobile Menu Toggle */}
          <button
            className="md:hidden p-2 text-slate-600"
            onClick={() => setIsOpen(!isOpen)}
            aria-label="Toggle menu"
          >
            {isOpen ? <X className="h-6 w-6" /> : <Menu className="h-6 w-6" />}
          </button>
        </div>
      </div>

      {/* Mobile Nav */}
      {isOpen && (
        <div className="md:hidden border-t border-slate-200 bg-white">
          <div className="container mx-auto px-4 py-4 flex flex-col space-y-4">
            {NAV_LINKS.map((link) => (
              <Link
                key={link.name}
                href={link.href}
                onClick={() => setIsOpen(false)}
                className="text-base font-medium text-slate-800"
              >
                {link.name}
              </Link>
            ))}
            <Link 
              href="/order"
              onClick={() => setIsOpen(false)}
              className="mt-2 inline-flex w-full items-center justify-center rounded-md bg-brand-blue px-4 py-3 text-base font-medium text-white shadow"
            >
              Order Now
            </Link>
          </div>
        </div>
      )}
    </nav>
  );
}
