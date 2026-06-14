# app/core/database.py
from motor.motor_asyncio import AsyncIOMotorClient
from envs import MONGO_URI


client = AsyncIOMotorClient(MONGO_URI)
db = client.creditgraph_db

# Collections mimicking our smart contracts
users_collection = db.users           # CreditIdentity
scores_collection = db.scores         # ScoreRegistry
loans_collection = db.loans           # LoanManager
attestations_collection = db.attests  # SocialAttestation