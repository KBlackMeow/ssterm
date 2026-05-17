#!/bin/bash
#
# memshell_detect.sh - Java内存马检测工具
# 检测Tomcat/Spring等Java中间件中的内存马(Filter/Servlet/Listener/Valve)
#
# Usage: ./memshell_detect.sh [选项]
#   -t TARGET   目标环境: local / docker:CONTAINER_NAME (默认 local)
#   -p WEBROOT  Tomcat webapps路径 (默认 /usr/local/tomcat)
#   -o FILE     输出报告到文件
#   -c          自动清理(部署检测JSP后自动删除)
#   -h          显示帮助
#
# 检测维度:
#   1. 运行时Filter/Servlet/Listener枚举 (通过JSP探针)
#   2. 磁盘可疑class文件分析
#   3. work目录编译文件特征匹配
#   4. /proc下Java进程异常线程检测

set -uo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TARGET="local"
CATALINA_HOME="/usr/local/tomcat"
OUTPUT_FILE=""
AUTO_CLEAN=true

usage() {
    echo "Usage: $0 [选项]"
    echo "  -t TARGET   目标: local / docker:CONTAINER (默认 local)"
    echo "  -p PATH     Tomcat路径 (默认 /usr/local/tomcat)"
    echo "  -o FILE     输出报告到文件"
    echo "  -c          跳过自动清理(保留检测JSP)"
    echo "  -h          显示帮助"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -t) TARGET="$2"; shift 2 ;;
        -p) CATALINA_HOME="$2"; shift 2 ;;
        -o) OUTPUT_FILE="$2"; shift 2 ;;
        -c) AUTO_CLEAN=false; shift ;;
        -h) usage ;;
        *)  shift ;;
    esac
done

# 执行命令封装(支持docker和本地)
run_cmd() {
    if [[ "$TARGET" == docker:* ]]; then
        local container="${TARGET#docker:}"
        docker exec "$container" sh -c "$1" 2>/dev/null
    else
        sh -c "$1" 2>/dev/null
    fi
}

log() {
    local msg="$1"
    echo -e "$msg"
    if [ -n "$OUTPUT_FILE" ]; then
        echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$OUTPUT_FILE"
    fi
}

TMPCOUNT=$(mktemp)
trap "rm -f '$TMPCOUNT'" EXIT

# ===== 检测阶段1: 获取Java进程信息 =====
detect_java_process() {
    log "${BOLD}${CYAN}[阶段1] Java进程检测${NC}"
    log "----------------------------------------------"

    local pids
    pids=$(run_cmd 'ls /proc/ 2>/dev/null | grep -E "^[0-9]+$" | sort -n')

    for pid in $pids; do
        local cmdline
        cmdline=$(run_cmd "cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' '")
        if echo "$cmdline" | grep -qi "java\|catalina\|tomcat\|spring"; then
            log "${GREEN}  PID: $pid${NC}"
            log "  命令: $(echo $cmdline | cut -c1-120)"

            # 检查线程数
            local thread_count
            thread_count=$(run_cmd "ls /proc/$pid/task/ 2>/dev/null | wc -l")
            log "  线程数: $thread_count"

            # 检查打开的网络连接
            local net_listen
            net_listen=$(run_cmd "cat /proc/$pid/net/tcp 2>/dev/null | awk 'NR>1{print \$2}' | grep -c ':' ")
            log "  网络连接数: $net_listen"
            log ""
        fi
    done
}

