import type { NextConfig } from "next";

// Deployment guard: a Vercel build that is NOT production (a preview) may only be pointed at the Staging Supabase project. A preview whose
// NEXT_PUBLIC_SUPABASE_URL is the Production project, or is not the Staging project, fails the BUILD, so no such preview can exist.
// Production builds (VERCEL_ENV=production) and local development (no VERCEL_ENV) are not affected.
const PRODUCTION_REF = "rodmdvfjashiohgwople";
const STAGING_REF = "adjjamiqwboawqedaapi";
if (process.env.VERCEL_ENV && process.env.VERCEL_ENV !== "production") {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  if (url.includes(PRODUCTION_REF)) {
    throw new Error("Refusing to build a " + process.env.VERCEL_ENV + " deployment: NEXT_PUBLIC_SUPABASE_URL is the PRODUCTION Supabase project. Previews must use Staging.");
  }
  if (!url.includes(STAGING_REF)) {
    throw new Error("Refusing to build a " + process.env.VERCEL_ENV + " deployment: NEXT_PUBLIC_SUPABASE_URL is not the Staging Supabase project.");
  }
}

// Shown in the sidebar so anyone can see which deployment (commit and environment) they are using.
const nextConfig: NextConfig = {
  env: {
    NEXT_PUBLIC_BUILD_SHA: (process.env.VERCEL_GIT_COMMIT_SHA ?? "local").slice(0, 7),
    NEXT_PUBLIC_BUILD_ENV: process.env.VERCEL_ENV ?? "local",
  },
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "images.unsplash.com",
        pathname: "/**",
      },
      {
        protocol: "https",
        hostname: "cdn.phototourl.com",
        pathname: "/**",
      },
    ],
  },
};

export default nextConfig;
