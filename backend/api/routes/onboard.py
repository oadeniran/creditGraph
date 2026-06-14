# app/api/routes/onboard.py
from fastapi import APIRouter
from models.schemas import UserOnboardRequest
from services.agent_service import mint_identity_and_score

router = APIRouter()

@router.post("/onboard")
async def onboard_user(req: UserOnboardRequest):
    """Simulates wallet connect, minting soulbound ID, and initial agent scoring."""
    user = await mint_identity_and_score(req.wallet_address)
    return {"message": "Identity Minted & Scored", "token_id": user["token_id"]}