# app/models/schemas.py
from pydantic import BaseModel, Field
from typing import List, Optional
from datetime import datetime

class UserOnboardRequest(BaseModel):
    wallet_address: str

class ScoreData(BaseModel):
    score: int
    tier: int
    reason: str
    updated_at: datetime

class LoanData(BaseModel):
    loan_id: str
    principal: float
    outstanding: float
    apr_bps: int
    due_at: datetime
    state: str # "Active", "Repaid", "Late", "Defaulted"

class AttestationData(BaseModel):
    attester_address: str
    bond_amount: float
    active: bool

class DashboardResponse(BaseModel):
    wallet_address: str
    token_id: int
    credit_score: ScoreData
    available_limit: float
    current_exposure: float
    headroom: float
    active_loans: List[LoanData]
    active_attestations: List[AttestationData]

class BorrowRequest(BaseModel):
    wallet_address: str
    amount: float
    term_days: int
    tx_hash: Optional[str] = "mock_hash"

class RepayRequest(BaseModel):
    wallet_address: str
    loan_id: str
    amount: float
    tx_hash: Optional[str] = "mock_hash"

class AttestRequest(BaseModel):
    attester_address: str
    subject_address: str # The friend they are vouching for
    bond_amount: float
    tx_hash: Optional[str] = "mock_hash"