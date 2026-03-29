#!/bin/bash
#
# トラフィック生成スクリプト
#
# Blue/Green 両サービスに HTTP リクエストを送り、
# Pixie で観測できる多様なメトリクスを生成する。
#
# 使い方:
#   ./scripts/load-gen.sh [秒数] [1秒あたりのリクエスト数]
#
# 例:
#   ./scripts/load-gen.sh 60 10    # 60秒間、10 RPS で実行
#   ./scripts/load-gen.sh           # デフォルト: 60秒、10 RPS

set -e

DURATION=${1:-60}
RPS=${2:-10}
BLUE_URL="http://localhost:30080"
GREEN_URL="http://localhost:30081"

INTERVAL=$(awk "BEGIN {printf \"%.3f\", 1/$RPS}")

echo "=== hello-k8s-pixie トラフィック生成 ==="
echo "  期間: ${DURATION}秒"
echo "  RPS:  ${RPS}"
echo "  Blue: ${BLUE_URL}"
echo "  Green: ${GREEN_URL}"
echo ""

# 正常リクエスト + 404 リクエストを混ぜることで
# Pixie の HTTP メトリクスにエラー率のデータも生成する
PATHS=("/" "/" "/" "/" "/nonexistent" "/" "/" "/" "/" "/another-404")

START=$(date +%s)
COUNT=0

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  if [ "$ELAPSED" -ge "$DURATION" ]; then
    break
  fi

  # パスをランダムに選択
  PATH_IDX=$((RANDOM % ${#PATHS[@]}))
  REQ_PATH="${PATHS[$PATH_IDX]}"

  # Blue と Green に交互にリクエスト
  if [ $((COUNT % 2)) -eq 0 ]; then
    curl -s -o /dev/null -w "" "${BLUE_URL}${REQ_PATH}" 2>/dev/null &
  else
    curl -s -o /dev/null -w "" "${GREEN_URL}${REQ_PATH}" 2>/dev/null &
  fi

  COUNT=$((COUNT + 1))
  sleep "$INTERVAL"
done

wait

echo ""
echo "=== 完了: ${COUNT} リクエスト送信 (${DURATION}秒) ==="
echo "Pixie でメトリクスを確認: px run -f pxl/http_metrics.pxl"
