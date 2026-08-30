import type { Metadata } from "next";
import { Inter, Outfit } from "next/font/google";
import { LayoutContent } from "@/components/LayoutContent";
import "./globals.css";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
});

const outfit = Outfit({
  variable: "--font-outfit",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "EFZ | Elite Football Zone - Premium Sports Equipment in Somalia",
  description: "Somalia's premier supplier of high-quality footballs and futsal balls for arenas, schools, and organizers.",
  keywords: ["footballs in Somalia", "futsal balls Mogadishu", "sports equipment Somalia", "EFZ", "Elite Football Zone"],
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`${inter.variable} ${outfit.variable} h-full antialiased`}>
      <body className="min-h-full flex flex-col font-sans bg-background text-foreground overflow-x-hidden">
        <LayoutContent>{children}</LayoutContent>
      </body>
    </html>
  );
}
