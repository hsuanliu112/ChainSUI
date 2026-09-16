# backend/app/api/deps.py
"""
API 依賴項
包含認證、權限檢查等共用邏輯
"""

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from typing import Optional

from app.core.database import get_async_session
from app.core.security import TokenError, decode_token
from app.models.user import User

# JWT Bearer token scheme
security = HTTPBearer()

async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: AsyncSession = Depends(get_async_session)
) -> User:
    """
    從 JWT token 獲取當前用戶
    """
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    
    try:
        # 只接受 type=access 的短效 token（refresh 不是 JWT、admin token 不可互用）
        user_id = decode_token(credentials.credentials, "access")
    except TokenError:
        raise credentials_exception

    # 從資料庫查詢用戶
    stmt = select(User).where(User.id == int(user_id))
    result = await db.execute(stmt)
    user = result.scalar_one_or_none()
    
    if user is None:
        raise credentials_exception
    
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Inactive user"
        )
    
    return user

async def get_current_active_user(
    current_user: User = Depends(get_current_user)
) -> User:
    """
    獲取當前活躍用戶 (額外檢查)
    """
    if not current_user.is_active:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Inactive user"
        )
    return current_user

def require_driver_role(
    current_user: User = Depends(get_current_user)
) -> User:
    """
    要求用戶具有司機角色
    """
    if current_user.user_type not in ['driver', 'both']:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Driver role required"
        )
    return current_user

def require_passenger_role(
    current_user: User = Depends(get_current_user)
) -> User:
    """
    要求用戶具有乘客角色
    """
    if current_user.user_type not in ['passenger', 'both']:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Passenger role required"
        )
    return current_user

# 可選的認證 (用於某些可以匿名訪問但登入後有額外功能的端點)
async def get_current_user_optional(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
    db: AsyncSession = Depends(get_async_session)
) -> Optional[User]:
    """
    可選的用戶認證，如果沒有 token 則返回 None
    """
    if not credentials:
        return None
    
    try:
        user_id = decode_token(credentials.credentials, "access")
    except TokenError:
        return None

    stmt = select(User).where(User.id == int(user_id))
    result = await db.execute(stmt)
    user = result.scalar_one_or_none()

    return user if user and user.is_active else None