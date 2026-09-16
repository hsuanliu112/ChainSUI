from datetime import datetime
from typing import Optional

from pydantic import BaseModel, EmailStr, Field


class AdminLoginRequest(BaseModel):
    email: EmailStr
    password: str


class AdminCreateRequest(BaseModel):
    name: str
    email: EmailStr
    password: str = Field(min_length=6)


class AdminInfo(BaseModel):
    id: int
    name: str
    email: EmailStr

    class Config:
        from_attributes = True


class AdminLoginResponse(BaseModel):
    token: str                      # access token（type=admin，60 分）
    refresh_token: str              # J1：30 天，DB 存雜湊、每次使用輪替（dashboard 接 refresh 列後續）
    expires_in: int                 # access 有效秒數
    admin: AdminInfo


class RefundUpdateRequest(BaseModel):
    status: str
    approved_refund_twd: Optional[float] = None
    approved_refund_points: Optional[int] = None
    decision_note: Optional[str] = None


class VehicleStatusUpdate(BaseModel):
    status: str


class TripStatusUpdate(BaseModel):
    status: str
    skip_timestamp: Optional[bool] = False


class GrowthQuery(BaseModel):
    baseDate: Optional[datetime] = None
