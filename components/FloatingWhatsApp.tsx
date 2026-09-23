"use client";

import { MessageCircle } from "lucide-react";
import { getWhatsAppUrl, EFZ_WHATSAPP_NUMBER } from "@/lib/utils";
import Link from "next/link";
import { motion } from "framer-motion";
import { usePublicSettings } from "@/lib/settings";

export function FloatingWhatsApp() {
  const settings = usePublicSettings();

  // wa.me wants digits only, and falls back to the built-in number until the
  // settings row arrives (or if it has none configured).
  const whatsappNumber = settings.whatsappNumber.replace(/\D/g, '') || EFZ_WHATSAPP_NUMBER;

  const defaultMessage = "Hello EFZ, I'm interested in your football/futsal products.";
  const url = getWhatsAppUrl(whatsappNumber, defaultMessage);

  return (
    <motion.div
      initial={{ scale: 0, opacity: 0 }}
      animate={{ scale: 1, opacity: 1 }}
      transition={{ delay: 1, type: "spring", stiffness: 260, damping: 20 }}
      className="fixed bottom-6 right-6 z-50"
    >
      <Link href={url} target="_blank" rel="noopener noreferrer">
        <div className="flex h-14 w-14 items-center justify-center rounded-full bg-[#25D366] text-white shadow-lg shadow-green-900/20 transition-transform hover:scale-110 active:scale-95 group relative">
          <MessageCircle className="h-7 w-7" />
          <span className="absolute -top-10 right-0 w-max rounded-md bg-white px-3 py-1 text-sm font-medium text-slate-800 shadow-sm opacity-0 transition-opacity group-hover:opacity-100">
            Chat with us
          </span>
        </div>
      </Link>
    </motion.div>
  );
}
