from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="TenantGuard Predictor")

class PredictionRequest(BaseModel):
    tenant_id: str
    cpu_usage: float
    memory_usage: float
    db_connections: int
    p95_latency_ms: float

class PredictionResponse(BaseModel):
    recommendation: str
    throttle_probability: float
    suggested_cpu_limit: float
    suggested_memory_limit_mb: int

@app.get("/health")
def health():
    return {"status": "ok", "service": "predictor"}

@app.post("/predict", response_model=PredictionResponse)
def predict(req: PredictionRequest):
    score = 0.0
    score += min(req.cpu_usage / 100.0, 1.0) * 0.4
    score += min(req.memory_usage / 100.0, 1.0) * 0.3
    score += min(req.db_connections / 10.0, 1.0) * 0.2
    score += min(req.p95_latency_ms / 1000.0, 1.0) * 0.1

    if score > 0.75:
        recommendation = "throttle_and_isolate"
        throttle_probability = round(min(score, 1.0), 3)
        suggested_cpu_limit = round(max(0.2, 0.6 - (score * 0.3)), 3)
        suggested_memory_limit_mb = max(256, int(512 - (score * 250)))
    elif score > 0.45:
        recommendation = "watch_and_limit"
        throttle_probability = round(score / 1.5, 3)
        suggested_cpu_limit = round(max(0.4, 0.7 - (score * 0.2)), 3)
        suggested_memory_limit_mb = max(384, int(600 - (score * 200)))
    else:
        recommendation = "allow"
        throttle_probability = round(score * 0.5, 3)
        suggested_cpu_limit = 0.8
        suggested_memory_limit_mb = 600

    return PredictionResponse(
        recommendation=recommendation,
        throttle_probability=throttle_probability,
        suggested_cpu_limit=suggested_cpu_limit,
        suggested_memory_limit_mb=suggested_memory_limit_mb,
    )
