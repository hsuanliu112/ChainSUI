# backend/app/schemas/user.py
"""
User Pydantic 模型 - 區塊鏈版本
支援傳統註冊和錢包註冊
"""

from pydantic import BaseModel, EmailStr, Field, field_validator
from typing import Optional
from datetime import datetime
from enum import Enum

class UserRole(str, Enum):
    """用戶角色枚舉"""
    PASSENGER = "passenger"
    DRIVER = "driver"
    BOTH = "both"
    ADMIN = "admin"

class UserStatus(str, Enum):
    """用戶狀態枚舉"""
    ACTIVE = "active"
    INACTIVE = "inactive"
    SUSPENDED = "suspended"

# === 基礎模型 ===
class UserBase(BaseModel):
    """用戶基礎模型"""
    username: str = Field(..., min_length=3, max_length=50, description="用戶名")
    email: Optional[EmailStr] = Field(None, description="電子郵件（可選）")
    phone: Optional[str] = Field(None, description="手機號碼（可選）")
    role: UserRole = Field(UserRole.PASSENGER, description="用戶角色")

class UserCreate(UserBase):
    """創建用戶模型 - 支援兩種方式"""
    # 區塊鏈相關（新增）
    wallet_address: str = Field(..., description="IOTA 錢包地址")
    did_identifier: Optional[str] = Field(None, description="DID 標識符")
    
    # 傳統欄位（改為可選）
    username: str = Field(..., min_length=3, max_length=50, description="用戶名")
    password: str = Field(..., min_length=8, description="密碼")
    email: Optional[EmailStr] = Field(None, description="郵箱（選填）")
    display_name: Optional[str] = Field(None, max_length=100, description="顯示名稱（選填）")
    user_type: str = Field(default="passenger", description="用戶類型")
    phone_number: Optional[str] = Field(None, description="電話號碼（選填）")
    
    @field_validator('password')
    @classmethod
    def validate_password(cls, v):
        if len(v) < 8:
            raise ValueError('密碼至少需要8個字符')
        return v
    
    @field_validator('wallet_address')
    @classmethod
    def validate_wallet_address(cls, v):
        if not v.startswith('0x') or len(v) != 66:
            raise ValueError('錢包地址格式不正確（應為0x開頭的66位字符）')
        return v.lower()
    
    @field_validator('phone')
    @classmethod
    def validate_phone(cls, v):
        if v and not (v.startswith('09') and len(v) == 10):
            raise ValueError('手機號碼格式不正確')
        return v

# 為了相容性，保留這個別名
UserCreateWithPassword = UserCreate

class UserUpdate(BaseModel):
    """更新用戶模型"""
    email: Optional[EmailStr] = None
    phone: Optional[str] = None
    display_name: Optional[str] = None
    role: Optional[UserRole] = None
    status: Optional[UserStatus] = None
    user_type: Optional[str] = None
    bio: Optional[str] = None
    avatar_url: Optional[str] = None
    @field_validator('user_type')
    @classmethod
    def validate_user_type(cls, v):
        if v and v not in ['passenger', 'driver', 'both']:
            raise ValueError('用戶類型必須是 passenger、driver 或 both')
        return v

class UserResponse(BaseModel):
    """用戶響應模型 - 區塊鏈增強版"""
    id: int
    username: str
    wallet_address: str
    did_identifier: Optional[str] = None
    
    # 基本資訊
    email: Optional[EmailStr] = None
    display_name: Optional[str] = None
    phone_number: Optional[str] = None
    user_type: str = "passenger"
    is_verified: bool = False
    is_active: bool = True
    
    # 時間戳記
    created_at: datetime
    updated_at: Optional[datetime] = None
    
    # 統計信息（區塊鏈版本）
    total_rides_as_passenger: int = 0
    total_rides_as_driver: int = 0
    total_distance_km: int = 0
    reputation_score: int = 50
    is_verified: bool = False
    is_active: bool = True
    
    # 計算屬性
    @property
    def total_rides(self) -> int:
        return self.total_rides_as_passenger + self.total_rides_as_driver
    
    @property
    def short_wallet_address(self) -> str:
        if self.wallet_address and len(self.wallet_address) >= 10:
            return f"{self.wallet_address[:6]}...{self.wallet_address[-4:]}"
        return ""
    
    class Config:
        from_attributes = True

class UserLogin(BaseModel):
    """用戶登錄模型"""
    identifier: str = Field(..., description="用戶名、電子郵件或錢包地址")
    password: str = Field(..., description="密碼")

# 保持相容性
LoginWithPassword = UserLogin

class TokenResponse(BaseModel):
    """Token 響應模型（J1：含 refresh token；expires_in 為 access 有效秒數）"""
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserResponse

# === 新增：錢包相關 Schema ===
class WalletLoginRequest(BaseModel):
    """錢包登入請求"""
    wallet_address: str = Field(..., description="錢包地址")
    signature: str = Field(..., description="簽名")
    message: str = Field(..., description="簽名的訊息")
    
    @field_validator('wallet_address')
    @classmethod
    def validate_wallet_address(cls, v):
        if not v.startswith('0x') or len(v) != 66:
            raise ValueError('錢包地址格式不正確')
        return v.lower()
class LoginWithPassword(BaseModel):
    """登入請求"""
    identifier: str = Field(..., description="用戶名或錢包地址")
    password: str = Field(..., description="密碼")        