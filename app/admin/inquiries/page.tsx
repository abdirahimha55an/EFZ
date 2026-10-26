"use client";

/**
 * Contact & Wholesale: a thin page over the inquiries inbox (components/admin/inquiries/InquiriesInbox.tsx). Access is gated by the
 * view_inquiries nav permission in the admin layout, and by RLS in the database.
 */
import { Suspense } from "react";
import { Loader2 } from "lucide-react";
import { InquiriesInbox } from "@/components/admin/inquiries/InquiriesInbox";

export default function InquiriesPage() {
  // useSearchParams() (inside the inbox) needs a Suspense boundary to keep the route prerenderable.
  return (
    <Suspense
      fallback={
        <div>
          <h1 className="font-heading text-2xl font-bold tracking-tight text-slate-900" data-testid="inquiries-title">Contact &amp; Wholesale</h1>
          <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
            <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
          </div>
        </div>
      }
    >
      <InquiriesInbox />
    </Suspense>
  );
}
