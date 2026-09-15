#!/bin/bash
# 快速更新本地開發 IP：只改 app_config.local.dart 裡的 localBackendUrl 那一行，
# 其餘設定（Google OAuth client id / redirect 等）原封不動。
# 用法：在 repo 根目錄執行  ./update_ip.sh
set -euo pipefail

CONFIG_FILE="mobile/lib/config/app_config.local.dart"
EXAMPLE_FILE="$CONFIG_FILE.example"

# 優先取 Wi-Fi(en0)，沒有再退回第一個非 loopback / 非 169.254 的 IPv4
CURRENT_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [ -z "$CURRENT_IP" ]; then
  CURRENT_IP="$(ifconfig | grep 'inet ' | grep -v 127.0.0.1 | grep -v 169.254 | awk '{print $2}' | head -1)"
fi
if [ -z "$CURRENT_IP" ]; then
  echo "❌ 偵測不到有效 IP，請確認已連上 Wi-Fi 或有線網路"; exit 1
fi
echo "✅ 偵測到 Mac IP: $CURRENT_IP"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "⚠️  $CONFIG_FILE 不存在，從 .example 建立（OAuth 欄位請自行填真值）"
  cp "$EXAMPLE_FILE" "$CONFIG_FILE"
fi

NEW_URL="http://$CURRENT_IP:8000/api/v1"
if grep -q "localBackendUrl" "$CONFIG_FILE"; then
  sed -i '' -E "s|(String get localBackendUrl => ')[^']*(';)|\1$NEW_URL\2|" "$CONFIG_FILE"
else
  printf "\nString get localBackendUrl => '%s';\n" "$NEW_URL" >> "$CONFIG_FILE"
fi

echo "✅ 已更新：$(grep localBackendUrl "$CONFIG_FILE")"
echo ""
echo "接下來："
echo "  1. 確認後端在跑：docker compose ps"
echo "  2. 重新 build 到手機（IP 是編譯進去的，hot reload 不夠）："
echo "     flutter run -d <device-id>            # debug，需由此指令帶起 app"
echo "     flutter run --release -d <device-id>  # release，可從主畫面直接開"
