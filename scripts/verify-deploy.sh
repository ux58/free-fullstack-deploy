#!/usr/bin/env bash
# 免费全栈部署端到端验证脚本
# 用法：
#   BASE_URL=https://your-app.onrender.com SETUP_USER=admin SETUP_PASS='你的密码' \
#     bash verify-deploy.sh
# 可选：
#   SKIP_SETUP=1        跳过初始化（管理员已存在时）
#   SETUP_ENDPOINT=/api/auth/setup   自定义初始化端点
# 依赖：curl + node（生成测试文件与 JSON 处理）
set -uo pipefail

BASE_URL="${BASE_URL:?请设置 BASE_URL，如 https://your-app.onrender.com}"
SETUP_USER="${SETUP_USER:?请设置 SETUP_USER}"
SETUP_PASS="${SETUP_PASS:?请设置 SETUP_PASS}"
SETUP_ENDPOINT="${SETUP_ENDPOINT:-/api/auth/setup}"
COOKIE_JAR="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "$COOKIE_JAR"' EXIT
PASS=0; FAIL=0

check() { # check <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then echo "  ✅ $1 ($3)"; PASS=$((PASS+1));
  else echo "  ❌ $1：期望 $2，实际 $3"; FAIL=$((FAIL+1)); fi
}
# node_json <文件> <取值表达式>：解析 JSON 并打印表达式结果（失败输出空串）
# Git Bash 的 /tmp 路径 Windows 版 Node 无法解析，统一转换为 Windows 路径
winpath() { command -v cygpath >/dev/null 2>&1 && cygpath -w "$1" || echo "$1"; }
node_json() { node -e "const fs=require('fs');try{const d=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));const f=eval('(d=>('+process.argv[2]+'))');console.log(f(d))}catch(e){}" "$(winpath "$1")" "$2" 2>/dev/null; }

echo "▶ 1/7 健康检查"
HEALTH=$(curl -s --max-time 60 "$BASE_URL/api/health" -o "$TMP_DIR/health.json" -w "%{http_code}")
check "GET /api/health" "200" "$HEALTH"

echo "▶ 2/7 初始化管理员（409 = 已存在，同样通过）"
CODE=$(curl -s --max-time 60 -c "$COOKIE_JAR" -X POST "$BASE_URL$SETUP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$SETUP_USER\",\"password\":\"$SETUP_PASS\"}" \
  -o "$TMP_DIR/setup.json" -w "%{http_code}")
case "$CODE" in
  201) echo "  ✅ 管理员已创建 (201)"; PASS=$((PASS+1));;
  409) echo "  ✅ 管理员已存在 (409)"; PASS=$((PASS+1));;
  *)   echo "  ❌ 初始化失败：$CODE"; FAIL=$((FAIL+1));;
esac

echo "▶ 3/7 登录"
CODE=$(curl -s --max-time 60 -c "$COOKIE_JAR" -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$SETUP_USER\",\"password\":\"$SETUP_PASS\"}" \
  -o /dev/null -w "%{http_code}")
check "POST /api/auth/login" "200" "$CODE"

echo "▶ 4/7 存储模式（应报告直传能力）"
MODE=$(curl -s --max-time 60 -b "$COOKIE_JAR" "$BASE_URL/api/v1/storage-mode" -o "$TMP_DIR/mode.json" -w "%{http_code}")
check "GET /api/v1/storage-mode" "200" "$MODE"
DIRECT=$(node_json "$TMP_DIR/mode.json" "d.directUpload")
DRIVER=$(node_json "$TMP_DIR/mode.json" "d.driver")
echo "  ℹ️ driver=$DRIVER directUpload=$DIRECT"

