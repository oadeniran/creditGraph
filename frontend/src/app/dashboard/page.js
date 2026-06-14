"use client";
import { useDashboard } from "./useDashboard";
import styles from "./dashboard.module.css";

// Decoupled tab components
import HomeTab from "./tabs/HomeTab";
import HistoryTab from "./tabs/HistoryTab";
import ProfileTab from "./tabs/ProfileTab";

export default function Dashboard() {
  const {
    user, loading, activeTab, setActiveTab, historyView, setHistoryView, goToHistory,
    fullLoans, loanPage, setLoanPage, 
    fullAttestations, attestPage, setAttestPage, 
    activeModal, setActiveModal,
    amount, setAmount, targetAddress, setTargetAddress, isSubmitting,
    handleBorrow, handleVouch, handleRepay, setSelectedLoan, disconnectWallet
  } = useDashboard();

  if (loading) return <div className={`container ${styles.loadingContainer}`}>Loading identity...</div>;
  if (!user) return <div className={`container ${styles.loadingContainer}`}>Failed to load user. Please reconnect.</div>;

  return (
    <>
      <main className="container main-content">
        {/* Global Header */}
        <div className={`flex-row ${styles.header}`}>
          <h2>Credit<span className="text-orange">Graph</span></h2>
          <span className={styles.walletBadge}>
            {user.wallet_address.substring(0, 6)}...{user.wallet_address.substring(user.wallet_address.length - 4)}
          </span>
        </div>

        {/* --- RENDER ACTIVE TAB --- */}
        {activeTab === "dashboard" && (
          <HomeTab 
            user={user} styles={styles} 
            setActiveModal={setActiveModal} setAmount={setAmount} 
            setSelectedLoan={setSelectedLoan} goToHistory={goToHistory} 
          />
        )}

        {activeTab === "history" && (
          <HistoryTab 
            fullLoans={fullLoans} loanPage={loanPage} setLoanPage={setLoanPage}
            fullAttestations={fullAttestations} attestPage={attestPage} setAttestPage={setAttestPage}
            historyView={historyView} setHistoryView={setHistoryView} 
            styles={styles} 
          />
        )}

        {activeTab === "profile" && (
          <ProfileTab 
            user={user} styles={styles} 
            setActiveModal={setActiveModal} disconnectWallet={disconnectWallet} 
          />
        )}

        {/* --- GLOBAL MODALS --- */}
        {activeModal === "borrow" && (
          <div className="modal-overlay">
            <div className="card modal-card">
              <h2>Borrow Funds</h2>
              <p className={styles.modalText}>Available Headroom: <strong>${user.headroom} USDC</strong></p>
              <input type="number" className="input-field" placeholder="Amount (USDC)" value={amount} onChange={e => setAmount(e.target.value)} />
              <p className={styles.modalNote}>Fixed Term: 30 days | APR: 15%</p>
              <div className={`flex-gap ${styles.modalActions}`}>
                <button className="btn-secondary" onClick={() => setActiveModal(null)} disabled={isSubmitting}>Cancel</button>
                <button className="btn-primary" onClick={handleBorrow} disabled={isSubmitting}>{isSubmitting ? "Confirming..." : "Confirm"}</button>
              </div>
            </div>
          </div>
        )}

        {activeModal === "vouch" && (
          <div className="modal-overlay">
            <div className="card modal-card">
              <h2>Vouch for a Friend</h2>
              <p>Boost their limit. If they default, you lose this stake.</p>
              <input type="text" className="input-field" placeholder="Friend's Wallet Address" value={targetAddress} onChange={e => setTargetAddress(e.target.value)} />
              <input type="number" className="input-field" placeholder="Bond Amount (USDC)" value={amount} onChange={e => setAmount(e.target.value)} />
              <div className={`flex-gap ${styles.modalActions}`}>
                <button className="btn-secondary" onClick={() => setActiveModal(null)} disabled={isSubmitting}>Cancel</button>
                <button className="btn-primary" onClick={handleVouch} disabled={isSubmitting}>{isSubmitting ? "Staking..." : "Stake"}</button>
              </div>
            </div>
          </div>
        )}

        {activeModal === "repay" && (
          <div className="modal-overlay">
            <div className="card modal-card">
              <h2>Repay Loan</h2>
              <input type="number" className="input-field" placeholder="Amount to Repay (USDC)" value={amount} onChange={e => setAmount(e.target.value)} />
              <div className={`flex-gap ${styles.modalActions}`}>
                <button className="btn-secondary" onClick={() => setActiveModal(null)} disabled={isSubmitting}>Cancel</button>
                <button className="btn-primary" onClick={handleRepay} disabled={isSubmitting}>{isSubmitting ? "Processing..." : "Repay"}</button>
              </div>
            </div>
          </div>
        )}

        {activeModal === "increase_score" && (
          <div className="modal-overlay">
            <div className="card modal-card">
              <h2>Increase Score</h2>
              <p className={styles.modalText}>To increase your score, you can:</p>
              <ul className={styles.aboutList} style={{marginTop: "12px", marginBottom: "24px"}}>
                <li className={styles.aboutListItem}>Repay active loans on time to build your graduation streak.</li>
                <li className={styles.aboutListItem}>Get a trusted friend with a high tier to Vouch for you.</li>
                <li className={styles.aboutListItem}>Connect more mobile money data sources for the AI agents to verify.</li>
              </ul>
              <button className="btn-primary" onClick={() => setActiveModal(null)}>Understood</button>
            </div>
          </div>
        )}
      </main>

      {/* --- BOTTOM NAVIGATION --- */}
      <nav className="bottom-nav">
        <div className="nav-container">
          <button className={`nav-item ${activeTab === "dashboard" ? "active" : ""}`} onClick={() => setActiveTab("dashboard")}>
            <span className="nav-icon">⌂</span> Home
          </button>
          <button className={`nav-item ${activeTab === "history" ? "active" : ""}`} onClick={() => setActiveTab("history")}>
            <span className="nav-icon">🕒</span> History
          </button>
          <button className={`nav-item ${activeTab === "profile" ? "active" : ""}`} onClick={() => setActiveTab("profile")}>
            <span className="nav-icon">👤</span> Profile
          </button>
        </div>
      </nav>
    </>
  );
}