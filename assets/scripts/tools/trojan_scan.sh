#!/bin/bash
#
# trojan_scan.sh - 木马文件扫描工具
# 扫描指定目录，检测常见Web木马/后门文件
#
# Usage: ./trojan_scan.sh [目录路径] [选项]
#   -r    递归扫描子目录
#   -o    输出到文件
#   -h    显示帮助

set -uo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

RECURSIVE=false
OUTPUT_FILE=""
SCAN_DIR="."

usage() {
    echo "Usage: $0 [目录路径] [选项]"
    echo "  -r    递归扫描子目录"
    echo "  -o F  输出报告到文件F"
    echo "  -h    显示帮助"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -r) RECURSIVE=true; shift ;;
        -o) OUTPUT_FILE="$2"; shift 2 ;;
        -h) usage ;;
        -*) echo "未知选项: $1"; usage ;;
        *)  SCAN_DIR="$1"; shift ;;
    esac
done

if [ ! -d "$SCAN_DIR" ]; then
    printf "${RED}[错误] 目录不存在: %s${NC}\n" "$SCAN_DIR"
    exit 1
fi

get_file_time() {
    stat -c "%y" "$1" 2>/dev/null | cut -d'.' -f1 || echo "unknown"
}

get_file_size() {
    stat -c "%s" "$1" 2>/dev/null || echo "0"
}

human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1048576 ]; then
        echo "$((bytes / 1048576))MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$((bytes / 1024))KB"
    else
        echo "${bytes}B"
    fi
}

grepq() {
    grep -qiP "$1" "$2" 2>/dev/null
}

