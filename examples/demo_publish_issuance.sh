#!/usr/bin/env bash
# 本轮调用示例：直接发布签发时刻（先取锁、后取时）
#
# 演示要点：
#   1. 相对到期 expires_in_seconds 自实际签发时刻（取齐版本/清单/快照行锁、
#      确认快照仍可发布后）起算，响应 expires_at 与落库一致，首读成功；
#   2. 显式 expires_at 已到点 -> 422 expires_at must be in the future；
#   3. 快照阅览截止 window_close_at 已到点 -> 422 window_close_at must be in the future；
#   4. 两次 422 均整次拒绝：不产生新快照或新令牌。
#
# 行锁等待（并发清单替换/撤回等使等待超过相对时长）由集成测试覆盖：
#   tests/test_integration_api.py 中 test_direct_publish_* 四个用例。
#
# 依赖：curl、jq；服务可用 docker compose up --build 启动。
# 可用 BASE_URL / SERVICE_KEY 覆盖默认配置。
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "0. 健康检查"
curl -sS "${BASE_URL}/healthz" | jq .

step "1. 创建记录（版本 1）"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 11010119903077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
echo "${CREATE}" | jq .
RECORD_ID=$(echo "${CREATE}" | jq -r .record_id)

step "2. 相对到期自签发时刻起算（expires_in_seconds=3600）"
PUB=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "expires_in_seconds": 3600, "max_reads": 5}')
echo "${PUB}" | jq '{snapshot_id, token, expires_at, max_reads}'
SNAPSHOT_ID=$(echo "${PUB}" | jq -r .snapshot_id)
TOKEN=$(echo "${PUB}" | jq -r .token)
EXPIRES_AT=$(echo "${PUB}" | jq -r .expires_at)

step "3. 首次读取立即成功（旧实现在等锁超过时长时此处会 403）"
curl -sS "${BASE_URL}/public/snapshots/${SNAPSHOT_ID}?token=${TOKEN}" | jq .

step "4. 维护侧核对落库到期时刻与响应一致"
curl -sS "${BASE_URL}/tokens/${TOKEN}" "${AUTH[@]}" \
  | jq --arg exp "${EXPIRES_AT}" '{active, reads_used, expires_at, response_matches_db: (.expires_at == $exp)}'

step "5. 显式 expires_at 已到点 -> 422（沿用既有校验错误，整次拒绝）"
curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "expires_at": "2000-01-01T00:00:00Z"}' | jq .

step "6. 快照阅览截止已到点 -> 422（沿用既有校验错误，整次拒绝）"
curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" -d '{
  "version": 1,
  "window_open_at": "2000-01-01T00:00:00Z",
  "window_close_at": "2000-01-02T00:00:00Z"
}' | jq .

step "7. 两次拒绝未留下新令牌：记录下仍只有步骤 2 的快照与令牌"
curl -sS "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" \
  | jq '{snapshots: [.snapshots[] | {version, status, window_open_at, window_close_at}]}'

step "8. 到点撤回优先结算 + 受控/窗口/敏感短语等约定不变（略，见其他 demo）"
echo "  ./examples/demo_withdraw.sh / demo_scheduled_withdraw.sh / demo_controlled.sh"
echo "  ./examples/demo_windows.sh / demo_phrases.sh"

printf '\n\033[1m演示完成。\n提示：行锁等待跨过相对时长/绝对截止的并发场景见集成测试：\n  python3 -m unittest tests.test_integration_api -k direct_publish -v\n\033[0m\n'
