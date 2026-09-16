from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_async_session
from app.core.security import hash_password, verify_password
from app.models import AdminUser
from app.schemas.admin import AdminCreateRequest, AdminInfo, AdminLoginRequest, AdminLoginResponse
from app.services.auth_service import AuthService

router = APIRouter(prefix="/admin/auth", tags=["admin-auth"])


@router.post("/login", response_model=AdminLoginResponse)
async def admin_login(
    payload: AdminLoginRequest,
    session: AsyncSession = Depends(get_async_session),
):
    stmt = select(AdminUser).where(AdminUser.email == payload.email, AdminUser.is_active.is_(True))
    result = await session.execute(stmt)
    admin = result.scalar_one_or_none()

    if not admin or not verify_password(payload.password, admin.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="電子郵件或密碼錯誤")

    # J1：admin access 60 分（type=admin，不可當一般使用者 token 用）+ refresh 30 天
    bundle = await AuthService(session).issue_bundle_for_admin(admin)
    return AdminLoginResponse(
        token=bundle["access_token"],
        refresh_token=bundle["refresh_token"],
        expires_in=bundle["expires_in"],
        admin=AdminInfo.model_validate(admin),
    )


@router.post("/create-admin", response_model=AdminInfo)
async def create_admin(
    payload: AdminCreateRequest,
    session: AsyncSession = Depends(get_async_session),
):
    stmt = select(AdminUser).where(AdminUser.email == payload.email)
    if (await session.execute(stmt)).scalar_one_or_none():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="電子郵件已存在")

    admin = AdminUser(
        name=payload.name,
        email=payload.email,
        password_hash=hash_password(payload.password),
    )
    session.add(admin)
    await session.commit()
    await session.refresh(admin)
    return AdminInfo.model_validate(admin)
