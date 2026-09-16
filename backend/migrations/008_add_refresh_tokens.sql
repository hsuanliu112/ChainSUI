-- 008_add_refresh_tokens.sql
-- Refresh token 儲存表（J1：access 15 分 + refresh 30 天）。
-- 只存 sha256 雜湊，原文不落地；每次使用即輪替（舊列填 revoked_at、指向新列）。
-- 已作廢 token 再被拿來用 = 疑似外洩 → 撤銷該主體全部 refresh token（見 services/auth_service.rotate）。
-- user_id / admin_id 二選一：dashboard 管理員登入也走同一張表。

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id              SERIAL PRIMARY KEY,
    user_id         INTEGER REFERENCES users(id) ON DELETE CASCADE,
    admin_id        INTEGER REFERENCES admin_users(id) ON DELETE CASCADE,
    token_hash      CHAR(64) NOT NULL UNIQUE,
    expires_at      TIMESTAMPTZ NOT NULL,
    revoked_at      TIMESTAMPTZ,
    replaced_by_id  INTEGER REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    last_used_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_refresh_tokens_one_subject CHECK (num_nonnulls(user_id, admin_id) = 1)
);

CREATE INDEX IF NOT EXISTS ix_refresh_tokens_user_id  ON refresh_tokens (user_id);
CREATE INDEX IF NOT EXISTS ix_refresh_tokens_admin_id ON refresh_tokens (admin_id);

COMMENT ON TABLE  refresh_tokens IS 'Refresh token（僅存 sha256）；每次使用輪替，重用視為外洩';
COMMENT ON COLUMN refresh_tokens.token_hash IS 'refresh token 的 sha256 hex；DB 不存原文';
COMMENT ON COLUMN refresh_tokens.revoked_at IS '輪替或登出時填入；非 NULL 的 token 再被使用視為重用攻擊 → 撤銷全家';
COMMENT ON COLUMN refresh_tokens.replaced_by_id IS '輪替後指向新 token 列（稽核用）';
COMMENT ON COLUMN refresh_tokens.last_used_at IS '最後一次成功輪替的時間';
