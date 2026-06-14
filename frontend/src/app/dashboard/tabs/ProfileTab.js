export default function ProfileTab({ 
  user, styles, setActiveModal, disconnectWallet 
}) {
  return (
    <div className={styles.profileContainer}>
      <div className={styles.avatar}>👤</div>
      <div className={styles.profileAddress}>
        {user.wallet_address.substring(0, 8)}...{user.wallet_address.substring(user.wallet_address.length - 6)}
      </div>
      
      <div className="card" style={{width: "100%", textAlign: "left", marginBottom: "24px"}}>
        <p style={{margin: 0, fontSize: "14px", color: "var(--text-muted)"}}>Identity Token ID</p>
        <p style={{fontWeight: "bold", fontSize: "18px", margin: "4px 0 16px 0"}}>#{user.token_id}</p>
        
        <p style={{margin: 0, fontSize: "14px", color: "var(--text-muted)"}}>Current Tier</p>
        <p style={{fontWeight: "bold", fontSize: "18px", color: "var(--primary)", margin: "4px 0 0 0"}}>Tier {user.credit_score?.tier}</p>
      </div>

      <button className="btn-primary" onClick={() => setActiveModal("increase_score")} style={{marginBottom: "16px"}}>
        Increase Credit Score
      </button>
      <button className="btn-secondary" onClick={disconnectWallet}>
        Disconnect Wallet
      </button>
    </div>
  );
}