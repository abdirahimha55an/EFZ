import { notFound } from "next/navigation";
import { legalStatus, openPlaceholders } from "@/lib/legal/content";

/** Wraps a legal page: 404 in Production until the owner has filled every placeholder; a DRAFT banner in a Staging preview. */
export function LegalShell({ title, children }: { title: string; children: React.ReactNode }) {
  const status = legalStatus();
  if (status === "hidden") notFound();
  return (
    <div className="bg-slate-50 min-h-screen py-12">
      <div className="container mx-auto max-w-3xl px-4 md:px-6">
        {status === "draft" && (
          <div role="alert" className="mb-6 rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
            DRAFT - NOT FOR PUBLICATION. Open placeholders: {openPlaceholders().join(", ")}.
          </div>
        )}
        <h1 className="font-heading text-3xl font-bold text-slate-900 mb-6">{title}</h1>
        <div className="space-y-4 text-slate-700 leading-relaxed">{children}</div>
      </div>
    </div>
  );
}
