# app/api/routes/dashboard.py
from fastapi import APIRouter, HTTPException, Query
from models.schemas import DashboardResponse, ScoreData
from core.database import db
from services.agent_service import calculate_credit_limit
import math

router = APIRouter()

@router.get("/user/{wallet_address}", response_model=DashboardResponse)
async def get_dashboard(wallet_address: str):
    """The mega-endpoint that hydrates the Next.js FE in one call."""
    
    user = await db.users.find_one({"wallet_address": wallet_address})
    if not user:
        raise HTTPException(status_code=404, detail="User not found. Call /onboard first.")

    score = await db.scores.find_one({"wallet_address": wallet_address})
    loans_cursor = db.loans.find({"wallet_address": wallet_address, "state": {"$in": ["Active", "Late"]}})
    loans = await loans_cursor.to_list(length=100)
    
    attests_cursor = db.attests.find({"subject_address": wallet_address, "active": True})
    attests = await attests_cursor.to_list(length=100)

    # Limit Engine Math
    total_limit = await calculate_credit_limit(wallet_address, score["tier"])
    exposure = sum(loan["outstanding"] for loan in loans)
    headroom = max(0, total_limit - exposure)

    return {
        "wallet_address": wallet_address,
        "token_id": user["token_id"],
        "credit_score": {
            "score": score["score"],
            "tier": score["tier"],
            "reason": score["reason"],
            "updated_at": score["updated_at"]
        },
        "available_limit": total_limit,
        "current_exposure": exposure,
        "headroom": headroom,
        "active_loans": [
            {
                "loan_id": str(l["_id"]), 
                "principal": l["principal"], 
                "outstanding": l["outstanding"],
                "apr_bps": l["apr_bps"],
                "due_at": l["due_at"],
                "state": l["state"]
            } for l in loans
        ],
        "active_attestations": [
            {
                "attester_address": a["attester_address"],
                "bond_amount": a["bond_amount"],
                "active": a["active"]
            } for a in attests
        ]
    }

@router.get("/user/{wallet_address}/loans")
async def get_loan_history(
    wallet_address: str, 
    page: int = Query(1, ge=1), 
    size: int = Query(5, ge=1) # Defaulting to 5 per page for the demo
):
    skip = (page - 1) * size
    
    # Get total for pagination math
    total_count = await db.loans.count_documents({"wallet_address": wallet_address})
    total_pages = math.ceil(total_count / size) if total_count > 0 else 1

    cursor = db.loans.find({"wallet_address": wallet_address}).sort("originated_at", -1).skip(skip).limit(size)
    loans = await cursor.to_list(length=size)
    
    return {
        "items": [
            {
                "loan_id": str(l["_id"]), 
                "principal": l["principal"], 
                "outstanding": l["outstanding"],
                "apr_bps": l.get("apr_bps", 1500),
                "due_at": l["due_at"],
                "state": l["state"]
            } for l in loans
        ],
        "total_pages": total_pages,
        "current_page": page
    }

@router.get("/user/{wallet_address}/attestations")
async def get_attestation_history(
    wallet_address: str,
    page: int = Query(1, ge=1), 
    size: int = Query(5, ge=1)
):
    skip = (page - 1) * size
    
    total_count = await db.attests.count_documents({"attester_address": wallet_address})
    total_pages = math.ceil(total_count / size) if total_count > 0 else 1

    cursor = db.attests.find({"attester_address": wallet_address}).sort("created_at", -1).skip(skip).limit(size)
    attests = await cursor.to_list(length=size)
    
    return {
        "items": [
            {
                "attester_address": a["attester_address"],
                "subject_address": a.get("subject_address", "Unknown"),
                "bond_amount": a["bond_amount"],
                "active": a["active"],
                "created_at": a.get("created_at")
            } for a in attests
        ],
        "total_pages": total_pages,
        "current_page": page
    }