# ===== 检测阶段2: 通过JSP探针检测运行时组件 =====
detect_runtime_components() {
    log "${BOLD}${CYAN}[阶段2] 运行时组件检测 (Filter/Servlet/Listener)${NC}"
    log "----------------------------------------------"

    # 查找可写的webapp目录
    local webapps
    webapps=$(run_cmd "find ${CATALINA_HOME}/webapps -maxdepth 1 -type d 2>/dev/null | tail -n+2 | head -5")

    if [ -z "$webapps" ]; then
        log "${YELLOW}  [!] 未找到webapp目录，跳过运行时检测${NC}"
        return
    fi

    local webapp_dir
    webapp_dir=$(echo "$webapps" | head -1)
    local jsp_ts
    jsp_ts=$(date +%s)
    local detect_jsp="${webapp_dir}/_memshell_detect_${jsp_ts}.jsp"
    local local_jsp="/tmp/_memshell_detect_${jsp_ts}.jsp"

    # 生成检测JSP到本地临时文件
    cat > "$local_jsp" << 'JSPEOF'
<%@ page import="java.lang.reflect.Field" %>
<%@ page import="org.apache.catalina.core.ApplicationContext" %>
<%@ page import="org.apache.catalina.core.StandardContext" %>
<%@ page import="java.util.Map" %>
<%@ page import="org.apache.catalina.Container" %>
<%@ page contentType="text/plain;charset=UTF-8" %>
<%
response.setContentType("text/plain;charset=UTF-8");
StringBuilder sb = new StringBuilder();
try {
    ServletContext sc = request.getSession().getServletContext();
    Field f1 = sc.getClass().getDeclaredField("context");
    f1.setAccessible(true);
    ApplicationContext ac = (ApplicationContext) f1.get(sc);
    Field f2 = ac.getClass().getDeclaredField("context");
    f2.setAccessible(true);
    StandardContext ctx = (StandardContext) f2.get(ac);

    sb.append("===FILTERS===\n");
    Field fcf = ctx.getClass().getDeclaredField("filterConfigs");
    fcf.setAccessible(true);
    Map fcs = (Map) fcf.get(ctx);
    for (Object key : fcs.keySet()) {
        Object fc = fcs.get(key);
        Field ff = fc.getClass().getDeclaredField("filter");
        ff.setAccessible(true);
        Object filter = ff.get(fc);
        String cls = (filter != null) ? filter.getClass().getName() : "null";
        String cl = (filter != null && filter.getClass().getClassLoader() != null) ? filter.getClass().getClassLoader().getClass().getName() : "bootstrap";
        java.net.URL url = (filter != null && filter.getClass().getClassLoader() != null) ? filter.getClass().getClassLoader().getResource(cls.replace(".","/") + ".class") : null;
        sb.append("FILTER|").append(key).append("|").append(cls).append("|").append(cl).append("|").append(url != null ? url : "NO_CLASS_FILE").append("\n");
    }

    sb.append("===SERVLETS===\n");
    Container[] children = ctx.findChildren();
    for (Container child : children) {
        String name = child.getName();
        Object inst = null;
        try { Field inf = child.getClass().getDeclaredField("instance"); inf.setAccessible(true); inst = inf.get(child); } catch(Exception e){}
        String cls = (inst != null) ? inst.getClass().getName() : "not_loaded";
        String cl = (inst != null && inst.getClass().getClassLoader() != null) ? inst.getClass().getClassLoader().getClass().getName() : "bootstrap";
        java.net.URL url = null;
        if (inst != null && inst.getClass().getClassLoader() != null) { url = inst.getClass().getClassLoader().getResource(cls.replace(".","/") + ".class"); }
        String[] maps = ctx.findServletMappings();
        String mapping = "";
        for (String m : maps) { if (name.equals(ctx.findServletMapping(m))) mapping += m + ","; }
        sb.append("SERVLET|").append(name).append("|").append(cls).append("|").append(cl).append("|").append(url != null ? url : "NO_CLASS_FILE").append("|").append(mapping).append("\n");
    }

    sb.append("===LISTENERS===\n");
    Object[] listeners = ctx.getApplicationEventListeners();
    for (Object l : listeners) {
        if (l != null) {
            String cls = l.getClass().getName();
            String cl = (l.getClass().getClassLoader() != null) ? l.getClass().getClassLoader().getClass().getName() : "bootstrap";
            java.net.URL url = (l.getClass().getClassLoader() != null) ? l.getClass().getClassLoader().getResource(cls.replace(".","/") + ".class") : null;
            sb.append("LISTENER|").append(cls).append("|").append(cl).append("|").append(url != null ? url : "NO_CLASS_FILE").append("\n");
        }
    }

    sb.append("===VALVES===\n");
    try {
        org.apache.catalina.Valve[] valves = ctx.getPipeline().getValves();
        for (org.apache.catalina.Valve v : valves) {
            String cls = v.getClass().getName();
            String cl = (v.getClass().getClassLoader() != null) ? v.getClass().getClassLoader().getClass().getName() : "bootstrap";
            java.net.URL url = (v.getClass().getClassLoader() != null) ? v.getClass().getClassLoader().getResource(cls.replace(".","/") + ".class") : null;
            sb.append("VALVE|").append(cls).append("|").append(cl).append("|").append(url != null ? url : "NO_CLASS_FILE").append("\n");
        }
    } catch (Exception e) {}

} catch (Exception e) {
    sb.append("ERROR|").append(e.getMessage());
}
out.print(sb.toString());
%>
JSPEOF

    # 部署JSP到目标
    if [[ "$TARGET" == docker:* ]]; then
        local container="${TARGET#docker:}"
        docker cp "$local_jsp" "${container}:${detect_jsp}" 2>/dev/null
    else
        cp "$local_jsp" "$detect_jsp" 2>/dev/null
    fi
    rm -f "$local_jsp"

    # 等待JSP编译
    sleep 2

    # 获取webapp context path
    local ctx_name
    ctx_name=$(basename "$webapp_dir")
    local url_path=""
    if [ "$ctx_name" = "ROOT" ]; then
        url_path=""
    else
        url_path="/$ctx_name"
    fi
    local jsp_name
    jsp_name=$(basename "$detect_jsp")

    # 请求检测JSP
    local result
    result=$(run_cmd "curl -s http://127.0.0.1:8080${url_path}/${jsp_name} 2>/dev/null")

    if [ -z "$result" ] || echo "$result" | grep -q "ERROR"; then
        log "${YELLOW}  [!] 8080端口失败，尝试8443...${NC}"
        result=$(run_cmd "curl -s -k https://127.0.0.1:8443${url_path}/${jsp_name} 2>/dev/null")
    fi

    # 清理检测JSP
    if [ "$AUTO_CLEAN" = true ]; then
        run_cmd "rm -f $detect_jsp"
        # 也删除编译产物
        run_cmd "find ${CATALINA_HOME}/work -name '*_memshell_detect_*' -delete 2>/dev/null"
    fi

    if [ -z "$result" ]; then
        log "${YELLOW}  [!] 无法获取运行时数据${NC}"
        return
    fi

    # 解析结果
    local suspicious=0

    # 已知合法的Filter
    local legit_filters="WsFilter|SetCharacterEncodingFilter|HttpHeaderSecurityFilter|CsrfPreventionFilter|CharacterEncodingFilter|HiddenHttpMethodFilter|FormContentFilter|RequestContextFilter"
    # 已知合法的Servlet
    local legit_servlets="org.apache.catalina.servlets.DefaultServlet|org.apache.jasper.servlet.JspServlet|org.apache.catalina.servlets.CGIServlet|org.springframework.web.servlet.DispatcherServlet"
    # 已知合法的ClassLoader
    local legit_classloaders="java.net.URLClassLoader|sun.misc.Launcher|org.apache.catalina.loader.WebappClassLoader|org.apache.catalina.loader.ParallelWebappClassLoader|org.springframework.boot.loader"

    log ""
    log "  ${BOLD}--- Filters ---${NC}"
    while IFS='|' read -r type name cls classloader classpath; do
        if [ "$type" != "FILTER" ]; then continue; fi
        local is_suspicious=false
        local reasons=""

        # 检查是否使用JasperLoader(JSP编译的类,可能是内存马注入)
        if echo "$classloader" | grep -q "JasperLoader"; then
            is_suspicious=true
            reasons+="[JasperLoader加载] "
        fi
        # 匿名类/内部类
        if echo "$cls" | grep -qE '\$\d+|\$[A-Z].*Filter'; then
            is_suspicious=true
            reasons+="[匿名/内部类] "
        fi
        # 不在合法列表中
        if ! echo "$cls" | grep -qE "$legit_filters"; then
            if echo "$cls" | grep -qiE 'shell|evil|hack|cmd|exec|runtime|behinder|godzilla|冰蝎|哥斯拉|memshell|suo5'; then
                is_suspicious=true
                reasons+="[可疑类名] "
            fi
        fi
        # 没有对应的class文件
        if echo "$classpath" | grep -q "NO_CLASS_FILE"; then
            is_suspicious=true
            reasons+="[无磁盘class文件] "
        fi

        if [ "$is_suspicious" = true ]; then
            log "  ${RED}[!] SUSPICIOUS: $name${NC}"
            log "      类名: $cls"
            log "      加载器: $classloader"
            log "      Class路径: $classpath"
            log "      ${YELLOW}原因: $reasons${NC}"
            suspicious=$((suspicious + 1))
            echo "1" >> "$TMPCOUNT"
        else
            log "  ${GREEN}[OK] $name${NC} -> $cls"
        fi
    done <<< "$result"

    log ""
    log "  ${BOLD}--- Servlets ---${NC}"
    while IFS='|' read -r type name cls classloader classpath mapping; do
        if [ "$type" != "SERVLET" ]; then continue; fi
        local is_suspicious=false
        local reasons=""

        if echo "$classloader" | grep -q "JasperLoader"; then
            is_suspicious=true
            reasons+="[JasperLoader加载] "
        fi
        if echo "$cls" | grep -qE '\$\d+.*Servlet|\$Evil'; then
            is_suspicious=true
            reasons+="[匿名/内部类Servlet] "
        fi
        if echo "$cls" | grep -qiE 'shell|evil|hack|cmd|exec|behinder|godzilla|memshell|suo5'; then
            is_suspicious=true
            reasons+="[可疑类名] "
        fi
        if echo "$classpath" | grep -q "NO_CLASS_FILE"; then
            is_suspicious=true
            reasons+="[无磁盘class文件] "
        fi
        # 可疑路径映射
        if echo "$mapping" | grep -qiE '\.ico$|\.png$|\.gif$|\.css$|\.js$' && ! echo "$cls" | grep -q "DefaultServlet"; then
            is_suspicious=true
            reasons+="[伪装静态资源路径] "
        fi

        if [ "$is_suspicious" = true ]; then
            log "  ${RED}[!] SUSPICIOUS: $name${NC}"
            log "      类名: $cls"
            log "      加载器: $classloader"
            log "      映射: $mapping"
            log "      Class路径: $classpath"
            log "      ${YELLOW}原因: $reasons${NC}"
            suspicious=$((suspicious + 1))
            echo "1" >> "$TMPCOUNT"
        else
            log "  ${GREEN}[OK] $name${NC} -> $cls [$mapping]"
        fi
    done <<< "$result"

    log ""
    log "  ${BOLD}--- Listeners ---${NC}"
    while IFS='|' read -r type cls classloader classpath; do
        if [ "$type" != "LISTENER" ]; then continue; fi
        local is_suspicious=false
        local reasons=""

        if echo "$classloader" | grep -q "JasperLoader"; then
            is_suspicious=true
            reasons+="[JasperLoader加载] "
        fi
        if echo "$classpath" | grep -q "NO_CLASS_FILE"; then
            is_suspicious=true
            reasons+="[无磁盘class文件] "
        fi

        if [ "$is_suspicious" = true ]; then
            log "  ${RED}[!] SUSPICIOUS: $cls${NC}"
            log "      加载器: $classloader"
            log "      ${YELLOW}原因: $reasons${NC}"
            suspicious=$((suspicious + 1))
            echo "1" >> "$TMPCOUNT"
        else
            log "  ${GREEN}[OK] $cls${NC}"
        fi
    done <<< "$result"

    log ""
    log "  ${BOLD}--- Valves ---${NC}"
    while IFS='|' read -r type cls classloader classpath; do
        if [ "$type" != "VALVE" ]; then continue; fi
        local is_suspicious=false
        local reasons=""

        if ! echo "$cls" | grep -qE "^org\.apache\.catalina"; then
            is_suspicious=true
            reasons+="[非标准Valve] "
        fi
        if echo "$classpath" | grep -q "NO_CLASS_FILE"; then
            is_suspicious=true
            reasons+="[无磁盘class文件] "
        fi

        if [ "$is_suspicious" = true ]; then
            log "  ${RED}[!] SUSPICIOUS: $cls${NC}"
            log "      ${YELLOW}原因: $reasons${NC}"
            suspicious=$((suspicious + 1))
            echo "1" >> "$TMPCOUNT"
        else
            log "  ${GREEN}[OK] $cls${NC}"
        fi
    done <<< "$result"

    log ""
}

