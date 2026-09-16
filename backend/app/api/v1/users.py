# backend/app/api/v1/users.py
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_async_session
from app.services.user_service import UserService
from app.schemas.user import (
    UserCreate, 
    UserResponse,
    LoginWithPassword,
    TokenResponse,
    UserUpdate,
    UserCreateWithPassword
)
from app.services.auth_service import AuthService

router = APIRouter(prefix="/users", tags=["users"])

@router.post("/register", response_model=UserResponse)
async def register_user(
    user_data: UserCreateWithPassword,
    db: AsyncSession = Depends(get_async_session)
):
    """註冊新用戶"""
    service = UserService(db)
    try:
        user = await service.create_user(user_data)
        return UserResponse.from_orm(user)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )
    except Exception as e:
        import traceback
        error_detail = f"Registration failed: {str(e)}\n{traceback.format_exc()}"
        print(error_detail)  # 打印到控制台
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Registration failed: {str(e)}"
        )

@router.post("/login", response_model=TokenResponse)
async def login(
    credentials: LoginWithPassword,
    db: AsyncSession = Depends(get_async_session)
):
    """用戶登入"""
    service = UserService(db)
    user, error_message = await service.authenticate_user(
        credentials.identifier,  # 可以是 username/email/phone
        credentials.password
    )
    
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=error_message or "登入失敗"
        )
    
    # J1：access 15 分 + refresh 30 天（DB 存雜湊、每次使用輪替）
    bundle = await AuthService(db).issue_bundle_for_user(user)
    return TokenResponse(**bundle, user=UserResponse.from_orm(user))

@router.get("/check-username/{username}")
async def check_username(
    username: str,
    db: AsyncSession = Depends(get_async_session)
):
    """檢查用戶名是否可用"""
    service = UserService(db)
    user = await service.get_user_by_username(username)
    
    return {
        "available": user is None,
        "message": "Username is available" if user is None else "Username already exists"
    }

@router.get("/{user_id}", response_model=UserResponse)
async def get_user(
    user_id: int,
    db: AsyncSession = Depends(get_async_session)
):
    """獲取用戶資訊"""
    service = UserService(db)
    user = await service.get_user_by_id(user_id)

    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )

    return UserResponse.from_orm(user)

@router.patch("/{user_id}", response_model=UserResponse)
async def update_user(
    user_id: int,
    user_data: UserUpdate,
    db: AsyncSession = Depends(get_async_session)
):
    """更新用戶資訊（僅允許用戶本人或管理員更新）"""
    service = UserService(db)

    try:
        user = await service.update_user(user_id, user_data)

        if not user:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="User not found"
            )

        return UserResponse.from_orm(user)

    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Update failed: {str(e)}"
        )