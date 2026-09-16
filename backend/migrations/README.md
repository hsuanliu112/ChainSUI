# 資料庫遷移 (Database Migrations)

這個目錄包含所有資料庫結構變更的 SQL 遷移腳本。

## 📋 遷移檔案列表

### 001: 動態定價功能
- **檔案**: `001_add_dynamic_pricing_fields.sql`
- **回滾**: `001_add_dynamic_pricing_fields_rollback.sql`
- **日期**: 2025-10-22
- **說明**: 新增動態定價、優先級和等待時間追蹤欄位

**新增欄位**:
- `surge_multiplier` (FLOAT): 動態加價係數
- `surge_reason` (VARCHAR): 加價原因說明
- `price_type` (VARCHAR): 定價類型（standard/dynamic）
- `priority` (INTEGER): 優先級（1=快速, 2=標準）
- `estimated_wait_minutes` (INTEGER): 預估等待時間
- `actual_wait_minutes` (INTEGER): 實際等待時間

### 008: Refresh token（J1）
- **檔案**: `008_add_refresh_tokens.sql`
- **日期**: 2026-09-16
- **說明**: 新增 `refresh_tokens` 表。只存 sha256 雜湊；每次使用輪替（舊列 `revoked_at` + `replaced_by_id`）；
  已作廢 token 再用視為外洩 → 撤銷該主體全部。`user_id` / `admin_id` 二選一（CHECK 約束）。
- **套用**: `docker compose exec -T db psql -U autodrive -d autodrive_dev -f - < backend/migrations/008_add_refresh_tokens.sql`

## 🚀 如何執行遷移

### 方法 1: Docker 容器內執行

```bash
# 進入 Docker 容器
docker-compose exec backend bash

# 進入 PostgreSQL
psql -U postgres -d autodrive

# 執行遷移
\i /app/migrations/001_add_dynamic_pricing_fields.sql

# 退出
\q
exit
```

### 方法 2: 本地執行（如果有直接連線）

```bash
# 執行遷移
psql -U postgres -d autodrive -f backend/migrations/001_add_dynamic_pricing_fields.sql

# 或使用 Docker Compose
docker-compose exec db psql -U postgres -d autodrive -f /docker-entrypoint-initdb.d/001_add_dynamic_pricing_fields.sql
```

### 方法 3: 使用 SQL 客戶端

1. 連接到 PostgreSQL 資料庫
2. 打開 `001_add_dynamic_pricing_fields.sql`
3. 執行整個腳本

## ↩️ 如何回滾

如果需要撤銷變更：

```bash
# 進入容器
docker-compose exec backend bash

# 進入 PostgreSQL
psql -U postgres -d autodrive

# 執行回滾
\i /app/migrations/001_add_dynamic_pricing_fields_rollback.sql
```

⚠️ **警告**: 回滾會刪除所有動態定價相關資料，請確保有備份！

## ✅ 驗證遷移

執行以下 SQL 驗證欄位是否正確新增：

```sql
-- 查看所有新增的欄位
SELECT column_name, data_type, column_default, is_nullable
FROM information_schema.columns
WHERE table_name = 'trips'
AND column_name IN (
    'surge_multiplier',
    'surge_reason',
    'price_type',
    'priority',
    'estimated_wait_minutes',
    'actual_wait_minutes'
);

-- 查看索引
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'trips'
AND indexname LIKE '%priority%' OR indexname LIKE '%price_type%';

-- 查看約束
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'trips'::regclass
AND conname LIKE '%price%' OR conname LIKE '%priority%' OR conname LIKE '%surge%';
```

## 📝 遷移歷史

| 版本 | 日期 | 說明 | 狀態 |
|------|------|------|------|
| 001 | 2025-10-22 | 動態定價功能 | ✅ 待執行 |

## 🔄 未來整合 Alembic

目前使用手動 SQL 遷移。未來可以考慮整合 Alembic：

```bash
# 初始化 Alembic
alembic init alembic

# 創建遷移
alembic revision --autogenerate -m "Add dynamic pricing fields"

# 執行遷移
alembic upgrade head

# 回滾
alembic downgrade -1
```

## 🆘 故障排除

### 問題：欄位已存在

如果遇到 "column already exists" 錯誤，說明欄位已經新增。可以：
1. 跳過該欄位的 ALTER TABLE 語句
2. 或執行回滾後重新執行

### 問題：約束衝突

如果現有資料不符合新約束：
1. 先檢查現有資料
2. 更新不符合的記錄
3. 然後執行遷移

```sql
-- 檢查現有資料
SELECT COUNT(*) FROM trips WHERE surge_multiplier IS NOT NULL;

-- 更新不符合的記錄
UPDATE trips SET surge_multiplier = 1.0 WHERE surge_multiplier IS NULL;
```

## 📞 聯絡

如有問題，請查看：
- 主要文檔：`/backend/README.md`
- 動態定價文檔：待整合
- WebSocket 文檔：`/WEBSOCKET_IMPLEMENTATION.md`
