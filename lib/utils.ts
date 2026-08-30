import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/**
 * Merges Tailwind CSS classes
 */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Generates a WhatsApp URL with a pre-filled message
 * @param phone WhatsApp phone number (e.g., "252610000000")
 * @param message Pre-filled message
 */
export function getWhatsAppUrl(phone: string, message: string) {
  const encodedMessage = encodeURIComponent(message);
  return `https://wa.me/${phone}?text=${encodedMessage}`;
}

// EFZ Contact Number (Replace with actual)
export const EFZ_WHATSAPP_NUMBER = "252614129991";
