# backend/app/schemas/auth.py
"""登入 / refresh 相關 schema（J1）。"""
from typing import Optional

from pydantic import BaseModel, Field


class TokenBundle(BaseModel):
    """所有登入端點與 /auth/refresh 共同回傳的 token 組。"""
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int = Field(..., description="access token 有效秒數")


class ZkLoginResponse(TokenBundle):
    user_id: int
    username: str
    wallet_address: Optional[str] = None
    role: str
    is_new_user: bool


class RefreshRequest(BaseModel):
    refresh_token: str = Field(..., min_length=16)


class LogoutRequest(BaseModel):
    refresh_token: str = Field(..., min_length=16)
