#!/bin/bash
#==================================================
# VPS 一键安全初始化脚本 v3.2 增强版
#==================================================

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -o pipefail

#-------- 配置 --------
SCRIPT_VERSION="3.2"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/vps_init_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/root/vps_backup_$(date +%Y%m%d_%H%M%S)"

#-------- 颜色 --------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; BOLD='\033[1m'; NC='\033[0m'

#-------- 图标 --------
ICON_OK="✅"; ICON_ERR="❌"; ICON_WARN="⚠️"
ICON_INFO="📌"; ICON_ROCKET="🚀"; ICON_LOCK="🔒"
ICON_USER="👤"; ICON_HOST="🖥️"; ICON_CLOCK="🕐"
ICON_PORT="🔌"; ICON_DONE="🎉"; ICON_SHIELD="🛡️"

#-------- 日志函数 --------
log() { 
    echo -e "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"
}

ok() { 
    log "  ${ICON_OK} $*"
}

warn() { 
    log "  ${ICON_WARN} $*"
}

err() { 
    log "  ${ICON_ERR} $*"
    exit 1
}

# 记录特殊事件
log_exec() {
    log "  ⚙️  执行: $*"
    "$@" >> "$LOG_FILE" 2>&1 || {
        err "命令执行失败: $*"
    }
}

#-------- 进度条 --------
progress_bar() {
    local current=$1 total=$2
    local width=30 percent=$((current * 100 / total))
    local filled=$((current * width / total))
    printf "\r  ["
    for ((i=0; i<filled; i++)); do printf "${GREEN}█${NC}"; done
    for ((i=filled; i<width; i++)); do printf "${WHITE}░${NC}"; done
    printf "] %3d%%" $percent
    [ "$current" -eq "$total" ] && echo ""
}

#-------- 步骤标题 --------
step_header() {
    echo -e "\n${CYAN}┌────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} $1"
    echo -e "${CYAN}└────────────────────────────────────────┘${NC}"
}

#-------- 权限检查 --------
check_root() {
    [ "$EUID" -eq 0 ] || err "必须使用root权限运行此脚本"
}

check_os() {
    if [ ! -f "/etc/os-release" ]; then
        err "无法检测操作系统"
    fi
    . /etc/os-release
    OS_TYPE=$(echo "$ID" | tr '[:lower:]' '[:upper:]')
    log "检测到系统: $PRETTY_NAME"
}

#-------- 端口管理 --------
generate_random_port() {
    local port
    local excluded=(21 22 23 25 53 80 110 143 443 465 587 993 995 3306 5432 6379 8080 8443 8888 9090)
    local max_attempts=100
    local attempts=0
    
    while [ $attempts -lt $max_attempts ]; do
        port=$(( RANDOM % 55536 + 10000 ))
        
        # 检查是否在排除列表中
        local excluded_found=0
        for ep in "${excluded[@]}"; do 
            if [ "$port" -eq "$ep" ]; then
                excluded_found=1
                break
            fi
        done
        
        if [ $excluded_found -eq 0 ] && ! ss -tlnp 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
        
        ((attempts++))
    done
    
    err "无法生成可用端口，请手动指定"
}

#-------- 验证函数 --------
validate_hostname() {
    local hostname=$1
    if ! [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]; then
        warn "无效主机名: $hostname"
        warn "主机名规则: 仅包含字母/数字/-，长度1-63，不能以-开头/结尾"
        return 1
    fi
    return 0
}

validate_username() {
    local username=$1
    local reserved=(root bin daemon adm lp sync shutdown halt mail news uucp operator games gopher ftp nobody ntp mysql postgres)
    
    for r in "${reserved[@]}"; do 
        if [ "$username" = "$r" ]; then
            warn "系统保留用户: $username"
            return 1
        fi
    done
    
    if id "$username" &>/dev/null; then
        warn "用户已存在: $username"
        return 1
    fi
    
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        warn "用户名格式错误: $username"
        warn "用户名规则: 以字母或_开头，仅包含字母/数字/_/-"
        return 1
    fi
    
    return 0
}

validate_port() {
    local port=$1
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        warn "端口必须是数字"
        return 1
    fi
    
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        warn "端口范围: 1024-65535"
        return 1
    fi
    
    return 0
}

