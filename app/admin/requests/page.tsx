"use client";

/**
 * Website Requests: a thin page over the shared requests inbox (components/admin/requests/RequestsInbox.tsx). The inbox applies a source filter; there is no separate table.
 */
import { Suspense } from "react";
import { Loader2 } from "lucide-react";
import { RequestsInbox } from "@/components/admin/requests/RequestsInbox";

export default function WebsiteRequestsPage() {
  // useSearchParams() (inside the inbox) needs a Suspense boundary to keep the route prerenderable.
  return (
    <Suspense
      fallback={
        <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
          <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        </div>
      }
    >
      <RequestsInbox source="web" />
    </Suspense>
  );
}
