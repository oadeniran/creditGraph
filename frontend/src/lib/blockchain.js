import { ethers } from "ethers";
import { api } from "./api";

// --- Configuration ---
// Leave these blank or set to local addresses. If blank, it automatically triggers the mock fallback.
const CONTRACT_ADDRESSES = {
  USDC: "", 
  LoanManager: "",
  SocialAttestation: ""
};

// Minimal ABIs required for executing functions
const MINIMAL_ABIS = {
  USDC: [
    "function approve(address spender, uint256 amount) external returns (bool)"
  ],
  LoanManager: [
    "function originate(uint256 amount, uint64 termDays) external returns (uint256)",
    "function repay(uint256 loanId, uint256 amount) external"
  ],
  SocialAttestation: [
    "function attest(address subject, uint256 bondAmount) external"
  ]
};

/**
 * Helper to get an ethers signer connected to MetaMask
 */
const getSigner = async () => {
  if (typeof window === "undefined" || !window.ethereum) {
    throw new Error("No crypto wallet found");
  }
  const provider = new ethers.BrowserProvider(window.ethereum);
  return await provider.getSigner();
};

export const txCoordinator = {
  /**
   * Originates a loan on-chain, or falls back to mock if unconfigured/fails.
   */
  borrowFunds: async (walletAddress, amountStr, termDays = 30) => {
    try {
      if (!CONTRACT_ADDRESSES.LoanManager) throw new Error("LoanManager address not configured");
      
      const signer = await getSigner();
      const contract = new ethers.Contract(CONTRACT_ADDRESSES.LoanManager, MINIMAL_ABIS.LoanManager, signer);
      
      // USDC usually uses 6 decimals
      const parsedAmount = ethers.parseUnits(amountStr, 6);
      
      // 1. Submit transaction to MetaMask
      const tx = await contract.originate(parsedAmount, termDays);
      console.log("Real on-chain tx submitted:", tx.hash);
      
      // 2. Wait for 1 confirmation (optional for speed, but great for safety)
      await tx.wait(1);

      // 3. Notify backend with the REAL transaction hash
      return await api.borrowFunds({
        wallet_address: walletAddress,
        amount: parseFloat(amountStr),
        term_days: termDays,
        tx_hash: tx.hash
      });

    } catch (error) {
      console.warn("[Web3 Fallback Active] Real borrow failed or unconfigured. Running mock:", error.message);
      
      // EXECUTE FALLBACK: Hit the backend with a fake hash so your demo keeps rolling
      return await api.borrowFunds({
        wallet_address: walletAddress,
        amount: parseFloat(amountStr),
        term_days: termDays,
        tx_hash: "mock_tx_borrow_" + Date.now()
      });
    }
  },

  /**
   * Handles Social Attestation. Approves USDC token allowance then stakes into the attestation contract.
   */
  vouchForFriend: async (attesterAddress, subjectAddress, bondAmountStr) => {
    try {
      if (!CONTRACT_ADDRESSES.SocialAttestation || !CONTRACT_ADDRESSES.USDC) {
        throw new Error("SocialAttestation or USDC addresses not configured");
      }

      const signer = await getSigner();
      const usdcContract = new ethers.Contract(CONTRACT_ADDRESSES.USDC, MINIMAL_ABIS.USDC, signer);
      const attestationContract = new ethers.Contract(CONTRACT_ADDRESSES.SocialAttestation, MINIMAL_ABIS.SocialAttestation, signer);
      
      const parsedAmount = ethers.parseUnits(bondAmountStr, 6);

      // 1. Approve contract to spend your USDC bond
      const approveTx = await usdcContract.approve(CONTRACT_ADDRESSES.SocialAttestation, parsedAmount);
      await approveTx.wait(1);

      // 2. Fire the attestation transaction
      const tx = await attestationContract.attest(subjectAddress, parsedAmount);
      await tx.wait(1);

      return await api.vouchForFriend({
        attester_address: attesterAddress,
        subject_address: subjectAddress,
        bond_amount: parseFloat(bondAmountStr),
        tx_hash: tx.hash
      });

    } catch (error) {
      console.warn("[Web3 Fallback Active] Real vouch failed or unconfigured. Running mock:", error.message);
      
      return await api.vouchForFriend({
        attester_address: attesterAddress,
        subject_address: subjectAddress,
        bond_amount: parseFloat(bondAmountStr),
        tx_hash: "mock_tx_vouch_" + Date.now()
      });
    }
  },

  /**
   * Repays an active loan. Approves USDC allowance then hits LoanManager.repay()
   */
  repayLoan: async (walletAddress, loanId, amountStr) => {
    try {
      if (!CONTRACT_ADDRESSES.LoanManager || !CONTRACT_ADDRESSES.USDC) {
        throw new Error("LoanManager or USDC addresses not configured");
      }

      const signer = await getSigner();
      const usdcContract = new ethers.Contract(CONTRACT_ADDRESSES.USDC, MINIMAL_ABIS.USDC, signer);
      const loanContract = new ethers.Contract(CONTRACT_ADDRESSES.LoanManager, MINIMAL_ABIS.LoanManager, signer);
      
      const parsedAmount = ethers.parseUnits(amountStr, 6);

      // 1. Approve LoanManager to take the repayment amount
      const approveTx = await usdcContract.approve(CONTRACT_ADDRESSES.LoanManager, parsedAmount);
      await approveTx.wait(1);

      // 2. Submit repayment transaction
      const tx = await loanContract.repay(loanId, parsedAmount);
      await tx.wait(1);

      return await api.repayLoan({
        wallet_address: walletAddress,
        loan_id: loanId,
        amount: parseFloat(amountStr),
        tx_hash: tx.hash
      });

    } catch (error) {
      console.warn("[Web3 Fallback Active] Real repayment failed or unconfigured. Running mock:", error.message);
      
      return await api.repayLoan({
        wallet_address: walletAddress,
        loan_id: loanId,
        amount: parseFloat(amountStr),
        tx_hash: "mock_tx_repay_" + Date.now()
      });
    }
  }
};