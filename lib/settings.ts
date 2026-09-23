"use client";

import { useEffect, useState } from "react";
import type { AdminSettings } from "@/lib/types";
import { getDb } from "@/lib/supabase/db";

/**
 * Shown until the real row arrives, so the chrome never renders blank and a
 * misconfigured project still produces a usable page.
 */
export const DEFAULT_SETTINGS: AdminSettings = {
  businessName: "Elite Football Zone",
  shortName: "EFZ",
  logo: "",
  favicon: "",
  whatsappNumber: "",
  contactEmail: "",
  defaultLowStockThreshold: 50,
  currencySymbol: "$",
  theme: "light",
  primaryColor: "#0F172A",
  secondaryColor: "#00E676",
};

/**
 * One in-flight request shared by every caller.
 *
 * The navbar, footer, WhatsApp button and three pages all want the same row on
 * the same paint. Without this they would each issue their own query for it.
 */
let pending: Promise<AdminSettings> | null = null;

/**
 * Business branding for the public site. `settings` is one of the two tables
 * anon may read, so this works for signed-out visitors.
 *
 * Never throws: branding is not worth breaking a page over.
 */
export function usePublicSettings(): AdminSettings {
  const [settings, setSettings] = useState<AdminSettings>(DEFAULT_SETTINGS);

  useEffect(() => {
    let cancelled = false;

    if (!pending) {
      pending = getDb()
        .settings.get()
        .catch(() => DEFAULT_SETTINGS);
    }

    pending.then(next => {
      if (!cancelled) setSettings(next);
    });

    return () => {
      cancelled = true;
    };
  }, []);

  return settings;
}

/** Drops the cache so the next mount refetches. For use after saving settings. */
export function invalidatePublicSettings() {
  pending = null;
}
