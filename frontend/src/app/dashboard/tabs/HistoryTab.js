export default function HistoryTab({ 
  fullLoans, loanPage, setLoanPage,
  fullAttestations, attestPage, setAttestPage,
  historyView, setHistoryView, styles 
}) {
  return (
    <div>
      <h2 className={styles.networkTitle} style={{marginBottom: "16px"}}>History</h2>
      
      {/* Segmented Toggle */}
      <div className={styles.toggleContainer}>
        <button 
          className={`${styles.toggleBtn} ${historyView === "loans" ? styles.toggleBtnActive : ""}`}
          onClick={() => setHistoryView("loans")}
        >
          Loans
        </button>
        <button 
          className={`${styles.toggleBtn} ${historyView === "attestations" ? styles.toggleBtnActive : ""}`}
          onClick={() => setHistoryView("attestations")}
        >
          Attestations
        </button>
      </div>

      {/* --- LOANS LIST --- */}
      {historyView === "loans" && (
        <div>
          {(!fullLoans.items || fullLoans.items.length === 0) ? (
            <p>No loan history found.</p>
          ) : (
            fullLoans.items.map((loan, i) => (
              <div key={i} className="card flex-row">
                <div>
                  <div className={styles.loanAmount}>${loan.principal} USDC</div>
                  <div style={{fontSize: "12px", color: loan.state === "Repaid" ? "green" : loan.state === "Defaulted" ? "red" : "var(--primary)"}}>
                    Status: {loan.state}
                  </div>
                </div>
                <span style={{fontSize: "12px", color: "#888"}}>ID: {loan.loan_id.substring(0, 4)}</span>
              </div>
            ))
          )}
          
          {/* Pagination Controls */}
          {fullLoans.total_pages > 1 && (
            <div className="flex-row" style={{ marginTop: "16px" }}>
              <button 
                className="btn-secondary" style={{ padding: "8px", width: "auto" }}
                disabled={loanPage === 1} 
                onClick={() => setLoanPage(prev => Math.max(prev - 1, 1))}
              >
                ← Prev
              </button>
              <span style={{ fontSize: "14px", alignSelf: "center", color: "var(--text-muted)" }}>
                Page {loanPage} of {fullLoans.total_pages}
              </span>
              <button 
                className="btn-secondary" style={{ padding: "8px", width: "auto" }}
                disabled={loanPage === fullLoans.total_pages} 
                onClick={() => setLoanPage(prev => prev + 1)}
              >
                Next →
              </button>
            </div>
          )}
        </div>
      )}

      {/* --- ATTESTATIONS LIST --- */}
      {historyView === "attestations" && (
        <div>
          {(!fullAttestations.items || fullAttestations.items.length === 0) ? (
            <p>No attestation history found.</p>
          ) : (
            fullAttestations.items.map((att, i) => (
              <div key={i} className={`card flex-row ${styles.attestCard}`}>
                <span className={styles.attestText}>User: {att.subject_address?.substring(0,6)}...</span>
                <div style={{textAlign: "right"}}>
                   <div className={styles.attestAmount}>${att.bond_amount} USDC</div>
                   <div style={{fontSize: "12px", color: att.active ? "green" : "gray"}}>{att.active ? "Active" : "Inactive"}</div>
                </div>
              </div>
            ))
          )}

          {/* Pagination Controls */}
          {fullAttestations.total_pages > 1 && (
            <div className="flex-row" style={{ marginTop: "16px" }}>
              <button 
                className="btn-secondary" style={{ padding: "8px", width: "auto" }}
                disabled={attestPage === 1} 
                onClick={() => setAttestPage(prev => Math.max(prev - 1, 1))}
              >
                ← Prev
              </button>
              <span style={{ fontSize: "14px", alignSelf: "center", color: "var(--text-muted)" }}>
                Page {attestPage} of {fullAttestations.total_pages}
              </span>
              <button 
                className="btn-secondary" style={{ padding: "8px", width: "auto" }}
                disabled={attestPage === fullAttestations.total_pages} 
                onClick={() => setAttestPage(prev => prev + 1)}
              >
                Next →
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}