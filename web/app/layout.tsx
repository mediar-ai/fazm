import type { Metadata, Viewport } from "next";
import "./globals.css";
import PostHogInit from "@/components/PostHogInit";

export const metadata: Metadata = {
  title: "Fazm",
  description: "Your desktop AI, from your phone",
  manifest: "/manifest.json",
  appleWebApp: {
    capable: true,
    title: "Fazm",
    statusBarStyle: "black-translucent",
  },
  icons: {
    icon: "/favicon.ico",
    apple: "/apple-touch-icon.png",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  viewportFit: "cover",
  themeColor: "#0a0a0a",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        <PostHogInit />
        {children}
      </body>
    </html>
  );
}
