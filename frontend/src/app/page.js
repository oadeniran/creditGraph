"use client";
import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { api } from "@/lib/api";

export default function Landing() {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [hasMetaMask, setHasMetaMask] = useState(true);

  // Check if MetaMask is installed when the component mounts
  useEffect(() => {
    if (typeof window !== "undefined" && !window.ethereum) {
      setHasMetaMask(false);
    }
  }, []);

  const connectWallet = async () => {
    setError("");
    
    if (!window.ethereum) {
      setError("Please install MetaMask to use CreditGraph.");
      return;
    }

    setLoading(true);

    try {
      // 1. Trigger MetaMask popup and request account access
      const accounts = await window.ethereum.request({ 
        method: "eth_requestAccounts" 
      });
      
      const walletAddress = accounts[0];

      if (!walletAddress) {
        throw new Error("No account selected.");
      }

      // 2. Tell backend to onboard (Mint identity + initial score)
      // If they already exist, your BE handles it and just returns their info
      await api.onboardUser(walletAddress);

      // 3. Save to local storage to persist the session across reloads
      localStorage.setItem("wallet_address", walletAddress);
      
      // 4. Push to dashboard
      router.push("/dashboard");

    } catch (err) {
      console.error("Connection failed:", err);
      // Handle user rejecting the MetaMask popup specifically
      if (err.code === 4001) {
        setError("You rejected the connection request.");
      } else {
        setError(err.message || "Failed to connect wallet or onboard.");
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className="container" style={{ display: "flex", flexDirection: "column", justifyContent: "center", alignItems: "center", textAlign: "center" }}>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center" }}>
        <h1>Credit<span className="text-orange">Graph</span></h1>
        <p style={{ fontSize: "18px", marginTop: "16px" }}>
          The onchain credit identity layer for the unbanked 1.4 billion.
        </p>
      </div>
      
      <div style={{ width: "100%", paddingBottom: "40px" }}>
        {error && (
          <p style={{ color: "red", fontSize: "14px", marginBottom: "16px", background: "#ffe6e6", padding: "10px", borderRadius: "8px" }}>
            {error}
          </p>
        )}
        
        <button 
          className="btn-primary" 
          onClick={connectWallet}
          disabled={loading || !hasMetaMask}
        >
          {!hasMetaMask 
            ? "MetaMask Not Found" 
            : loading 
              ? "Connecting MetaMask..." 
              : "Connect Wallet"}
        </button>
      </div>
    </main>
  );
}