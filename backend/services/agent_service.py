# app/services/agent_service.py
import random
from datetime import datetime
from core.database import db

async def mint_identity_and_score(wallet_address: str):
    """Simulates CreditIdentity.mint() and DataCollector/Underwriter Agents"""
    
    # Check if user exists
    existing = await db.users.find_one({"wallet_address": wallet_address})
    if existing:
        return existing

    # Mock Agent Scoring Logic
    mock_score = random.randint(600, 750)
    tier = 3 if mock_score > 700 else 2
    
    user_doc = {
        "wallet_address": wallet_address,
        "token_id": random.randint(1000, 9999), # Fake ERC-5192 Token ID
        "created_at": datetime.utcnow()
    }
    await db.users.insert_one(user_doc)

    score_doc = {
        "wallet_address": wallet_address,
        "score": mock_score,
        "tier": tier,
        "reason": "Agent verified mobile money inflows > $50/mo",
        "updated_at": datetime.utcnow()
    }
    await db.scores.insert_one(score_doc)
    
    return user_doc

async def calculate_credit_limit(wallet_address: str, tier: int):
    """Simulates CreditLimitEngine.sol"""
    # Base limits by tier
    tier_limits = {1: 20, 2: 50, 3: 150, 4: 500, 5: 2000}
    base = tier_limits.get(tier, 20)
    
    # Calculate social attestation bonus (Cap at 2x base)
    cursor = db.attests.find({"subject_address": wallet_address, "active": True})
    attestations = await cursor.to_list(length=100)
    
    bonus = sum(a["bond_amount"] for a in attestations)
    max_bonus = base * 2
    
    return base + min(bonus, max_bonus)