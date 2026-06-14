export default function HomeTab({ 
  user, styles, setActiveModal, setAmount, setSelectedLoan, goToHistory 
}) {
  const topLoans = user.active_loans?.slice(0, 5) || [];
  const topAttestations = user.active_attestations?.slice(0, 5) || [];

  return (
    <div>
      {/* Top Credit Card */}
      <div className={`card ${styles.creditCard}`}>
        <p className={styles.cardSubtitle}>Your Credit Limit</p>
        <div className={`big-number ${styles.cardValue}`}>${user.available_limit?.toFixed(2) || "0.00"} USDC</div>
        
        <div className={`flex-row ${styles.cardDivider}`}>
          <div>
            <p className={styles.smallLabel}>Credit Score</p>
            <div className={styles.boldValue}>{user.credit_score?.score || "Pending"}</div>
          </div>
          <div className={styles.alignRight}>
            <p className={styles.smallLabel}>Tier</p>
            <div className={styles.tierValue}>{user.credit_score?.tier || "1"}</div>
          </div>
        </div>
      </div>

      {/* Main Action Buttons */}
      <div className="flex-gap">
        <button className="btn-primary" onClick={() => { setAmount(""); setActiveModal("borrow"); }}>
          Borrow
        </button>
        <button className="btn-secondary" onClick={() => { setAmount(""); setActiveModal("vouch"); }}>
          Vouch
        </button>
      </div>

      {/* Active Loans */}
      <h2 className={styles.sectionTitle}>Active Loans</h2>
      {topLoans.length === 0 ? (
        <p className={styles.smallLabel}>No active loans.</p>
      ) : (
        topLoans.map(loan => (
          <div key={loan.loan_id} className="card flex-row">
            <div>
              <div className={styles.loanAmount}>${loan.outstanding} USDC</div>
              <div className={loan.state === "Late" ? styles.loanStateLate : styles.loanStateActive}>
                {loan.state}
              </div>
            </div>
            <button 
              className={styles.actionButton}
              onClick={() => {
                setSelectedLoan(loan.loan_id);
                setAmount(loan.outstanding.toString());
                setActiveModal("repay");
              }}
            >
              Repay
            </button>
          </div>
        ))
      )}
      {user.active_loans?.length > 5 && (
        <button className={styles.viewAllBtn} onClick={() => goToHistory("loans")}>
          View All Loans
        </button>
      )}

      {/* Active Attestations */}
      <h2 className={styles.sectionTitle} style={{marginTop: "24px"}}>Social Attestations</h2>
      {topAttestations.length === 0 ? (
        <p className={styles.smallLabel}>You haven't vouched for anyone yet.</p>
      ) : (
        topAttestations.map((att, i) => (
          <div key={i} className={`card flex-row ${styles.attestCard}`}>
            <span className={styles.attestText}>Vouched for: {att.subject_address?.substring(0,6)}...</span>
            <span className={styles.attestAmount}>${att.bond_amount}</span>
          </div>
        ))
      )}
      {user.active_attestations?.length > 5 && (
        <button className={styles.viewAllBtn} onClick={() => goToHistory("attestations")}>
          View All Vouches
        </button>
      )}
    </div>
  );
}