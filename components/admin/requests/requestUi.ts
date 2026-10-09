import type { WebsiteRequestStatus } from "@/lib/types";

export const STATUS_LABEL: Record<WebsiteRequestStatus, string> = {
  new: "New",
  contacted: "Contacted",
  confirmed: "Confirmed",
  converted: "Converted",
  rejected: "Rejected",
};

export const STATUS_CLASS: Record<WebsiteRequestStatus, string> = {
  new: "border-blue-200 bg-blue-50 text-blue-700",
  contacted: "border-amber-200 bg-amber-50 text-amber-700",
  confirmed: "border-emerald-200 bg-emerald-50 text-emerald-700",
  converted: "border-slate-200 bg-slate-100 text-slate-600",
  rejected: "border-red-200 bg-red-50 text-red-600",
};

/** "12 min", "3 h", "2 d" - how long a request has been waiting. */
export function ageOf(iso: string, now = Date.now()): { label: string; hours: number } {
  const hours = Math.max(0, (now - new Date(iso).getTime()) / 3_600_000);
  if (hours < 1) return { label: `${Math.max(1, Math.round(hours * 60))} min`, hours };
  if (hours < 48) return { label: `${Math.floor(hours)} h`, hours };
  return { label: `${Math.floor(hours / 24)} d`, hours };
}
