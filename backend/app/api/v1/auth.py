# backend/app/api/v1/auth.py
"""
zkLogin 認證 API（Mysten Enoki）— 非託管登入

流程：
  1. Flutter 產臨時金鑰 → POST /auth/zklogin/nonce（取 nonce）
  2. Flutter 用該 nonce 做 Google OAuth → 取得 JWT
  3. POST /auth/zklogin/login（帶 JWT）→ 後端由 Enoki 取 zkLogin 位址 → upsert 使用者 → 發 app JWT
  4.（簽交易時）POST /auth/zklogin/zkp 取 ZK proof（見 zklogin_service / Phase 4 付款流程）
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.core.database import get_async_session
from app.core.rate_limit import rate_limit
from app.models.user import User
from app.schemas.auth import LogoutRequest, RefreshRequest, TokenBundle, ZkLoginResponse
from app.services.auth_service import AuthService, RefreshTokenError
from app.services.zklogin_service import zklogin_service, ZkLoginError

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])


class NonceRequest(BaseModel):
    ephemeral_public_key: str
    additional_epochs: int = 2


class ZkLoginRequest(BaseModel):
    jwt: str
    user_type: str = "passenger"  # 首次登入的預設角色


class ZkpRequest(BaseModel):
    jwt: str
    ephemeral_public_key: str
    max_epoch: int
    randomness: str


@router.post(
    "/zklogin/nonce",
    dependencies=[Depends(rate_limit(times=20, seconds=60, scope="zk-nonce"))],
)
async def zklogin_nonce(body: NonceRequest):
    """建立 zkLogin nonce（Flutter 拿去做 OAuth）。"""
    try:
        return await zklogin_service.create_nonce(body.ephemeral_public_key, body.additional_epochs)
    except ZkLoginError as e:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(e))
    except Exception as e:  # noqa: BLE001
        logger.error(f"zklogin nonce 失敗: {e}")
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=f"Enoki 呼叫失敗: {e}")


@router.post(
    "/zklogin/login",
    response_model=ZkLoginResponse,
    dependencies=[Depends(rate_limit(times=20, seconds=60, scope="zk-login"))],
)
async def zklogin_login(body: ZkLoginRequest, db: AsyncSession = Depends(get_async_session)):
    """用 OAuth JWT 完成 zkLogin：取位址 → upsert 使用者 → 發 app JWT（非託管，無私鑰）。"""
    try:
        info = await zklogin_service.get_address(body.jwt)
    except ZkLoginError as e:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(e))
    except Exception as e:  # noqa: BLE001
        logger.error(f"zklogin get_address 失敗: {e}")
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="JWT 驗證失敗或 Enoki 錯誤")

    address = info.get("address")
    if not address:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail="Enoki 未回傳位址")

    # upsert：以 zkLogin 位址為身分錨
    user = (await db.execute(select(User).where(User.wallet_address == address))).scalar_one_or_none()
    is_new = user is None
    if is_new:
        user = User(
            wallet_address=address,
            username=f"zk_{address[2:12]}",
            user_type=body.user_type,
            is_active=True,
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
        logger.info(f"✅ zkLogin 建立新使用者 {user.id} ({address[:12]}…)")

    bundle = await AuthService(db).issue_bundle_for_user(user)
    return {
        **bundle,
        "user_id": user.id,
        "username": user.username,
        "wallet_address": user.wallet_address,
        "role": user.user_type,
        "is_new_user": is_new,
    }


# ── J1：refresh / logout ─────────────────────────────────────
_REFRESH_DETAIL = {
    "invalid": "refresh_token_invalid",
    "expired": "refresh_token_expired",
    "reused": "refresh_token_reused",
    "inactive": "account_inactive",
}


@router.post(
    "/refresh",
    response_model=TokenBundle,
    dependencies=[Depends(rate_limit(times=30, seconds=60, scope="auth-refresh"))],
)
async def refresh(body: RefreshRequest, db: AsyncSession = Depends(get_async_session)):
    """
    用 refresh token 換一組新的 access + refresh（舊 refresh 立即作廢）。
    不需 Bearer（access 可能已過期）。已作廢 token 再用 → 該帳號全部 refresh 撤銷、回 401。
    """
    svc = AuthService(db)
    try:
        new_refresh, subject_type, subject_id = await svc.rotate(body.refresh_token)
    except RefreshTokenError as e:
        logger.warning(f"refresh 拒絕（{e.reason}）")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=_REFRESH_DETAIL.get(e.reason, "refresh_token_invalid"),
            headers={"WWW-Authenticate": "Bearer"},
        )
    access, expires_in = svc.access_for(subject_type, subject_id)
    return {"access_token": access, "refresh_token": new_refresh, "token_type": "bearer", "expires_in": expires_in}


@router.post(
    "/logout",
    dependencies=[Depends(rate_limit(times=10, seconds=60, scope="auth-logout"))],
)
async def logout(body: LogoutRequest, db: AsyncSession = Depends(get_async_session)):
    """登出當前裝置：作廢這把 refresh token。冪等，不需 Bearer。"""
    await AuthService(db).revoke(body.refresh_token)
    return {"success": True}


@router.post("/logout-all")
async def logout_all(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_async_session)):
    """登出所有裝置：撤銷此使用者全部 refresh token（需有效 access）。"""
    revoked = await AuthService(db).revoke_all(user_id=user.id)
    return {"success": True, "revoked": revoked}


@router.post("/zklogin/zkp")
async def zklogin_zkp(body: ZkpRequest):
    """產生 ZK proof（簽交易前置；由付款/委託/爭議流程呼叫）。"""
    try:
        return await zklogin_service.create_zkp(
            body.jwt, body.ephemeral_public_key, body.max_epoch, body.randomness
        )
    except ZkLoginError as e:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(e))
    except Exception as e:  # noqa: BLE001
        logger.error(f"zklogin zkp 失敗: {e}")
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=f"Enoki 呼叫失敗: {e}")
