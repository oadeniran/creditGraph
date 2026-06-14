from dotenv import load_dotenv
import os

load_dotenv()  # Load environment variables from .env file

MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
RPC_URL = os.getenv("RPC_URL", "https://sepolia-rollup.arbitrum.io/rpc")