detect_trojan_type() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"
    local result=""

    case "$ext" in
        php|php3|php4|php5|php7|phtml|pht|phps|inc)
            if grepq 'eval\s*\(\s*\$_(POST|GET|REQUEST|COOKIE)' "$file"; then
                result="PHP一句话木马"
            elif grepq 'assert\s*\(\s*\$_(POST|GET|REQUEST)' "$file"; then
                result="PHP一句话木马"
            elif grepq 'eval\s*\(\s*(base64_decode|gzinflate|gzuncompress|str_rot13)' "$file"; then
                result="PHP加密木马"
            elif grepq 'chr\s*\(\s*\d+\s*\)\s*\.\s*chr' "$file"; then
                result="PHP加密木马"
            elif grepq '(system|passthru|shell_exec|popen|proc_open)\s*\(\s*\$_(POST|GET|REQUEST)' "$file"; then
                result="PHP命令执行木马"
            elif grepq 'exec\s*\(\s*\$_(POST|GET|REQUEST)' "$file"; then
                result="PHP命令执行木马"
            elif grepq '(file_put_contents|fputs\s*\(\s*fopen|move_uploaded_file)' "$file" && \
                 grepq '\$_(POST|GET|REQUEST|FILES)' "$file"; then
                result="PHP文件上传木马"
            elif grepq '(c99shell|r57shell|b374k|webshell)' "$file"; then
                result="PHP大马"
            elif grepq 'preg_replace\s*\(.*/e' "$file"; then
                result="PHP后门"
            elif grepq 'create_function\s*\(' "$file" && \
                 grepq '\$_(POST|GET|REQUEST)' "$file"; then
                result="PHP后门"
            elif grepq 'call_user_func\s*\(\s*\$_(POST|GET|REQUEST)' "$file"; then
                result="PHP后门"
            elif grepq '\$\w+\s*\(\s*\$_(POST|GET|REQUEST|COOKIE)' "$file"; then
                result="PHP变形木马"
            elif grepq 'base64_decode\s*\(\s*\$' "$file" && \
                 grepq 'eval\s*\(' "$file"; then
                result="PHP加密木马"
            fi
            ;;
        jsp|jspx)
            if grepq '(behinder|冰蝎)' "$file"; then
                result="JSP冰蝎木马"
            elif grepq '(godzilla|哥斯拉)' "$file"; then
                result="JSP哥斯拉木马"
            elif grepq 'AES.*decrypt|Cipher\.getInstance' "$file" && \
                 grepq '(invoke|defineClass|ClassLoader)' "$file"; then
                result="JSP加密木马(冰蝎/哥斯拉)"
            elif grepq 'defineClass\s*\(' "$file"; then
                result="JSP内存马/类加载木马"
            elif grepq '(ClassLoader|URLClassLoader)' "$file" && \
                 grepq '(getParameter|request)' "$file"; then
                result="JSP类加载木马"
            elif grepq 'Runtime\.getRuntime\(\)\.exec' "$file"; then
                result="JSP命令执行木马"
            elif grepq 'ProcessBuilder' "$file" && \
                 grepq '(getParameter|request)' "$file"; then
                result="JSP命令执行木马"
            elif grepq 'ScriptEngine' "$file" && \
                 grepq 'getParameter' "$file"; then
                result="JSP脚本引擎木马"
            elif grepq 'equals\s*\(\s*"[a-f0-9]{32}"\s*\)' "$file"; then
                result="JSP密码验证后门"
            elif grepq 'pageContext.*invoke' "$file"; then
                result="JSP反射后门"
            fi
            ;;
        java|class)
            if grepq 'Runtime\.getRuntime\(\)\.exec' "$file" && \
               grepq '(getParameter|request|socket)' "$file"; then
                result="Java命令执行后门"
            elif grepq 'defineClass' "$file" && \
                 grepq '(Base64|decode|decrypt)' "$file"; then
                result="Java内存马"
            fi
            ;;
        asp|asa|cer|cdx)
            if grepq '(Execute|Eval)\s*\(\s*Request' "$file"; then
                result="ASP一句话木马"
            elif grepq 'CreateObject.*WScript\.Shell' "$file"; then
                result="ASP命令执行木马"
            elif grepq 'CreateObject.*Shell\.Application' "$file"; then
                result="ASP命令执行木马"
            elif grepq '(cmd\.exe|powershell)' "$file" && \
                 grepq 'Request' "$file"; then
                result="ASP命令执行木马"
            elif grepq 'CreateObject.*Scripting\.FileSystemObject' "$file"; then
                result="ASP文件管理木马"
            fi
            ;;
        aspx)
            if grepq 'Process\.Start' "$file" && \
               grepq 'Request' "$file"; then
                result="ASPX命令执行木马"
            elif grepq '(Eval|Execute)\s*\(\s*Request' "$file"; then
                result="ASPX一句话木马"
            elif grepq 'Assembly\.Load' "$file" && \
                 grepq '(FromBase64|Request)' "$file"; then
                result="ASPX加密木马"
            fi
            ;;
        py)
            if grepq '(os\.system|os\.popen|subprocess)\s*\(.*request\.' "$file"; then
                result="Python命令执行木马"
            elif grepq '(exec|eval)\s*\(\s*request\.' "$file"; then
                result="Python后门"
            elif grepq 'pickle\.loads\s*\(\s*base64' "$file"; then
                result="Python反序列化木马"
            elif grepq '__import__.*os.*system' "$file"; then
                result="Python命令执行木马"
            fi
            ;;
        js|mjs|cjs)
            if grepq 'child_process.*exec\s*\(\s*req\.' "$file"; then
                result="Node.js命令执行后门"
            elif grepq 'eval\s*\(\s*req\.(body|query|params)' "$file"; then
                result="Node.js代码注入后门"
            elif grepq 'Function\s*\(\s*req\.' "$file"; then
                result="Node.js后门"
            elif grepq 'spawn\s*\(\s*req\.' "$file"; then
                result="Node.js命令执行后门"
            fi
            ;;
    esac

    if [ -z "$result" ]; then
        local size
        size=$(get_file_size "$file")
        if [ "$size" -lt 500 ]; then
            if grepq '(eval|exec|system|assert)\s*\(' "$file" && \
               grepq '\$_(POST|GET|REQUEST|COOKIE)' "$file"; then
                result="疑似一句话木马"
            fi
        fi
        if [ -z "$result" ] && grep -qP '^[A-Za-z0-9+/=]{200,}$' "$file" 2>/dev/null; then
            if grepq '(eval|exec|decode|base64)' "$file"; then
                result="疑似编码隐藏木马"
            fi
        fi
    fi

    echo "$result"
}

