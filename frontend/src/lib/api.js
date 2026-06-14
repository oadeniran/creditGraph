import { API_URL } from "./config";

// --- Internal Fetch Wrapper ---
const fetchAPI = async (endpoint, options = {}) => {
  const url = `${API_URL}${endpoint}`;
  
  const headers = {
    "Content-Type": "application/json",
    ...options.headers,
  };

  const response = await fetch(url, { ...options, headers });
  
  if (!response.ok) {
    const errorData = await response.json().catch(() => ({}));
    throw new Error(errorData.detail || `API Request Failed: ${response.status}`);
  }
  
  return response.json();
};

// --- API Endpoints ---

export const api = {
  /**
   * Onboards a user, mints identity, and generates first score.
   */
  onboardUser: async (walletAddress) => {
    return fetchAPI("/api/onboard", {
      method: "POST",
      body: JSON.stringify({ wallet_address: walletAddress }),
    });
  },

  /**
   * Fetches the complete dashboard state for a user.
   */
  getUserDashboard: async (walletAddress) => {
    return fetchAPI(`/api/user/${walletAddress}`, {
      method: "GET",
    });
  },

  /**
   * Originates a new loan.
   */
  borrowFunds: async (payload) => {
    // payload: { wallet_address, amount, term_days, tx_hash }
    return fetchAPI("/api/borrow", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  },

  /**
   * Repays an active loan.
   */
  repayLoan: async (payload) => {
    // payload: { wallet_address, loan_id, amount, tx_hash }
    return fetchAPI("/api/repay", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  },

  /**
   * Social Attestation: Vouch for a friend.
   */
  vouchForFriend: async (payload) => {
    // payload: { attester_address, subject_address, bond_amount, tx_hash }
    return fetchAPI("/api/attest", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  },

  /**
   * Fetches full loan history (Paginated)
   */
  getLoanHistory: async (walletAddress, page = 1, size = 5) => {
    return fetchAPI(`/api/user/${walletAddress}/loans?page=${page}&size=${size}`, { method: "GET" });
  },

  /**
   * Fetches full attestation history (Paginated)
   */
  getAttestationHistory: async (walletAddress, page = 1, size = 5) => {
    return fetchAPI(`/api/user/${walletAddress}/attestations?page=${page}&size=${size}`, { method: "GET" });
  }
};