# ===== 检测阶段3: 磁盘痕迹分析 =====
detect_disk_artifacts() {
    log "${BOLD}${CYAN}[阶段3] 磁盘痕迹分析${NC}"
    log "----------------------------------------------"

    # 检查work目录中的可疑编译文件
    log "  ${BOLD}[3.1] work目录可疑class文件:${NC}"
    local suspicious_classes
    suspicious_classes=$(run_cmd "find ${CATALINA_HOME}/work -name '*.java' -exec grep -l 'defineClass\|Cipher\|AES\|Runtime\.getRuntime\|ProcessBuilder\|ClassLoader.*loadClass\|addFilter\|addServlet\|createWrapper\|behinder\|godzilla' {} \; 2>/dev/null")

    if [ -n "$suspicious_classes" ]; then
        echo "$suspicious_classes" | while read -r f; do
            local ftime fsize
            ftime=$(run_cmd "stat -c '%y' '$f' 2>/dev/null | cut -d. -f1")
            fsize=$(run_cmd "stat -c '%s' '$f' 2>/dev/null")

            # 提取关键特征
            local features
            features=$(run_cmd "grep -oP 'defineClass|Cipher|AES|Runtime\.getRuntime|ProcessBuilder|addFilter|addServlet|createWrapper|behinder|godzilla|冰蝎|哥斯拉' '$f' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//'")

            # 提取FilterName/ServletName
            local inject_name
            inject_name=$(run_cmd "grep -oP '(?:setFilterName|setName|filterName|servletName)\s*[=(]\s*\"?\K[^\";\)]+' '$f' 2>/dev/null | head -1")

            log "  ${RED}[!] $f${NC}"
            log "      时间: $ftime  大小: $fsize bytes"
            log "      ${YELLOW}特征: $features${NC}"
            if [ -n "$inject_name" ]; then
                log "      ${YELLOW}注入名称: $inject_name${NC}"
            fi
            echo "1" >> "$TMPCOUNT"
        done
    else
        log "  ${GREEN}  未发现可疑编译文件${NC}"
    fi

    # 检查webapps中的可疑JSP
    log ""
    log "  ${BOLD}[3.2] webapps可疑JSP文件:${NC}"
    local suspicious_jsps
    suspicious_jsps=$(run_cmd "find ${CATALINA_HOME}/webapps -name '*.jsp' -o -name '*.jspx' 2>/dev/null | xargs grep -l 'defineClass\|Cipher\|AES\|Runtime\.getRuntime\|ProcessBuilder\|ClassLoader\|addFilter\|createWrapper\|behinder\|godzilla\|冰蝎\|哥斯拉' 2>/dev/null")

    if [ -n "$suspicious_jsps" ]; then
        echo "$suspicious_jsps" | while read -r f; do
            local ftime fsize
            ftime=$(run_cmd "stat -c '%y' '$f' 2>/dev/null | cut -d. -f1")
            fsize=$(run_cmd "stat -c '%s' '$f' 2>/dev/null")
            local features
            features=$(run_cmd "grep -oP 'defineClass|Cipher|AES|Runtime\.getRuntime|ProcessBuilder|addFilter|addServlet|createWrapper|behinder|godzilla|冰蝎|哥斯拉' '$f' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//'")

            log "  ${RED}[!] $f${NC}"
            log "      时间: $ftime  大小: $fsize bytes"
            log "      ${YELLOW}特征: $features${NC}"
            echo "1" >> "$TMPCOUNT"
        done
    else
        log "  ${GREEN}  未发现可疑JSP${NC}"
    fi

    # 检查异常的class文件(非标准位置)
    log ""
    log "  ${BOLD}[3.3] 可疑class文件(非标准路径/匿名类):${NC}"
    local anon_classes
    anon_classes=$(run_cmd "find ${CATALINA_HOME}/work -name '*\$*.class' -newer ${CATALINA_HOME}/lib/catalina.jar 2>/dev/null | grep -iP 'Evil|Filter|Servlet|Shell|Cmd|Exec|Mem|Suo'")

    if [ -n "$anon_classes" ]; then
        echo "$anon_classes" | while read -r f; do
            local ftime
            ftime=$(run_cmd "stat -c '%y' '$f' 2>/dev/null | cut -d. -f1")
            log "  ${RED}[!] $f${NC}  ($ftime)"
            echo "1" >> "$TMPCOUNT"
        done
    else
        log "  ${GREEN}  未发现可疑class${NC}"
    fi
}

