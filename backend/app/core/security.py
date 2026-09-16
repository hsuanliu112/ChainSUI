# backend/app/core/security.py
"""
安全認證相關功能：密碼雜湊、JWT 簽發與驗證。

J1（2026-09-16）：
  - access token 帶 `type` claim（一般使用者 "access"、dashboard 管理員 "admin"），
    兩者同 secret 但彼此不可互用。
  - decode 邏輯收斂於 `decode_token`（原本散在 deps / websocket / admin 三處）；
    簽章錯、過期、缺 sub、type 不符一律 raise TokenError（fail-closed）。
  - refresh token 不是 JWT，見 services/auth_service.py。
"""
from datetime import datetime, timedelta, timezone
from typing import Any, Optional, Union

from jose import JWTError, jwt
from passlib.context import CryptContext

from app.config import settings

# 密碼加密 - 使用更簡單的配置避免 bcrypt 版本問題
try:
    pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
except Exception:
    # 如果 bcrypt 有問題，使用 pbkdf2_sha256 作為備選
    pwd_context = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")


def hash_password(password: str) -> str:
    """加密密碼"""
    # 確保密碼不超過 72 字節 (bcrypt 限制)
    if len(password.encode('utf-8')) > 72:
        password = password[:72]
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    """驗證密碼"""
    return pwd_context.verify(plain_password, hashed_password)


class TokenError(Exception):
    """JWT 無法接受（簽章錯 / 過期 / 缺欄位 / type 不符）。"""


def create_access_token(
    subject: Union[str, Any],
    expires_delta: Optional[timedelta] = None,
    token_type: str = "access",
) -> str:
    """簽發短效 JWT。`token_type` 區分一般使用者（access）與管理員（admin）。"""
    now = datetime.now(timezone.utc)
    if expires_delta is None:
        expires_delta = timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = {"exp": now + expires_delta, "iat": now, "sub": str(subject), "type": token_type}
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)


def decode_token(token: str, expected_type: str) -> str:
    """
    驗證 JWT 並回傳 sub。任何不符即 raise TokenError，呼叫端自行映射為 401。
    舊格式（無 type claim）一律拒絕，避免舊 token 混用。
    """
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
    except JWTError as e:
        raise TokenError(str(e)) from e
    if payload.get("type") != expected_type:
        raise TokenError("token type mismatch")
    sub = payload.get("sub")
    if not sub:
        raise TokenError("missing sub")
    return str(sub)


def verify_token(token: str) -> Optional[str]:
    """管理員 token 驗證（dependencies/admin.py 用）；回 admin id 或 None。"""
    try:
        return decode_token(token, "admin")
    except TokenError:
        return None
