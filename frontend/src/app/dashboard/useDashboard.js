import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { api } from "@/lib/api";
import { txCoordinator } from "@/lib/blockchain";

export function useDashboard() {
  const router = useRouter();
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  
  // UI States
  const [activeTab, setActiveTab] = useState("dashboard"); // "dashboard", "history", "profile"
  const [historyView, setHistoryView] = useState("loans"); // "loans" or "attestations"
  const [activeModal, setActiveModal] = useState(null); 
  
  // Data States for Paginated History
  const [fullLoans, setFullLoans] = useState({ items: [], total_pages: 1, current_page: 1 });
  const [fullAttestations, setFullAttestations] = useState({ items: [], total_pages: 1, current_page: 1 });
  
  // Pagination States
  const [loanPage, setLoanPage] = useState(1);
  const [attestPage, setAttestPage] = useState(1);

  // Form States
  const [amount, setAmount] = useState("");
  const [targetAddress, setTargetAddress] = useState("");
  const [selectedLoan, setSelectedLoan] = useState(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  // 1. Initial User Fetch
  useEffect(() => {
    const fetchUser = async () => {
      const address = localStorage.getItem("wallet_address");
      if (!address) return router.push("/");

      try {
        const data = await api.getUserDashboard(address);
        setUser(data);
      } catch (err) {
        console.error("Failed to fetch dashboard:", err);
      } finally {
        setLoading(false);
      }
    };
    fetchUser();
  }, [router]);

  // 2. Fetch Paginated Loans (Triggers on mount, tab change, or page change)
  useEffect(() => {
    if (activeTab === "history" && historyView === "loans" && user) {
      api.getLoanHistory(user.wallet_address, loanPage, 5) // 5 items per page
         .then(data => setFullLoans(data))
         .catch(err => console.error("Loan history fetch error:", err));
    }
  }, [activeTab, historyView, loanPage, user]);

  // 3. Fetch Paginated Attestations (Triggers on mount, tab change, or page change)
  useEffect(() => {
    if (activeTab === "history" && historyView === "attestations" && user) {
      api.getAttestationHistory(user.wallet_address, attestPage, 5) // 5 items per page
         .then(data => setFullAttestations(data))
         .catch(err => console.error("Attestation history fetch error:", err));
    }
  }, [activeTab, historyView, attestPage, user]);

  // Navigation Helper
  const goToHistory = (view) => {
    setHistoryView(view);
    setLoanPage(1);     // Reset to page 1 on fresh navigation
    setAttestPage(1);   // Reset to page 1 on fresh navigation
    setActiveTab("history");
  };

  // Action Handlers
  const handleBorrow = async () => {
    setIsSubmitting(true);
    try {
      await txCoordinator.borrowFunds(user.wallet_address, amount, 30);
      window.location.reload(); 
    } catch (err) {
      alert("Borrow routine error: " + err.message);
    }
    setIsSubmitting(false);
  };

  const handleVouch = async () => {
    setIsSubmitting(true);
    try {
      await txCoordinator.vouchForFriend(user.wallet_address, targetAddress, amount);
      window.location.reload();
    } catch (err) {
      alert("Vouch routine error: " + err.message);
    }
    setIsSubmitting(false);
  };

  const handleRepay = async () => {
    setIsSubmitting(true);
    try {
      await txCoordinator.repayLoan(user.wallet_address, selectedLoan, amount);
      window.location.reload();
    } catch (err) {
      alert("Repayment routine error: " + err.message);
    }
    setIsSubmitting(false);
  };

  const disconnectWallet = () => {
    localStorage.removeItem("wallet_address");
    router.push("/");
  };

  return {
    user, loading,
    activeTab, setActiveTab,
    historyView, setHistoryView, goToHistory,
    fullLoans, loanPage, setLoanPage,
    fullAttestations, attestPage, setAttestPage,
    activeModal, setActiveModal,
    amount, setAmount, targetAddress, setTargetAddress, isSubmitting,
    handleBorrow, handleVouch, handleRepay, setSelectedLoan, disconnectWallet
  };
}