/**
 * Public social media accounts shown in the footer.
 *
 * EFZ has not supplied any verified account yet, so every URL is empty and the footer shows no
 * social icons. To add one, paste the account's full https URL below and deploy: nothing else
 * changes. Only fill in accounts the business owns and has confirmed; do not guess a handle.
 */
export type SocialNetwork = "facebook" | "instagram" | "x";

export const SOCIAL_LINKS: Record<SocialNetwork, string> = {
  facebook: "",
  instagram: "",
  x: "",
};

export const SOCIAL_LABELS: Record<SocialNetwork, string> = { facebook: "Facebook", instagram: "Instagram", x: "X" };

/** The configured accounts that are real https URLs, in a fixed display order. Anything else is ignored. */
export function visibleSocialLinks(links: Record<SocialNetwork, string> = SOCIAL_LINKS): { network: SocialNetwork; url: string }[] {
  const order: SocialNetwork[] = ["facebook", "instagram", "x"];
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