# ===== 检测阶段4: 网络连接异常检测 =====
detect_network_anomaly() {
    log ""
    log "${BOLD}${CYAN}[阶段4] 网络连接异常检测${NC}"
    log "----------------------------------------------"

    # 检查异常监听端口
    local listening
    listening=$(run_cmd "cat /proc/1/net/tcp 2>/dev/null | awk 'NR>1{split(\$2,a,\":\"); port=strtonum(\"0x\"a[2]); if(port>0) print port}' | sort -un")

    if [ -n "$listening" ]; then
        log "  监听端口: $(echo $listening | tr '\n' ' ')"
    fi

    # 检查外连
    local established
    established=$(run_cmd "cat /proc/1/net/tcp 2>/dev/null | awk '\$4==\"01\"{split(\$3,a,\":\"); printf \"%d.%d.%d.%d:%d\n\", strtonum(\"0x\"substr(a[1],7,2)), strtonum(\"0x\"substr(a[1],5,2)), strtonum(\"0x\"substr(a[1],3,2)), strtonum(\"0x\"substr(a[1],1,2)), strtonum(\"0x\"a[2])}'")

    if [ -n "$established" ]; then
        log "  ${YELLOW}外连地址:${NC}"
        echo "$established" | while read -r conn; do
            log "    $conn"
        done
    else
        log "  ${GREEN}  无异常外连${NC}"
    fi
}

