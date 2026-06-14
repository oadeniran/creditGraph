# app/api/routes/transactions.py
from fastapi import APIRouter, HTTPException
from datetime import datetime, timedelta
from bson.objectid import ObjectId

from models.schemas import BorrowRequest, RepayRequest, AttestRequest
from core.database import db
from core.web3_utils import verify_transaction

router = APIRouter()

@router.post("/borrow")
async def borrow_funds(req: BorrowRequest):
    """Originates a loan after FE completes the MetaMask transaction."""
    
    # 1. Try to verify on-chain (Fallback to True if RPC fails)
    if not verify_transaction(req.tx_hash):
        raise HTTPException(status_code=400, detail="Transaction reverted on-chain.")

    # 2. Check user exists
    user = await db.users.find_one({"wallet_address": req.wallet_address})
    if not user:
        raise HTTPException(status_code=404, detail="User not found.")

    # 3. Create Loan Record in Mongo
    # Note: In a full app, we'd pull apr_bps from the InterestRateModel SC. 
    # Here we mock a 15% APR (1500 bps) for the demo.
    loan_doc = {
        "wallet_address": req.wallet_address,
        "principal": req.amount,
        "outstanding": req.amount,
        "apr_bps": 1500,
        "originated_at": datetime.utcnow(),
        "due_at": datetime.utcnow() + timedelta(days=req.term_days),
        "state": "Active",
        "tx_hash": req.tx_hash
    }
    
    result = await db.loans.insert_one(loan_doc)
    
    return {
        "message": "Loan originated successfully", 
        "loan_id": str(result.inserted_id)
    }

@router.post("/repay")
async def repay_loan(req: RepayRequest):
    """Processes a loan repayment."""
    
    if not verify_transaction(req.tx_hash):
        raise HTTPException(status_code=400, detail="Transaction reverted on-chain.")

    # Find the loan
    loan = await db.loans.find_one({"_id": ObjectId(req.loan_id), "wallet_address": req.wallet_address})
    if not loan:
        raise HTTPException(status_code=404, detail="Loan not found.")

    # Calculate new outstanding balance
    new_outstanding = max(0.0, loan["outstanding"] - req.amount)
    new_state = "Repaid" if new_outstanding == 0 else "Active"

    # Update Mongo
    await db.loans.update_one(
        {"_id": ObjectId(req.loan_id)},
        {"$set": {
            "outstanding": new_outstanding,
            "state": new_state,
            "last_repayment_at": datetime.utcnow()
        }}
    )

    return {"message": f"Repayment successful. New balance: {new_outstanding}", "state": new_state}

@router.post("/attest")
async def social_attestation(req: AttestRequest):
    """The 'Vouch for a Friend' flow (SocialAttestation.sol)"""
    
    if not verify_transaction(req.tx_hash):
        raise HTTPException(status_code=400, detail="Transaction reverted on-chain.")

    # Verify subject exists
    subject = await db.users.find_one({"wallet_address": req.subject_address})
    if not subject:
        raise HTTPException(status_code=404, detail="Subject user does not exist in CreditGraph.")

    # Record the attestation
    attest_doc = {
        "attester_address": req.attester_address,
        "subject_address": req.subject_address,
        "bond_amount": req.bond_amount,
        "active": True,
        "created_at": datetime.utcnow(),
        "tx_hash": req.tx_hash
    }
    
    await db.attests.insert_one(attest_doc)

    return {"message": f"Successfully vouched for {req.subject_address} with {req.bond_amount} USDC."}