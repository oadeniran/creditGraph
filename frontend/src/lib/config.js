// Safely grabs runtime env vars injected by public/env.js, falling back to build-time vars
const getEnv = (key, fallback = "") => {
  if (typeof window !== "undefined" && window.env?.[key]) {
    return window.env[key];
  }
  return fallback;
};

const rawUrl = getEnv("NEXT_PUBLIC_API_URL", process.env.NEXT_PUBLIC_API_URL || "http://127.0.0.1:8000");

export const API_URL = rawUrl.replace(/\/$/, ""); // Strip trailing slash just in case
export const API_KEY = getEnv("NEXT_PUBLIC_API_KEY", process.env.NEXT_PUBLIC_API_KEY || "");