print_header() {
    printf "${CYAN}%-60s %-22s %-10s %-s${NC}\n" "文件路径" "修改时间" "文件大小" "木马类型"
    printf "%-60s %-22s %-10s %-s\n" "------------------------------------------------------------" "----------------------" "----------" "--------------------"
}

TMPCOUNT=$(mktemp)
trap "rm -f '$TMPCOUNT'" EXIT

report_file() {
    local file="$1"
    local trojan_type="$2"
    local ftime fsize fsize_h

    ftime=$(get_file_time "$file")
    fsize=$(get_file_size "$file")
    fsize_h=$(human_size "$fsize")

    printf "${RED}%-60s${NC} %-22s %-10s ${YELLOW}%-s${NC}\n" "$file" "$ftime" "$fsize_h" "$trojan_type"

    if [ -n "$OUTPUT_FILE" ]; then
        printf "%-60s %-22s %-10s %-s\n" "$file" "$ftime" "$fsize_h" "$trojan_type" >> "$OUTPUT_FILE"
    fi

    echo "1" >> "$TMPCOUNT"
}

scan_file() {
    local file="$1"
    local trojan_type
    trojan_type=$(detect_trojan_type "$file")
    if [ -n "$trojan_type" ]; then
        report_file "$file" "$trojan_type"
    fi
}

printf "${GREEN}[*] 木马文件扫描工具 v1.0${NC}\n"
printf "${GREEN}[*] 扫描目录: %s${NC}\n" "$(cd "$SCAN_DIR" && pwd)"
printf "${GREEN}[*] 递归模式: %s${NC}\n" "$RECURSIVE"
echo ""

if [ -n "$OUTPUT_FILE" ]; then
    > "$OUTPUT_FILE"
    echo "木马扫描报告 - $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_FILE"
    echo "扫描目录: $(cd "$SCAN_DIR" && pwd)" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    printf "%-60s %-22s %-10s %-s\n" "文件路径" "修改时间" "文件大小" "木马类型" >> "$OUTPUT_FILE"
    printf "%-60s %-22s %-10s %-s\n" "------------------------------------------------------------" "----------------------" "----------" "--------------------" >> "$OUTPUT_FILE"
fi

print_header

DEPTH_OPT=""
if [ "$RECURSIVE" = "false" ]; then
    DEPTH_OPT="-maxdepth 1"
fi

EXTENSIONS='.*\.\(php\|php3\|php4\|php5\|php7\|phtml\|pht\|phps\|inc\|jsp\|jspx\|java\|class\|asp\|aspx\|asa\|cer\|cdx\|py\|js\|mjs\|cjs\)'

find "$SCAN_DIR" $DEPTH_OPT -type f -iregex "$EXTENSIONS" 2>/dev/null | while read -r file; do
    scan_file "$file"
done

FOUND_COUNT=$(wc -l < "$TMPCOUNT" | tr -d ' ')

echo ""
printf "${GREEN}[*] 扫描完成，共发现 ${RED}%d${GREEN} 个可疑文件${NC}\n" "$FOUND_COUNT"

if [ -n "$OUTPUT_FILE" ]; then
    echo "" >> "$OUTPUT_FILE"
    echo "共发现 ${FOUND_COUNT} 个可疑文件" >> "$OUTPUT_FILE"
    printf "${GREEN}[*] 报告已保存到: %s${NC}\n" "$OUTPUT_FILE"
fi
