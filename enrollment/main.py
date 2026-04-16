from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException

from . import db
from .models import EnrollRequest, EnrollResponse

DB_PATH = Path(os.environ.get("SUBTERRA_DB", "/var/lib/subterra-hub/state.db"))

app = FastAPI(title="subterra-wg-hub enrollment", version="0.1.0")


@app.on_event("startup")
def _startup() -> None:
    db.initialize(DB_PATH)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/enroll", response_model=EnrollResponse)
def enroll(req: EnrollRequest) -> EnrollResponse:
    raise HTTPException(status_code=501, detail="enrollment not yet implemented")


def serve() -> None:
    import uvicorn

    uvicorn.run(
        "enrollment.main:app",
        host=os.environ.get("SUBTERRA_HOST", "127.0.0.1"),
        port=int(os.environ.get("SUBTERRA_PORT", "8080")),
    )
