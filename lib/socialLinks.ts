/**
 * Public social media accounts shown in the footer.
 *
 * Only accounts the owner has supplied and confirmed are filled in (Facebook and TikTok). An empty
 * value shows no icon. To add one, paste the account's full https URL and deploy: nothing else
 * changes. Do not guess a handle.
 */
export type SocialNetwork = "facebook" | "instagram" | "x" | "tiktok";

export const SOCIAL_LINKS: Record<SocialNetwork, string> = {
  facebook: "https://www.facebook.com/profile.php?id=61596258383654",
  instagram: "",
  x: "",
  tiktok: "https://www.tiktok.com/@elite.football.zone?is_from_webapp=1&sender_device=pc",
};

export const SOCIAL_LABELS: Record<SocialNetwork, string> = { facebook: "Facebook", instagram: "Instagram", x: "X", tiktok: "TikTok" };

/** The configured accounts that are real https URLs, in a fixed display order. Anything else is ignored. */
export function visibleSocialLinks(links: Record<SocialNetwork, string> = SOCIAL_LINKS): { network: SocialNetwork; url: string }[] {
  const order: SocialNetwork[] = ["facebook", "instagram", "x", "tiktok"];
  return order.flatMap((network) => {
    const raw = (links[network] ?? "").trim();
    if (!raw) return [];
    try {
      const u = new URL(raw);
      return u.protocol === "https:" && u.hostname.includes(".") ? [{ network, url: u.toString() }] : [];
    } catch {
      return [];
    }
  });
}
