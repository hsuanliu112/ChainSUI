# backend/app/services/auth_service.py
"""
AuthService — access / refresh token 發行、輪替、撤銷（J1）

設計（使用者決策）：
  - refresh token = 隨機 opaque 字串（secrets.token_urlsafe），DB 只存 sha256。
  - 每次使用即輪替：舊列 revoked_at 填入、replaced_by_id 指向新列。
  - 已作廢 token 再被使用 = 疑似外洩 → 撤銷該主體所有 refresh token（fail-closed）。
  - access token 為 JWT，帶 type claim（user → "access"，admin → "admin"），15 / 60 分鐘。

查詢順序固定為「token 列 → 主體」，讓整合測試用 FakeSession 依序預排結果。
"""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional, Tuple

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.core.security import create_access_token
from app.models.admin_user import AdminUser
from app.models.refresh_token import RefreshToken
from app.models.user import User


class RefreshTokenError(Exception):
    """reason ∈ {invalid, expired, reused, inactive}；API 層映射成 401 detail。"""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _now() -> datetime:
    return datetime.now(timezone.utc)


class AuthService:
    def __init__(self, db: AsyncSession):
        self.db = db

    # ── 基本工具 ────────────────────────────────────────────
    @staticmethod
    def hash_token(raw: str) -> str:
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    @staticmethod
    def _new_raw() -> str:
        return secrets.token_urlsafe(48)

    def _expiry(self) -> datetime:
        return _now() + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS)

    # ── 發行 ────────────────────────────────────────────────
    async def issue_refresh_token(self, *, user_id: Optional[int] = None, admin_id: Optional[int] = None) -> str:
        """新增一列 refresh token，回傳原文（只此一次）。"""
        if (user_id is None) == (admin_id is None):
            raise ValueError("user_id / admin_id 必須恰好指定一個")
        raw = self._new_raw()
        self.db.add(RefreshToken(
            user_id=user_id, admin_id=admin_id,
            token_hash=self.hash_token(raw), expires_at=self._expiry(),
        ))
        await self.db.commit()
        return raw

    async def issue_bundle_for_user(self, user: User) -> Dict[str, object]:
        minutes = settings.ACCESS_TOKEN_EXPIRE_MINUTES
        access = create_access_token(user.id, timedelta(minutes=minutes), token_type="access")
        refresh = await self.issue_refresh_token(user_id=user.id)
        user.last_login_at = _now()
        await self.db.commit()
        return {"access_token": access, "refresh_token": refresh, "token_type": "bearer", "expires_in": minutes * 60}

    async def issue_bundle_for_admin(self, admin: AdminUser) -> Dict[str, object]:
        minutes = settings.ADMIN_ACCESS_TOKEN_EXPIRE_MINUTES
        access = create_access_token(admin.id, timedelta(minutes=minutes), token_type="admin")
        refresh = await self.issue_refresh_token(admin_id=admin.id)
        return {"access_token": access, "refresh_token": refresh, "token_type": "bearer", "expires_in": minutes * 60}

    # ── 輪替 ────────────────────────────────────────────────
    async def _find(self, raw: str) -> Optional[RefreshToken]:
        stmt = select(RefreshToken).where(RefreshToken.token_hash == self.hash_token(raw))
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def rotate(self, raw: str) -> Tuple[str, str, int]:
        """
        用舊 refresh token 換新的。回 (new_raw, subject_type, subject_id)。
        失敗一律 raise RefreshTokenError；重用 / 主體失效時同時撤銷全家。
        """
        row = await self._find(raw)
        if row is None:
            raise RefreshTokenError("invalid")

        now = _now()
        if row.revoked_at is not None:
            await self.revoke_all(user_id=row.user_id, admin_id=row.admin_id)
            raise RefreshTokenError("reused")
        if row.expires_at <= now:
            row.revoked_at = now
            await self.db.commit()
            raise RefreshTokenError("expired")

        if row.admin_id is not None:
            subject = (await self.db.execute(select(AdminUser).where(AdminUser.id == row.admin_id))).scalar_one_or_none()
            subject_type = "admin"
        else:
            subject = (await self.db.execute(select(User).where(User.id == row.user_id))).scalar_one_or_none()
            subject_type = "user"
        if subject is None or not getattr(subject, "is_active", False):
            await self.revoke_all(user_id=row.user_id, admin_id=row.admin_id)
            raise RefreshTokenError("inactive")

        new_raw = self._new_raw()
        new_row = RefreshToken(
            user_id=row.user_id, admin_id=row.admin_id,
            token_hash=self.hash_token(new_raw), expires_at=self._expiry(),
        )
        self.db.add(new_row)
        row.revoked_at = now
        row.last_used_at = now
        await self.db.commit()
        await self.db.refresh(new_row)
        row.replaced_by_id = new_row.id
        await self.db.commit()
        return new_raw, subject_type, int(subject.id)

    def access_for(self, subject_type: str, subject_id: int) -> Tuple[str, int]:
        """依主體型別簽 access token；回 (token, expires_in 秒)。"""
        if subject_type == "admin":
            minutes = settings.ADMIN_ACCESS_TOKEN_EXPIRE_MINUTES
            return create_access_token(subject_id, timedelta(minutes=minutes), token_type="admin"), minutes * 60
        minutes = settings.ACCESS_TOKEN_EXPIRE_MINUTES
        return create_access_token(subject_id, timedelta(minutes=minutes), token_type="access"), minutes * 60

    # ── 撤銷 ────────────────────────────────────────────────
    async def revoke(self, raw: str) -> None:
        """登出：作廢單一 refresh token。冪等；找不到也靜默（不洩漏存在性）。"""
        row = await self._find(raw)
        if row is not None and row.revoked_at is None:
            row.revoked_at = _now()
            await self.db.commit()

    async def revoke_all(self, *, user_id: Optional[int] = None, admin_id: Optional[int] = None) -> int:
        """撤銷主體所有仍有效的 refresh token（登出所有裝置 / 重用偵測）。回撤銷筆數。"""
        if user_id is None and admin_id is None:
            return 0
        cond = RefreshToken.admin_id == admin_id if admin_id is not None else RefreshToken.user_id == user_id
        stmt = update(RefreshToken).where(cond, RefreshToken.revoked_at.is_(None)).values(revoked_at=_now())
        result = await self.db.execute(stmt)
        await self.db.commit()
        return int(getattr(result, "rowcount", 0) or 0)
