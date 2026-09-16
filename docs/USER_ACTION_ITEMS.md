# 使用者待辦清單（USER ACTION ITEMS）

> 這是「**需要你本人操作、我（Claude）無法代做**」的事情的**單一清單**。
> 程式碼側我已完成的進度見 `docs/PRODUCTION_HARDENING_ROADMAP.md` §8 變更日誌。
> 完成一項就打勾。最後更新：2026-09-14。

## 🔴 P0 — Mapbox token 輪替（2026-09-05 新增）

兩顆 pk. token（帳號 hy1iii）從最初的 commit 就在 GitHub 歷史裡＝視為已洩漏。
程式碼側我已修好：token 改讀 gitignored 的 `mobile/lib/config/map_config.local.dart`，
被 push protection 點名的未推送 blob 也已用 filter-repo 洗掉；但**舊已推送歷史裡的 token 仍在遠端**。
- 位置：https://account.mapbox.com/access-tokens/
- [ ] 刪除（revoke）這兩顆舊 token（一顆仍有效、一顆已失效但也刪掉）
- [ ] 建新 public token，設 **URL restrictions**，填入 `map_config.local.dart`
- pk token 本屬前端可公開型，風險是被盜用刷配額，輪替＋URL 限制即可，無需重寫已推送歷史

---

## ✅ operator 私鑰輪替（2026-09-14 Claude 已完成鏈上與程式碼側）

`contracts/test_wallet_info.txt` 曾把平台錢包 `0x013a90ee…af36` 的私鑰推上公開 repo。已處理：
新錢包 `0x5b6d84…bf3ac` 重新部署整套合約（新 package `0x95f99809…79b0`，admin cap 全部重 mint 給新錢包），
`.env` / `app_config.dart` / `Published.toml` 同步；舊錢包餘額已清空作廢。**不重寫 git 歷史**（testnet key、無真實價值）。
剩下只有你能做的：
- [ ] **Enoki Portal allowed move call targets 換成新 package**（下方 P0 第 1 節的三行已更新為新值）
- [ ] 舊 OperatorCap 因 `agent` 綁舊地址已失效：實機測試時用戶要**重新委託**一次（app 內 delegation 頁）
- [ ] （選配）退款池注資：`scripts/ops/fund_refund_pool.sh`（active-address 須為新錢包 `platform_operator_v2`）
- [ ] （選配）ZKP 驗證金鑰註冊：用新 `CredentialAdminCap` 呼叫 `credential_verifier::register_verification_key`

---

## 🔴 P0 — 卡住 zkLogin 全部功能（登入/付款/委託/爭議）

### 1. Enoki Portal 設定贊助交易
- 位置：https://portal.enoki.mystenlabs.com → 你的 app（對應 `enoki_public_643a…c75`）
- [ ] **建立 Private API key 並換掉 `.env` 的 `ENOKI_API_KEY`**（2026-09-16 實測：目前填的是 `enoki_public_…`，
  Enoki 對 `/transaction-blocks/sponsor` 回 403 `Private API key required`。public key 只能做登入 nonce/位址；
  贊助交易、委託、爭議全部需要 private key。Portal → API keys → Create private key → 貼進 `.env` → `docker compose up -d --force-recreate backend`）
- [ ] 開啟 **交易贊助（sponsored transactions）** 並**儲值 testnet gas**
- [ ] **允許 move 目標**（allowed move call targets），把下面**三行完整字串**逐一貼上
  （格式 = `package::module::function`；**2026-09-14 金鑰輪替後已換成新 package**，舊 `0xb761c6f5…` 的三行請刪除）：
  ```
  0x95f9980906fb946ffd1c7474e59c9155d9075d62b8c3ca5511b6ca53fed779b0::payment_escrow::lock_payment
  0x95f9980906fb946ffd1c7474e59c9155d9075d62b8c3ca5511b6ca53fed779b0::agent_registry::issue_operator_cap
  0x95f9980906fb946ffd1c7474e59c9155d9075d62b8c3ca5511b6ca53fed779b0::payment_escrow::raise_dispute
  ```
  > package id 的權威來源：`mobile/lib/config/app_config.dart` 的 `contractPackageId`（與 `.env` 的 `CONTRACT_PACKAGE_ID` 一致）。
