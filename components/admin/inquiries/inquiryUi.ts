import type { InquiryKind, InquiryStatus } from "@/lib/types";

export const INQUIRY_STATUS_LABEL: Record<InquiryStatus, string> = {
  new: "New",
  contacted: "Contacted",
  closed: "Closed",
};

export const INQUIRY_STATUS_CLASS: Record<InquiryStatus, string> = {
  new: "border-blue-200 bg-blue-50 text-blue-700",
  contacted: "border-amber-200 bg-amber-50 text-amber-700",
  closed: "border-slate-200 bg-slate-100 text-slate-600",
};

export const INQUIRY_KIND_LABEL: Record<InquiryKind, string> = {
  contact: "Contact",
  wholesale: "Wholesale",
};

export const INQUIRY_KIND_CLASS: Record<InquiryKind, string> = {
  contact: "bg-slate-100 text-slate-600",
  wholesale: "bg-emerald-50 text-emerald-700",
};