echo "▶ 5/7 直传全链路（签发 → PUT → 落库复核）"
printf 'ID3\x03\x00\x00\x00\x00\x00\x00SKILL-VERIFY' > "$TMP_DIR/verify.mp3"
head -c 2048 /dev/zero >> "$TMP_DIR/verify.mp3"
SIZE=$(wc -c < "$TMP_DIR/verify.mp3" | tr -d ' ')
CODE=$(curl -s --max-time 60 -b "$COOKIE_JAR" -X POST "$BASE_URL/api/v1/songs/upload-url" \
  -H "Content-Type: application/json" \
  -d "{\"kind\":\"audio\",\"mime\":\"audio/mpeg\",\"filename\":\"verify.mp3\",\"size\":$SIZE}" \
  -o "$TMP_DIR/signed.json" -w "%{http_code}")
check "POST /api/v1/songs/upload-url" "200" "$CODE"
SONG_ID=""; KEY=""
if [ "$CODE" = "200" ]; then
  URL=$(node_json "$TMP_DIR/signed.json" "d.url")
  KEY=$(node_json "$TMP_DIR/signed.json" "d.key")
  PUT_CODE=$(node -e "
    const fs=require('fs');
    const signed=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
    const body=fs.readFileSync(process.argv[2]);
    fetch(signed.url,{method:'PUT',body,headers:{'Content-Type':'audio/mpeg'}})
      .then(r=>{console.log(r.status);process.exit(0)})
      .catch(()=>{console.log('000');process.exit(0)});
  " "$(winpath "$TMP_DIR/signed.json")" "$(winpath "$TMP_DIR/verify.mp3")")
  check "直传 PUT（含 CORS）" "200" "$PUT_CODE"

  CODE=$(curl -s --max-time 60 -b "$COOKIE_JAR" -X POST "$BASE_URL/api/v1/songs" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Skill 部署验证 $(date +%s)\",\"audioUpload\":{\"key\":\"$KEY\",\"name\":\"verify.mp3\"}}" \
    -o "$TMP_DIR/created.json" -w "%{http_code}")
  check "JSON 创建（服务端 head 复核）" "201" "$CODE"
  SONG_ID=$(node_json "$TMP_DIR/created.json" "d.id")
  STORED_SIZE=$(node_json "$TMP_DIR/created.json" "d.audio?.size ?? 0")
  if [ "$STORED_SIZE" != "0" ] && [ -n "$STORED_SIZE" ]; then
    echo "  ℹ️ 服务端复核对象大小 ${STORED_SIZE}B（客户端声明 ${SIZE}B，以实际为准）"
  fi
else
  echo "  ⚠️ 签发失败（可能存储后端为 local，直传通道未启用）。跳过 5-7 的直传部分。"
fi

echo "▶ 6/7 Range 流式播放（206 分段）"
if [ -n "$KEY" ]; then
  curl -s --max-time 60 -b "$COOKIE_JAR" -H "Range: bytes=0-15" \
    -o "$TMP_DIR/range.bin" -D "$TMP_DIR/range.h" \
    "$BASE_URL/files/$KEY" || true
  STREAM_CODE=$(head -1 "$TMP_DIR/range.h" 2>/dev/null | grep -o "[0-9]\{3\}" || echo 000)
  check "GET /files/<key> 带 Range" "206" "$STREAM_CODE"
  if grep -qi "content-range" "$TMP_DIR/range.h" 2>/dev/null; then
    echo "  ✅ Content-Range 存在"; PASS=$((PASS+1))
  else
    echo "  ❌ 缺少 Content-Range"; FAIL=$((FAIL+1))
  fi
else
  echo "  ⏭️ 无直传键，跳过"
fi

echo "▶ 7/7 清理测试数据"
if [ -n "$SONG_ID" ]; then
  CODE=$(curl -s --max-time 60 -b "$COOKIE_JAR" -X DELETE "$BASE_URL/api/v1/songs/$SONG_ID" \
    -o /dev/null -w "%{http_code}")
  check "DELETE /api/v1/songs/<id>" "204" "$CODE"
else
  echo "  ⏭️ 无测试数据"
fi

echo ""
echo "══════════════════════════════"
echo "结果：$PASS 通过，$FAIL 失败"
[ "$FAIL" = "0" ]