- ✅ Google Auth Provider 已註冊（我驗證過，這項已完成）

### 2. Google OAuth 同意畫面
- 位置：Google Cloud Console → OAuth consent screen
- [ ] 若專案在「Testing」模式，把你的測試 Google 帳號加進 **Test users**（否則登入會被擋）

### 3. zkLogin 位址領測試幣
- [ ] 第一次 Google 登入拿到 zkLogin 位址後，去 testnet faucet 給它一點 **SUI**
  （付款金額本身由乘客出；gas 由 Enoki 贊助，所以只需覆蓋車資額）

---

## 🟡 P1 — Google Maps（不影響 zkLogin，但影響地圖功能）

新 key `AIzaSyAezZ…lFWk` 已存進 gitignored 檔（`google_maps_config.local.dart` + `.env`），但它有應用限制。
- 位置：Google Cloud Console → Credentials → 該 key
- [ ] **API 限制**：只勾 Directions API、Places API、Geocoding API、Street View Static API
- [ ] **應用程式限制**：iOS app 含 bundle id `com.example.projectDapp`（REST header 我已接）
- [ ] 設**每日配額/預算上限**（防外流被刷）
- [ ] （選填）若要後端也能算真實路線：GCP 另建一把**伺服器 IP 限制**的 key，填進 `.env` 的
  `BACKEND_GOOGLE_MAPS_API_KEY`（未填則後端用直線 fallback，不影響 app）

---

## 🟡 P1.5 — Firebase 推播（選填，app 已能不靠它啟動）

啟動閃退已修好（Firebase key 是佔位符 → 現在會自動跳過，app 照常跑，只是沒推播）。
若要啟用 FCM 推播通知：
- [ ] Firebase Console → 專案設定 → iOS app → 下載真實的 `GoogleService-Info.plist` 放進 `mobile/ios/Runner/`
- [ ] 跑 `flutterfire configure` 更新 `mobile/lib/firebase_options.dart`（把佔位符換成真實值）
- 不做也沒關係——zkLogin / 付款 / 委託 / 爭議 全部功能都不需要 Firebase

---

## 🟢 P2 — 本機驗證（我這環境跑不了 Flutter）

- [x] ~~`cd mobile && flutter pub get && flutter analyze`~~ → 2026-08-13 已由 Claude 代跑：
  **0 error**（修掉範本 widget_test 的 MyApp 引用），剩 17 warning / 402 info（unused/deprecation，無功能影響）
- [ ] 實機/模擬器跑 Google 登入（免助記詞）
- [ ] 實機測付款 → 確認 `execute` 回傳 `escrow_object_id`（鏈上建立 Escrow）
- [ ] 把第一個實機錯誤貼給我（很可能是 Enoki 簽名格式，排查點見 `docs/ZKLOGIN_SETUP.md`）

---

## ⚪ P3 — 資料一致性（低優先，建議清）

- [x] ~~`CLAUDE.md` 過期 package~~ → 2026-09-14 隨金鑰輪替更新為新 package `0x95f99809…79b0`
- [x] ~~`contracts/Published.toml` 仍寫過期 package~~ → 2026-09-14 重新部署後已同步為新 package；
  過期的 `deploy_output.json` / `.package_id` 已刪除

---

## 我（Claude）端的已知後續（不需你動，記錄備查）
- Phase 4/5/6 為 scaffold，待你 P0+P2 完成後依實機結果我來收尾修正。
- Phase 9 死碼清理持續進行（已刪 IOTA/WalletConnect/舊 driver 頁/舊 payment_dialog/sui_contract_service）。
- 詳見 `docs/PRODUCTION_HARDENING_ROADMAP.md` §8。
