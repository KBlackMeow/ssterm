#!/bin/bash
# 将 assets/scripts/tools/ 下的脚本添加到 assets/scripts/cmd.json
# 用法: ./tool/add_cmd.sh <脚本路径> <名称> <描述>
# 示例: ./tool/add_cmd.sh assets/scripts/tools/memshell_detect.sh "内存马检测" "检测 Java 内存马"

set -euo pipefail

SCRIPT_PATH="${1:-}"
NAME="${2:-}"
DESCRIPTION="${3:-}"
CMD_JSON="assets/scripts/cmd.json"

if [ -z "$SCRIPT_PATH" ] || [ -z "$NAME" ] || [ -z "$DESCRIPTION" ]; then
    echo "用法: $0 <脚本路径> <名称> <描述>"
    echo "示例: $0 assets/scripts/tools/memshell_detect.sh \"内存马检测\" \"检测 Java 内存马\""
    exit 1
fi

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "错误: 脚本文件不存在: $SCRIPT_PATH"
    exit 1
fi

BASENAME=$(basename "$SCRIPT_PATH")
TMPNAME="/tmp/${BASENAME}"

B64=$(base64 "$SCRIPT_PATH" | tr -d '\n')
COMMAND="echo '${B64}' | base64 -d > ${TMPNAME} && chmod +x ${TMPNAME} && bash ${TMPNAME}"

# 用 python3 安全地插入 JSON（避免手动拼接出错）
python3 - "$CMD_JSON" "$NAME" "$DESCRIPTION" "$COMMAND" << 'EOF'
import json, sys

path, name, desc, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

# 检查是否已存在同名条目
for entry in data:
    if entry.get('name') == name:
        print(f"已存在同名条目: {name}，跳过")
        sys.exit(0)

data.append({"name": name, "description": desc, "command": cmd})

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f"已添加: {name}")
EOF
