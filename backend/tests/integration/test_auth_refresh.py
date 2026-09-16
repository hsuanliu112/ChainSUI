"""
J1 refresh token：發行 / 輪替 / 重用偵測 / 過期 / 主體失效 / 登出，以及 decode_token 的 type 隔離。

不變式：
  - DB 只存 sha256，原文不落地。
  - 已作廢 token 再用 → RefreshTokenError("reused") 且撤銷全家（多一次 update）。
  - decode_token 對 type 不符 / 舊格式無 type / 過期 一律 raise TokenError（fail-closed）。
"""
import hashlib
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from jose import jwt

from app.config import settings
from app.core.security import TokenError, create_access_token, decode_token
from app.services.auth_service import AuthService, RefreshTokenError

from tests.integration.conftest import FakeResult

NOW = datetime.now(timezone.utc)


def _row(*, user_id=7, admin_id=None, revoked_at=None, expires_in_days=10):
    return SimpleNamespace(
        id=1, user_id=user_id, admin_id=admin_id,
        token_hash="x" * 64, expires_at=NOW + timedelta(days=expires_in_days),
        revoked_at=revoked_at, replaced_by_id=None, last_used_at=None,
    )


def _user(active=True):
    return SimpleNamespace(id=7, is_active=active, last_login_at=None)


# ── 發行 ────────────────────────────────────────────────

async def test_issue_stores_only_sha256(fake_session_factory):
    db = fake_session_factory()
    raw = await AuthService(db).issue_refresh_token(user_id=7)
    assert len(db.added) == 1
    row = db.added[0]
    assert row.user_id == 7 and row.admin_id is None
    assert row.token_hash == hashlib.sha256(raw.encode()).hexdigest()
    assert raw not in row.token_hash
    assert db.commits == 1


async def test_issue_requires_exactly_one_subject(fake_session_factory):
    svc = AuthService(fake_session_factory())
    with pytest.raises(ValueError):
        await svc.issue_refresh_token()
    with pytest.raises(ValueError):
        await svc.issue_refresh_token(user_id=1, admin_id=2)


async def test_bundle_for_user_writes_last_login(fake_session_factory):
    db = fake_session_factory()
    user = _user()
    bundle = await AuthService(db).issue_bundle_for_user(user)
    assert set(bundle) == {"access_token", "refresh_token", "token_type", "expires_in"}
    assert bundle["expires_in"] == settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60
    assert decode_token(bundle["access_token"], "access") == "7"
    assert user.last_login_at is not None


# ── 輪替 ────────────────────────────────────────────────

async def test_rotate_success_revokes_old_and_adds_new(fake_session_factory):
    old = _row()
    db = fake_session_factory([FakeResult(old), FakeResult(_user())])
    new_raw, subject_type, subject_id = await AuthService(db).rotate("old-raw-token-value")
    assert subject_type == "user" and subject_id == 7
    assert old.revoked_at is not None and old.last_used_at is not None
    assert len(db.added) == 1
    assert db.added[0].token_hash == hashlib.sha256(new_raw.encode()).hexdigest()
    assert old.replaced_by_id == db.added[0].id  # FakeSession.refresh 回填 id
    assert db.results == []


async def test_rotate_unknown_token_is_invalid(fake_session_factory):
    db = fake_session_factory([FakeResult(None)])
    with pytest.raises(RefreshTokenError) as ei:
        await AuthService(db).rotate("nope")
    assert ei.value.reason == "invalid"
    assert db.added == []


async def test_rotate_reused_token_revokes_family(fake_session_factory):
    revoked = _row(revoked_at=NOW - timedelta(minutes=1))
    # 第 2 個結果給 revoke_all 的 update()
    db = fake_session_factory([FakeResult(revoked), FakeResult()])
    with pytest.raises(RefreshTokenError) as ei:
        await AuthService(db).rotate("stolen")
    assert ei.value.reason == "reused"
    assert db.results == []          # 確實執行了撤銷全家的 update
    assert db.commits == 1
    assert db.added == []


async def test_rotate_expired_token(fake_session_factory):
    expired = _row(expires_in_days=-1)
    db = fake_session_factory([FakeResult(expired)])
    with pytest.raises(RefreshTokenError) as ei:
        await AuthService(db).rotate("old")
    assert ei.value.reason == "expired"
    assert expired.revoked_at is not None


async def test_rotate_inactive_subject_revokes_family(fake_session_factory):
    db = fake_session_factory([FakeResult(_row()), FakeResult(_user(active=False)), FakeResult()])
    with pytest.raises(RefreshTokenError) as ei:
        await AuthService(db).rotate("old")
    assert ei.value.reason == "inactive"
    assert db.results == []
    assert db.added == []


async def test_rotate_admin_subject_gives_admin_type(fake_session_factory):
    admin = SimpleNamespace(id=3, is_active=True)
    db = fake_session_factory([FakeResult(_row(user_id=None, admin_id=3)), FakeResult(admin)])
    svc = AuthService(db)
    _, subject_type, subject_id = await svc.rotate("old")
    assert (subject_type, subject_id) == ("admin", 3)
    token, expires_in = svc.access_for(subject_type, subject_id)
    assert decode_token(token, "admin") == "3"
    assert expires_in == settings.ADMIN_ACCESS_TOKEN_EXPIRE_MINUTES * 60
    with pytest.raises(TokenError):
        decode_token(token, "access")   # admin token 不能當 user access 用


# ── 登出 ────────────────────────────────────────────────

async def test_revoke_then_rotate_is_reused(fake_session_factory):
    row = _row()
    db1 = fake_session_factory([FakeResult(row)])
    await AuthService(db1).revoke("raw")
    assert row.revoked_at is not None and db1.commits == 1

    db2 = fake_session_factory([FakeResult(row), FakeResult()])
    with pytest.raises(RefreshTokenError) as ei:
        await AuthService(db2).rotate("raw")
    assert ei.value.reason == "reused"


async def test_revoke_unknown_is_silent(fake_session_factory):
    db = fake_session_factory([FakeResult(None)])
    await AuthService(db).revoke("nope")
    assert db.commits == 0


# ── decode_token / type 隔離 ───────────────────────────

def test_decode_rejects_wrong_type():
    tok = create_access_token(1, token_type="admin")
    with pytest.raises(TokenError):
        decode_token(tok, "access")
    assert decode_token(tok, "admin") == "1"


def test_decode_rejects_legacy_token_without_type():
    legacy = jwt.encode(
        {"exp": datetime.now(timezone.utc) + timedelta(minutes=5), "sub": "1"},
        settings.SECRET_KEY, algorithm=settings.ALGORITHM,
    )
    with pytest.raises(TokenError):
        decode_token(legacy, "access")


def test_decode_rejects_expired():
    tok = create_access_token(1, timedelta(seconds=-1))
    with pytest.raises(TokenError):
        decode_token(tok, "access")


def test_decode_rejects_bad_signature():
    tok = jwt.encode({"exp": datetime.now(timezone.utc) + timedelta(minutes=5), "sub": "1", "type": "access"},
                     "another-secret", algorithm=settings.ALGORITHM)
    with pytest.raises(TokenError):
        decode_token(tok, "access")
