#!/usr/bin/env bash

set -euo pipefail

# 配置
KDB_HOST="http://localhost:2113"
KDB_USER="admin"
KDB_PASS="changeit"
PROJECTIONS_DIR="projections"
WAIT_TIME=0.5  # 500 毫秒
STEP_WAIT=2    # 2 秒 (delete 後需等 KurrentDB 非同步清理完成再 create)

# 顏色輸出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 檢查 jq 是否安裝
if ! command -v jq &> /dev/null; then
    echo "錯誤: 需要安裝 jq 來解析 JSON"
    echo "安裝方式: apt-get install jq (Ubuntu/Debian) 或 yum install jq (RHEL/CentOS)"
    exit 1
fi

# 檢查 projections 目錄是否存在
if [ ! -d "$PROJECTIONS_DIR" ]; then
    printf "${YELLOW}目前還沒有 ${PROJECTIONS_DIR} 資料夾${NC}\n"
    exit 0
fi

# 檢查 projection 是否存在
check_projection_exists() {
    local name=$1
    
    local exists=$(curl -s -u "${KDB_USER}:${KDB_PASS}" "${KDB_HOST}/projections/any" \
        | jq -r --arg name "$name" '.projections[] | select(.name == $name) | .name')
    
    if [ -n "$exists" ]; then
        return 0  # 存在
    else
        return 1  # 不存在
    fi
}

# Disable projection
disable_projection() {
    local name=$1
    
    printf "${BLUE}  → Disabling ${name}${NC}\n"
    
    http_code=$(curl -s -o /tmp/kdb_disable.txt -w "%{http_code}" \
        -d{} \
        "${KDB_HOST}/projection/${name}/command/disable" \
        -u "${KDB_USER}:${KDB_PASS}")
    
    if [ "$http_code" -eq 200 ]; then
        printf "${GREEN}  ✓ Disabled${NC}\n"
        sleep "$STEP_WAIT"
        return 0
    else
        printf "${YELLOW}  ⚠ Disable 回應: HTTP ${http_code}${NC}\n"
        sleep "$STEP_WAIT"
        return 0
    fi
}

# Delete projection
delete_projection() {
    local name=$1
    local deleteStateStream="true"
    local deleteCheckpointStream="true"
    local deleteEmittedStreams="true"
    
    printf "${BLUE}  → Deleting ${name}${NC}\n"
    
    http_code=$(curl -s -o /tmp/kdb_delete.txt -w "%{http_code}" \
        -X DELETE \
        "${KDB_HOST}/projection/${name}?deleteStateStream=${deleteStateStream}&deleteCheckpointStream=${deleteCheckpointStream}&deleteEmittedStreams=${deleteEmittedStreams}" \
        -H "accept:application/json" \
        -H "Content-Length:0" \
        -u "${KDB_USER}:${KDB_PASS}")
    
    if [ "$http_code" -eq 200 ]; then
        printf "${GREEN}  ✓ Deleted${NC}\n"
        sleep "$STEP_WAIT"
        return 0
    elif [ "$http_code" -eq 404 ]; then
        printf "${YELLOW}  ⚠ Projection 不存在 (HTTP ${http_code})${NC}\n"
        sleep "$STEP_WAIT"
        return 0
    else
        printf "${RED}  ✗ Delete 失敗 (HTTP ${http_code})${NC}\n"
        cat /tmp/kdb_delete.txt
        sleep "$STEP_WAIT"
        return 1
    fi
}

# 建立 projection
# KurrentDB 的 delete 是非同步：delete 回 200 後實際清理仍在跑，緊接的 create 可能撞
# 「409 Duplicate projection names」。故 create 對 409 自動等待重試（其他錯誤直接失敗）。
create_projection_api() {
    local file=$1
    local name=$2
    local max_attempts=10
    local retry_wait=2

    printf "${BLUE}  → Creating ${name}${NC}\n"

    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        http_code=$(curl -s -o /tmp/kdb_create.txt -w "%{http_code}" \
            --data-binary "@${file}" \
            "${KDB_HOST}/projections/continuous?name=${name}&type=js&enabled=true&emit=true&trackemittedstreams=true" \
            -u "${KDB_USER}:${KDB_PASS}")

        if [ "$http_code" -eq 201 ]; then
            printf "${GREEN}  ✓ Created (HTTP ${http_code})${NC}\n"
            return 0
        elif [ "$http_code" -eq 409 ]; then
            # async delete 尚未清完 → 等待後重試
            printf "${YELLOW}  ⚠ 409 Duplicate（async delete 未清完），等待 ${retry_wait}s 後重試 (${attempt}/${max_attempts})${NC}\n"
            sleep "$retry_wait"
            attempt=$((attempt + 1))
        else
            printf "${RED}  ✗ Create 失敗 (HTTP ${http_code})${NC}\n"
            cat /tmp/kdb_create.txt
            return 1
        fi
    done

    printf "${RED}  ✗ Create 失敗：重試 ${max_attempts} 次仍為 409 Duplicate${NC}\n"
    cat /tmp/kdb_create.txt
    return 1
}

# 處理單一 projection (完整流程)
process_projection() {
    local file=$1
    local name=$(basename "$file" Projection.js)
    
    printf "${YELLOW}處理 projection: ${name}${NC}\n"
    
    if check_projection_exists "$name"; then
        printf "${BLUE}  ℹ Projection 已存在，將進行重建${NC}\n"
        
        disable_projection "$name"
        
        if ! delete_projection "$name"; then
            return 1
        fi
    else
        printf "${BLUE}  ℹ Projection 不存在，直接建立${NC}\n"
    fi
    
    if ! create_projection_api "$file" "$name"; then
        return 1
    fi
    
    printf "${GREEN}✓ ${name} 完成${NC}\n\n"
    return 0
}

# 主程式
main() {
    echo "開始建立 projections..."
    echo "目錄: ${PROJECTIONS_DIR}"
    echo "---"
    
    local success_count=0
    local fail_count=0
    
    # 使用暫存檔收集檔案列表
    local tmpfile="/tmp/kdb_projections_list.txt"
    find "$PROJECTIONS_DIR" -name "*Projection.js" -type f | sort > "$tmpfile"
    
    local total_count=$(wc -l < "$tmpfile")
    
    # 處理每個檔案
    while IFS= read -r file; do
        if process_projection "$file"; then
            success_count=$((success_count + 1))
            sleep "$WAIT_TIME"
        else
            fail_count=$((fail_count + 1))
        fi
    done < "$tmpfile"
    
    # 清理暫存檔
    rm -f "$tmpfile"
    rm -f /tmp/kdb_disable.txt /tmp/kdb_delete.txt /tmp/kdb_create.txt
    
    # 總結
    echo "---"
    printf "完成: 總共 ${total_count} 個 projections\n"
    printf "${GREEN}成功: ${success_count}${NC}\n"
    
    if [ "$fail_count" -gt 0 ]; then
        printf "${RED}失敗: ${fail_count}${NC}\n"
        exit 1
    fi
    
    # 列出所有 projections
    echo ""
    echo "目前所有 projections:"
    curl -s -u "${KDB_USER}:${KDB_PASS}" "${KDB_HOST}/projections/any" | jq -r '.projections[].name'
}

main "$@"
