import Script from "next/script";
import "./globals.css";

export const metadata = {
  title: "CreditGraph",
  description: "The onchain credit identity layer for 1.4 billion people.",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        {/* Injects the runtime variables before React loads */}
        <Script src="/env.js" strategy="beforeInteractive" />
      </head>
      <body>{children}</body>
    </html>
  );
}