# ===== 主流程 =====
printf "${BOLD}${GREEN}================================================${NC}\n"
printf "${BOLD}${GREEN}  Java内存马检测工具 v1.0${NC}\n"
printf "${BOLD}${GREEN}================================================${NC}\n"
log "目标: $TARGET"
log "Tomcat路径: $CATALINA_HOME"
log "时间: $(date '+%Y-%m-%d %H:%M:%S')"
log ""

if [ -n "$OUTPUT_FILE" ]; then
    > "$OUTPUT_FILE"
    echo "Java内存马检测报告 - $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_FILE"
    echo "目标: $TARGET" >> "$OUTPUT_FILE"
    echo "Tomcat路径: $CATALINA_HOME" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
fi

detect_java_process
log ""
detect_runtime_components
log ""
detect_disk_artifacts
detect_network_anomaly

FOUND_COUNT=$(wc -l < "$TMPCOUNT" | tr -d ' ')

log ""
log "================================================"
if [ "$FOUND_COUNT" -gt 0 ]; then
    log "${RED}${BOLD}[结论] 共发现 $FOUND_COUNT 处可疑内存马痕迹!${NC}"
    log ""
    log "${BOLD}处置建议:${NC}"
    log "  1. 保存证据: 备份work目录和可疑JSP"
    log "  2. 清除内存马:"
    log "     - 重启Tomcat (最彻底,但会中断服务)"
    log "     - 或通过反射移除注入的Filter/Servlet:"
    log "       StandardContext.removeFilterDef(filterName)"
    log "       StandardContext.removeChild(wrapper)"
    log "  3. 删除磁盘木马文件(JSP/class)"
    log "  4. 排查入侵入口(日志审计)"
    log "  5. 修复漏洞(升级组件/修补代码)"
else
    log "${GREEN}${BOLD}[结论] 未发现内存马痕迹${NC}"
fi

if [ -n "$OUTPUT_FILE" ]; then
    log ""
    log "${GREEN}报告已保存: $OUTPUT_FILE${NC}"
fi
