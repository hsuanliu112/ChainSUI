# backend/app/models/refresh_token.py
"""
RefreshToken — 長效登入憑證（J1）

只存 sha256 雜湊，原文只在發行當下回給 client。每次使用即輪替：舊列填 revoked_at 並以
replaced_by_id 指向新列。已作廢的 token 再被使用視為外洩，撤銷該主體所有 refresh token。
user_id / admin_id 二選一（DB 有 CHECK 約束）。
"""
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey
from sqlalchemy.sql import func
from app.core.database import Base


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"

    id = Column(Integer, primary_key=True)

    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=True, index=True,
        comment="一般使用者（與 admin_id 二選一）",
    )
    admin_id = Column(
        Integer, ForeignKey("admin_users.id", ondelete="CASCADE"), nullable=True, index=True,
        comment="Dashboard 管理員（與 user_id 二選一）",
    )
    token_hash = Column(
        String(64), nullable=False, unique=True, index=True,
        comment="refresh token 的 sha256 hex；不存原文",
    )
    expires_at = Column(DateTime(timezone=True), nullable=False, comment="到期時間")
    revoked_at = Column(DateTime(timezone=True), nullable=True, comment="輪替 / 登出時填入；非 NULL 再被用 = 重用攻擊")
    replaced_by_id = Column(
        Integer, ForeignKey("refresh_tokens.id", ondelete="SET NULL"), nullable=True,
        comment="輪替後指向新列（稽核）",
    )
    last_used_at = Column(DateTime(timezone=True), nullable=True, comment="最後成功輪替時間")

    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    @property
    def subject_type(self) -> str:
        return "admin" if self.admin_id is not None else "user"

    @property
    def subject_id(self) -> int:
        return self.admin_id if self.admin_id is not None else self.user_id

    def __repr__(self):
        return f"<RefreshToken {self.subject_type}={self.subject_id} revoked={self.revoked_at is not None}>"