#-------- SSH相关 --------
safe_sed() {
    local file="$1" pattern="$2" replacement="$3"
    
    if ! grep -q "^${pattern}" "$file" 2>/dev/null; then
        if ! grep -q "^#${pattern}" "$file" 2>/dev/null; then
            echo "$replacement" >> "$file"
            return
        fi
    fi
    
    # 使用 | 作为分隔符避免 / 冲突
    sed -i "s|^#\?${pattern}.*|${replacement}|g" "$file"
}

detect_ssh_service() {
    if systemctl list-units --type=service 2>/dev/null | grep -q "sshd.service"; then
        echo "sshd"
    elif systemctl list-units --type=service 2>/dev/null | grep -q "ssh.service"; then
        echo "ssh"
    else
        echo "ssh"
    fi
}

show_current_port() {
    grep -E "^Port [0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22"
}

validate_sshd_config() {
    local config=$1
    if sshd -t -f "$config" 2>/dev/null; then
        return 0
    else
        warn "SSH配置验证失败"
        return 1
    fi
}

#-------- 主函数 --------
main() {
    check_root
    check_os
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    log "========== VPS初始化开始 =========="
    
    clear
    
    # 顶部横幅
    echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${CYAN}   🚀  VPS 一键安全初始化脚本${NC}              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${WHITE}   v${SCRIPT_VERSION} · 增强安全版${NC}                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"

    # 系统信息概览
    echo -e "\n${WHITE}📋 系统概览${NC}"
    echo -e "  ${ICON_HOST} 主机名   : ${YELLOW}$(hostname)${NC}"
    echo -e "  ${ICON_INFO} 系统     : ${YELLOW}${PRETTY_NAME}${NC}"
    echo -e "  ${ICON_INFO} 内核版本 : ${YELLOW}$(uname -r)${NC}"
    echo -e "  ${ICON_PORT} SSH端口  : ${YELLOW}$(show_current_port)${NC}"
    echo -e "  ${ICON_CLOCK} 当前时间 : ${YELLOW}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"

    # ---- 1. 主机名配置 ----
    step_header "${ICON_HOST} 步骤 1/5 · 主机名配置"
    echo -e "  ${WHITE}示例:${NC} my-server、web-prod-01、game-vps"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 新主机名: "
        read -r NEW_HOSTNAME
        NEW_HOSTNAME=$(echo "$NEW_HOSTNAME" | xargs)
        [ -z "$NEW_HOSTNAME" ] && { warn "主机名不能为空"; continue; }
        validate_hostname "$NEW_HOSTNAME" && break
    done

    # ---- 2. 时区配置 ----
    step_header "${ICON_CLOCK} 步骤 2/5 · 时区配置"
    echo -e "  ${WHITE}常用时区:${NC}"
    echo -e "  ${GREEN}1${NC}) 🇨🇳 Shanghai   ${GREEN}2${NC}) 🇭🇰 HongKong   ${GREEN}3${NC}) 🇯🇵 Tokyo"
    echo -e "  ${GREEN}4${NC}) 🇸🇬 Singapore  ${GREEN}5${NC}) 🇰🇷 Seoul      ${GREEN}6${NC}) 🇹🇼 Taipei"
    echo -e "  ${GREEN}0${NC}) 🌍 自定义"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 请选择 [1]: "
        read -r TZ
        TZ=${TZ:-1}
        case $TZ in
            1) TIMEZONE="Asia/Shanghai"; break;;
            2) TIMEZONE="Asia/Hong_Kong"; break;;
            3) TIMEZONE="Asia/Tokyo"; break;;
            4) TIMEZONE="Asia/Singapore"; break;;
            5) TIMEZONE="Asia/Seoul"; break;;
            6) TIMEZONE="Asia/Taipei"; break;;
            0) echo -ne "  ${CYAN}➤${NC} 输入时区: "; read -r TIMEZONE
               if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
                   break
               else
                   warn "无效时区，请重试"
               fi
               ;;
            *) warn "请输入 0-6";;
        esac
    done

    # ---- 3. 新用户创建 ----
    step_header "${ICON_USER} 步骤 3/5 · 创建管理员用户"
    echo -e "  ${WHITE}示例:${NC} admin、deploy、myuser"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 用户名: "
        read -r NEW_USER
        NEW_USER=$(echo "$NEW_USER" | xargs | tr '[:upper:]' '[:lower:]')
        [ -z "$NEW_USER" ] && { warn "用户名不能为空"; continue; }
        validate_username "$NEW_USER" && break
    done
    
    echo -e "\n  ${WHITE}提示:${NC} 密码至少8位，建议包含大小写字母+数字+特殊字符"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 密码: "
        read -rs USER_PASS
        echo ""
        if [ ${#USER_PASS} -lt 8 ]; then
            warn "密码长度不足8位"
            continue
        fi
        
        echo -ne "  ${CYAN}➤${NC} 再次输入密码: "
        read -rs USER_PASS2
        echo ""
        
        if [ "$USER_PASS" = "$USER_PASS2" ]; then
            break
        else
            warn "两次输入不一致，请重试"
        fi
    done

    # ---- 4. SSH端口配置 ----
    step_header "${ICON_PORT} 步骤 4/5 · SSH端口配置"
    CURRENT_PORT=$(show_current_port)
    RANDOM_PORT=$(generate_random_port)
    
    echo -e "  ${WHITE}当前端口:${NC} ${YELLOW}$CURRENT_PORT${NC}"
    echo -e "  ${WHITE}随机推荐:${NC} ${GREEN}$RANDOM_PORT${NC}"
    echo -e "  ${WHITE}输入数字 = 指定  |  直接回车 = 随机${NC}"
    
    while true; do
        echo -ne "  ${CYAN}➤${NC} 新端口 [回车使用$RANDOM_PORT]: "
        read -r PORT_INPUT
        PORT_INPUT=$(echo "$PORT_INPUT" | xargs)
        
        if [ -z "$PORT_INPUT" ]; then
            NEW_PORT=$RANDOM_PORT
            echo -e "  ${GREEN}→ 已选择端口: $NEW_PORT${NC}"
            break
        fi
        
        validate_port "$PORT_INPUT" || continue
        
        if ss -tlnp 2>/dev/null | grep -q ":$PORT_INPUT "; then
            warn "端口 $PORT_INPUT 已被占用"
            echo -ne "  ${CYAN}➤${NC} 仍要使用? (y/N): "
            read -r FORCE
            if [[ "$FORCE" =~ ^[Yy]$ ]]; then
                NEW_PORT=$PORT_INPUT
                break
            else
                RANDOM_PORT=$(generate_random_port)
                echo -e "  ${GREEN}→ 新推荐端口: $RANDOM_PORT${NC}"
            fi
        else
            NEW_PORT=$PORT_INPUT
            break
        fi
    done

    # ---- 5. 系统更新（可选） ----
    step_header "${ICON_SHIELD} 步骤 5/5 · 系统更新选项"
    echo -e "  ${WHITE}是否更新系统软件包?${NC}"
    echo -e "  ${YELLOW}(1)${NC} 是，执行更新  ${YELLOW}(2)${NC} 否，跳过"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 请选择 [2]: "
        read -r UPDATE_OPT
        UPDATE_OPT=${UPDATE_OPT:-2}
        if [[ "$UPDATE_OPT" =~ ^[12]$ ]]; then
            break
        fi
        warn "请输入 1 或 2"
    done

    # ---- 配置确认 ----
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}          ${WHITE}📋 配置确认清单${NC}                   ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${ICON_HOST} 主机名      : ${GREEN}$NEW_HOSTNAME${NC}"
    echo -e "${BLUE}║${NC}  ${ICON_CLOCK} 时区        : ${GREEN}$TIMEZONE${NC}"
    echo -e "${BLUE}║${NC}  ${ICON_USER} 新用户      : ${GREEN}$NEW_USER${NC}"
    echo -e "${BLUE}║${NC}  ${ICON_PORT} SSH端口     : ${GREEN}$NEW_PORT${NC} ${YELLOW}(原:$CURRENT_PORT)${NC}"
    echo -e "${BLUE}║${NC}  ${ICON_LOCK} Root登录    : ${RED}禁止${NC}"
    echo -e "${BLUE}║${NC}  ${ICON_SHIELD} 系统更新    : $([ "$UPDATE_OPT" = "1" ] && echo "${GREEN}是${NC}" || echo "${YELLOW}否${NC}")${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
    
    echo -ne "\n  ${CYAN}➤${NC} 确认执行以上配置? ${GREEN}(y)${NC}/${RED}(N)${NC}: "
    read -r CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "\n  ${ICON_WARN} 已取消操作"; exit 0; }

    # ---- 执行配置 ----
    clear
    echo -e "\n${CYAN}┌────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${ICON_ROCKET} 正在执行配置，请稍候...          ${CYAN}│${NC}"
    echo -e "${CYAN}└────────────────────────────────────────┘${NC}"
    
    TOTAL_STEPS=5
    CURRENT_STEP=0

    # 1. 主机名配置
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_HOST} 修改主机名..."
    progress_bar 0 1
    
    OLD_HOSTNAME=$(hostname)
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || true
    echo "$NEW_HOSTNAME" > /etc/hostname
    
    # 更新 /etc/hosts
    if grep -q "$OLD_HOSTNAME" /etc/hosts 2>/dev/null; then
        sed -i "s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts 2>/dev/null || true
    else
        echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
    fi
    
    progress_bar 1 1
    ok "主机名: ${GREEN}$OLD_HOSTNAME${NC} → ${GREEN}$NEW_HOSTNAME${NC}"

    # 2. 时区设置
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_CLOCK} 设置时区..."
    progress_bar 0 1
    
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true
    
    progress_bar 1 1
    ok "时区: ${GREEN}$TIMEZONE${NC}"

    # 3. 创建用户
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_USER} 创建用户..."
    progress_bar 0 2
    
    useradd -m -s /bin/bash "$NEW_USER" 2>/dev/null || { warn "用户创建可能失败，继续..."; }
    echo "$NEW_USER:$USER_PASS" | chpasswd 2>/dev/null || { warn "密码设置失败"; }
    
    # 添加到sudo组
    if getent group sudo &>/dev/null; then
        usermod -aG sudo "$NEW_USER" 2>/dev/null || true
    else
        groupadd sudo 2>/dev/null || true
        usermod -aG sudo "$NEW_USER" 2>/dev/null || true
    fi
    
    if getent group wheel &>/dev/null; then
        usermod -aG wheel "$NEW_USER" 2>/dev/null || true
    fi
    
    progress_bar 1 2
    ok "用户 ${GREEN}$NEW_USER${NC} 创建成功"
    
    echo -ne "\n  ${CYAN}➤${NC} 允许无密码sudo? ${GREEN}(y)${NC}/${RED}(N)${NC}: "
    read -r NOPASS
    if [[ "$NOPASS" =~ ^[Yy]$ ]]; then
        echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
        chmod 440 "/etc/sudoers.d/$NEW_USER"
        ok "已配置${GREEN}无密码${NC}sudo"
    else
        ok "sudo权限已授予${YELLOW}(需密码)${NC}"
    fi
    
    progress_bar 2 2

    # 4. SSH配置
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_PORT} 配置SSH服务..."
    progress_bar 0 5
    
    SSH_SERVICE=$(detect_ssh_service)
    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSHD_CONFIG_TEMP="/tmp/sshd_config.new"
    
    # 备份
    cp "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config.bak" 2>/dev/null || true
    cp "$SSHD_CONFIG" /etc/ssh/sshd_config.bak."$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    progress_bar 1 5

    # 修改SSH配置
    cp "$SSHD_CONFIG" "$SSHD_CONFIG_TEMP"
    
    safe_sed "$SSHD_CONFIG_TEMP" "Port" "Port $NEW_PORT"
    safe_sed "$SSHD_CONFIG_TEMP" "PermitRootLogin" "PermitRootLogin no"
    safe_sed "$SSHD_CONFIG_TEMP" "PasswordAuthentication" "PasswordAuthentication yes"
    safe_sed "$SSHD_CONFIG_TEMP" "PubkeyAuthentication" "PubkeyAuthentication yes"
    safe_sed "$SSHD_CONFIG_TEMP" "X11Forwarding" "X11Forwarding no"
    safe_sed "$SSHD_CONFIG_TEMP" "MaxAuthTries" "MaxAuthTries 3"
    safe_sed "$SSHD_CONFIG_TEMP" "ClientAliveInterval" "ClientAliveInterval 300"
    
    # 确保只允许 Protocol 2
    grep -q "^Protocol" "$SSHD_CONFIG_TEMP" 2>/dev/null || echo "Protocol 2" >> "$SSHD_CONFIG_TEMP"
    
    # 添加额外的安全选项
    if ! grep -q "^AllowUsers" "$SSHD_CONFIG_TEMP"; then
        echo "AllowUsers $NEW_USER" >> "$SSHD_CONFIG_TEMP"
    fi
    
    progress_bar 2 5

    # 验证配置
    if validate_sshd_config "$SSHD_CONFIG_TEMP"; then
        mv "$SSHD_CONFIG_TEMP" "$SSHD_CONFIG"
        progress_bar 3 5
        ok "SSH配置已更新"
    else
        warn "SSH配置验证失败，恢复备份..."
        cp "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG"
        rm -f "$SSHD_CONFIG_TEMP"
        err "SSH配置恢复为原配置"
    fi

    # 配置防火墙
    if command -v ufw &>/dev/null; then
        ufw allow "$NEW_PORT"/tcp 2>/dev/null && log "  ufw已开放端口 $NEW_PORT" || true
    fi
    
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="$NEW_PORT"/tcp 2>/dev/null && \
        firewall-cmd --reload 2>/dev/null && \
        log "  firewalld已开放端口 $NEW_PORT" || true
    fi
    
    progress_bar 4 5

    # 重启SSH服务
    echo -e "\n  ${ICON_WARN} 重启SSH服务..."
    if systemctl restart "$SSH_SERVICE" 2>/dev/null; then
        progress_bar 5 5
        ok "SSH服务已重启 ${GREEN}✓${NC}"
    else
        warn "systemctl重启失败，尝试service命令..."
        if service ssh restart 2>/dev/null || service sshd restart 2>/dev/null; then
            ok "SSH服务已重启 ${GREEN}✓${NC}"
        else
            err "SSH服务重启失败"
        fi
    fi

    # 5. 系统更新（可选）
    if [ "$UPDATE_OPT" = "1" ]; then
        ((CURRENT_STEP++))
        echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_SHIELD} 更新系统软件包..."
        progress_bar 0 1
        
        if command -v apt-get &>/dev/null; then
            apt-get update >/dev/null 2>&1 && apt-get upgrade -y >/dev/null 2>&1 && \
            ok "软件包已更新（apt）" || warn "apt更新可能失败"
        elif command -v yum &>/dev/null; then
            yum update -y >/dev/null 2>&1 && \
            ok "软件包已更新（yum）" || warn "yum更新可能失败"
        elif command -v dnf &>/dev/null; then
            dnf update -y >/dev/null 2>&1 && \
            ok "软件包已更新（dnf）" || warn "dnf更新可能失败"
        else
            warn "无法识别包管理器，跳过更新"
        fi
        
        progress_bar 1 1
    fi

    # ---- 完成 ----
    IP_ADDR=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "未知")
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}       ${ICON_DONE}  初始化完成！${ICON_DONE}                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_HOST} 主机名 : ${WHITE}$NEW_HOSTNAME${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_CLOCK} 时区   : ${WHITE}$TIMEZONE${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_USER} 用户   : ${WHITE}$NEW_USER${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_PORT} SSH端口: ${WHITE}$NEW_PORT${NC} ${YELLOW}(原:$CURRENT_PORT)${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_INFO} IP地址 : ${WHITE}$IP_ADDR${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_WARN} ${YELLOW}测试连接 (不要关闭当前会话):${NC}         ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${WHITE}ssh -p $NEW_PORT $NEW_USER@$IP_ADDR${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_INFO} 备份目录: ${WHITE}$BACKUP_DIR${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_INFO} 日志文件: ${WHITE}$LOG_FILE${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    
    log "========== VPS初始化完成 =========="
}

main "$@"
