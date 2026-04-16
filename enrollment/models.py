from __future__ import annotations

from pydantic import BaseModel, Field


class EnrollRequest(BaseModel):
    serial: str = Field(min_length=4, max_length=64)
    pubkey: str = Field(min_length=40, max_length=64)
    enroll_token: str = Field(min_length=16, max_length=128)
    detected_subnets: list[str] = Field(default_factory=list)


class WGPeer(BaseModel):
    pubkey: str
    endpoint: str
    tunnel_ip: str


class EnrollResponse(BaseModel):
    hostname: str
    assigned_tunnel_ip: str
    district_subnet: str
    real_subnets: list[str]
    peers: list[WGPeer]
    persistent_keepalive: int = 25
