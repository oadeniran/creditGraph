# app/main.py
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api.routes import onboard, dashboard, transactions

app = FastAPI(title="CreditGraph API", version="0.1")

# Allow Next.js frontend to call us
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # Change to localhost:3000 in prod if needed
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(onboard.router, prefix="/api", tags=["Onboarding"])
app.include_router(dashboard.router, prefix="/api", tags=["Dashboard"])
app.include_router(transactions.router, prefix="/api", tags=["Transactions"])

@app.get("/")
async def root():
    return {"message": "CreditGraph API running. LFG."}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8005)