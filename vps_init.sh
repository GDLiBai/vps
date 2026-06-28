#!/bin/bash
#==================================================
# VPS 一键安全初始化脚本 v3.1 UI优化版
#==================================================

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#-------- 颜色 --------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; BOLD='\033[1m'; NC='\033[0m'
LOG_FILE="/var/log/vps_init_$(date +%Y%m%d_%H%M%S).log"

#-------- 图标 --------
ICON_OK="✅"; ICON_ERR="❌"; ICON_WARN="⚠️"
ICON_INFO="📌"; ICON_ROCKET="🚀"; ICON_LOCK="🔒"
ICON_USER="👤"; ICON_HOST="🖥️"; ICON_CLOCK="🕐"
ICON_PORT="🔌"; ICON_DONE="🎉"

#-------- 函数 --------
log() { echo -e "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
ok()  { log "  ${ICON_OK} $*"; }
warn(){ log "  ${ICON_WARN} $*"; }
err() { log "  ${ICON_ERR} $*"; exit 1; }

# 绘制进度条
progress_bar() {
    local current=$1 total=$2
    local width=30 percent=$((current * 100 / total))
    local filled=$((current * width / total))
    printf "\r  ["
    for ((i=0; i<filled; i++)); do printf "${GREEN}█${NC}"; done
    for ((i=filled; i<width; i++)); do printf "${WHITE}░${NC}"; done
    printf "] %3d%%" $percent
}

# 显示步骤标题
step_header() {
    echo -e "\n${CYAN}┌────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} $1"
    echo -e "${CYAN}└────────────────────────────────────────┘${NC}"
}

check_root() {
    [ "$EUID" -eq 0 ] || { echo -e "${RED}${ICON_ERR} 请使用root运行${NC}"; exit 1; }
}

generate_random_port() {
    local port excluded=(21 22 23 25 53 80 110 143 443 465 587 993 995 3306 5432 6379 8080 8443 8888 9090)
    while true; do
        port=$(( RANDOM % 55536 + 10000 ))
        for ep in "${excluded[@]}"; do [ "$port" -eq "$ep" ] && continue 2; done
        ss -tlnp 2>/dev/null | grep -q ":$port " || { echo "$port"; return; }
    done
}

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] || err "无效主机名: $1"
}

validate_username() {
    local u="$1" r
    local reserved=(root bin daemon adm lp sync shutdown halt mail news uucp operator games gopher ftp nobody)
    for r in "${reserved[@]}"; do [ "$u" = "$r" ] && err "系统保留用户: $u"; done
    id "$u" &>/dev/null && err "用户 $u 已存在"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || err "用户名格式错误"
}

safe_sed() {
    local f="$1" p="$2" r="$3"
    grep -q "^${p}" "$f" && sed -i "s/^${p}.*/${r}/" "$f" && return
    grep -q "^#${p}" "$f" && sed -i "s/^#${p}.*/${r}/" "$f" && return
    echo "$r" >> "$f"
}

detect_ssh_service() {
    systemctl list-units --type=service 2>/dev/null | grep -q "sshd.service" && echo "sshd" && return
    systemctl list-units --type=service 2>/dev/null | grep -q "ssh.service" && echo "ssh" && return
    echo "ssh"
}

show_current_port() {
    grep -E "^Port [0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22"
}

#-------- 主流程 --------
main() {
    check_root
    mkdir -p "$(dirname "$LOG_FILE")"
    log "VPS初始化开始"

    clear
    # 顶部横幅
    echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${CYAN}   🚀  VPS 一键安全初始化脚本${NC}              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${WHITE}   v3.1 · 交互优化版${NC}                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"

    # 系统信息概览
    echo -e "\n${WHITE}📋 系统概览${NC}"
    echo -e "  ${ICON_HOST} 主机名 : ${YELLOW}$(hostname)${NC}"
    echo -e "  ${ICON_INFO} 系统   : ${YELLOW}$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "未知")${NC}"
    echo -e "  ${ICON_PORT} SSH端口: ${YELLOW}$(show_current_port)${NC}"
    echo -e "  ${ICON_CLOCK} 时间   : ${YELLOW}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

    # ---- 1. 主机名 ----
    step_header "${ICON_HOST} 步骤 1/4 · 主机名配置"
    echo -e "  ${WHITE}示例:${NC} my-server、web-prod-01、game-vps"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 新主机名: "
        read NEW_HOSTNAME
        validate_hostname "$NEW_HOSTNAME" && break
    done

    # ---- 2. 时区 ----
    step_header "${ICON_CLOCK} 步骤 2/4 · 时区配置"
    echo -e "  ${WHITE}常用时区:${NC}"
    echo -e "  ${GREEN}1${NC}) 🇨🇳 Shanghai   ${GREEN}2${NC}) 🇭🇰 HongKong   ${GREEN}3${NC}) 🇯🇵 Tokyo"
    echo -e "  ${GREEN}4${NC}) 🇸🇬 Singapore  ${GREEN}5${NC}) 🇰🇷 Seoul      ${GREEN}6${NC}) 🇹🇼 Taipei"
    echo -e "  ${GREEN}0${NC}) 🌍 自定义"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 请选择 [1]: "
        read TZ
        TZ=${TZ:-1}
        case $TZ in
            1) TIMEZONE="Asia/Shanghai"; break;;
            2) TIMEZONE="Asia/Hong_Kong"; break;;
            3) TIMEZONE="Asia/Tokyo"; break;;
            4) TIMEZONE="Asia/Singapore"; break;;
            5) TIMEZONE="Asia/Seoul"; break;;
            6) TIMEZONE="Asia/Taipei"; break;;
            0) echo -ne "  ${CYAN}➤${NC} 输入时区: "; read TIMEZONE
               [ -f "/usr/share/zoneinfo/$TIMEZONE" ] && break || warn "无效时区";;
            *) warn "输入0-6";;
        esac
    done

    # ---- 3. 新用户 ----
    step_header "${ICON_USER} 步骤 3/4 · 创建管理员用户"
    echo -e "  ${WHITE}示例:${NC} admin、deploy、myuser"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 用户名: "
        read NEW_USER
        validate_username "$NEW_USER" && break
    done
    
    echo -e "  ${WHITE}提示:${NC} 密码至少6位，建议包含字母+数字"
    while true; do
        echo -ne "  ${CYAN}➤${NC} 密码: "
        read -s USER_PASS; echo
        [ ${#USER_PASS} -ge 6 ] || { warn "长度不足6位"; continue; }
        echo -ne "  ${CYAN}➤${NC} 确认密码: "
        read -s USER_PASS2; echo
        [ "$USER_PASS" = "$USER_PASS2" ] && break || warn "两次输入不一致"
    done

    # ---- 4. SSH端口 ----
    step_header "${ICON_PORT} 步骤 4/4 · SSH端口配置"
    CURRENT_PORT=$(show_current_port)
    RANDOM_PORT=$(generate_random_port)
    
    echo -e "  ${WHITE}当前端口:${NC} ${YELLOW}$CURRENT_PORT${NC}"
    echo -e "  ${WHITE}随机推荐:${NC} ${GREEN}$RANDOM_PORT${NC}"
    echo -e "  ${WHITE}输入数字 = 指定  |  直接回车 = 随机${NC}"
    
    while true; do
        echo -ne "  ${CYAN}➤${NC} 新端口 [随机:$RANDOM_PORT]: "
        read PORT_INPUT
        PORT_INPUT=$(echo "$PORT_INPUT" | xargs)
        if [ -z "$PORT_INPUT" ]; then
            NEW_PORT=$RANDOM_PORT
            echo -e "  ${GREEN}→ 已选择随机端口: $NEW_PORT${NC}"
            break
        fi
        [[ "$PORT_INPUT" =~ ^[0-9]+$ ]] || { warn "端口必须是数字"; continue; }
        [ "$PORT_INPUT" -ge 1024 ] && [ "$PORT_INPUT" -le 65535 ] || { warn "范围: 1024-65535"; continue; }
        if ss -tlnp 2>/dev/null | grep -q ":$PORT_INPUT "; then
            warn "端口 $PORT_INPUT 已被占用"
            echo -ne "  ${CYAN}➤${NC} 仍要使用? (y/N): "
            read FORCE
            [[ "$FORCE" =~ ^[Yy]$ ]] || { RANDOM_PORT=$(generate_random_port); echo -e "  ${GREEN}→ 新推荐端口: $RANDOM_PORT${NC}"; continue; }
        fi
        NEW_PORT=$PORT_INPUT
        break
    done

    # ---- 确认 ----
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}          ${WHITE}📋 配置确认清单${NC}                   ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${ICON_HOST} 主机名  : ${GREEN}$NEW_HOSTNAME${NC}"
    printf "${BLUE}║${NC}  %-*s${NC}  ${BLUE}║${NC}\n" 30 ""
    echo -e "${BLUE}║${NC}  ${ICON_CLOCK} 时区    : ${GREEN}$TIMEZONE${NC}"
    printf "${BLUE}║${NC}  %-*s${NC}  ${BLUE}║${NC}\n" 30 ""
    echo -e "${BLUE}║${NC}  ${ICON_USER} 新用户  : ${GREEN}$NEW_USER${NC}"
    printf "${BLUE}║${NC}  %-*s${NC}  ${BLUE}║${NC}\n" 30 ""
    echo -e "${BLUE}║${NC}  ${ICON_PORT} SSH端口 : ${GREEN}$NEW_PORT${NC} ${YELLOW}(原:$CURRENT_PORT)${NC}"
    printf "${BLUE}║${NC}  %-*s${NC}  ${BLUE}║${NC}\n" 30 ""
    echo -e "${BLUE}║${NC}  ${ICON_LOCK} root登录: ${RED}将被禁止${NC}"
    echo -e "${BLUE}║${NC}                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
    
    echo -ne "\n  ${CYAN}➤${NC} 确认执行以上配置? ${GREEN}(y)${NC}/${RED}(N)${NC}: "
    read CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "\n  ${ICON_WARN} 已取消操作"; exit 0; }

    # ---- 执行配置 ----
    clear
    echo -e "\n${CYAN}┌────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${ICON_ROCKET} 正在执行配置，请稍候...          ${CYAN}│${NC}"
    echo -e "${CYAN}└────────────────────────────────────────┘${NC}"
    
    BACKUP_DIR="/root/vps_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    TOTAL_STEPS=4
    CURRENT_STEP=0

    # 1. 主机名
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_HOST} 修改主机名..."
    progress_bar 0 1
    OLD_HOSTNAME=$(hostname)
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || true
    echo "$NEW_HOSTNAME" > /etc/hostname
    sed -i "s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts 2>/dev/null || true
    grep -q "$NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
    progress_bar 1 1
    ok "主机名: ${GREEN}$OLD_HOSTNAME${NC} → ${GREEN}$NEW_HOSTNAME${NC}"

    # 2. 时区
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_CLOCK} 设置时区..."
    progress_bar 0 1
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true
    progress_bar 1 1
    ok "时区: ${GREEN}$TIMEZONE${NC}"

    # 3. 创建用户
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_USER} 创建用户..."
    progress_bar 0 1
    useradd -m -s /bin/bash "$NEW_USER" 2>/dev/null || true
    echo "$NEW_USER:$USER_PASS" | chpasswd 2>/dev/null || true
    
    getent group sudo &>/dev/null && usermod -aG sudo "$NEW_USER" 2>/dev/null
    getent group wheel &>/dev/null && usermod -aG wheel "$NEW_USER" 2>/dev/null
    getent group sudo &>/dev/null || { groupadd sudo; usermod -aG sudo "$NEW_USER"; }
    progress_bar 1 1
    ok "用户 ${GREEN}$NEW_USER${NC} 创建成功"
    
    echo -ne "  ${CYAN}➤${NC} 允许无密码sudo? ${GREEN}(y)${NC}/${RED}(N)${NC}: "
    read NOPASS
    if [[ "$NOPASS" =~ ^[Yy]$ ]]; then
        echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
        chmod 440 "/etc/sudoers.d/$NEW_USER"
        ok "已配置${GREEN}无密码${NC}sudo"
    else
        ok "sudo权限已授予${YELLOW}(需密码)${NC}"
    fi

    # 4. SSH配置
    ((CURRENT_STEP++))
    echo -e "\n${CYAN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${ICON_PORT} 配置SSH服务..."
    progress_bar 0 3
    
    SSH_SERVICE=$(detect_ssh_service)
    SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config.bak" 2>/dev/null || true
    cp "$SSHD_CONFIG" /etc/ssh/sshd_config.bak.$(date +%Y%m%d) 2>/dev/null || true
    progress_bar 1 3

    safe_sed "$SSHD_CONFIG" "Port" "Port $NEW_PORT"
    safe_sed "$SSHD_CONFIG" "PermitRootLogin" "PermitRootLogin no"
    safe_sed "$SSHD_CONFIG" "PasswordAuthentication" "PasswordAuthentication yes"
    safe_sed "$SSHD_CONFIG" "PubkeyAuthentication" "PubkeyAuthentication yes"
    grep -q "^Protocol" "$SSHD_CONFIG" 2>/dev/null || echo "Protocol 2" >> "$SSHD_CONFIG"
    progress_bar 2 3

    # 防火墙
    if command -v ufw &>/dev/null; then
        ufw allow "$NEW_PORT"/tcp 2>/dev/null && log "  ufw已开放$NEW_PORT" || true
    fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="$NEW_PORT"/tcp 2>/dev/null && firewall-cmd --reload 2>/dev/null
        log "  firewalld已开放$NEW_PORT" || true
    fi

    # 重启SSH
    echo -e "\n  ${ICON_WARN} 重启SSH服务..."
    if sshd -t 2>/dev/null; then
        systemctl restart "$SSH_SERVICE" 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
        progress_bar 3 3
        ok "SSH服务已重启 ${GREEN}✓${NC}"
    else
        warn "SSH配置测试失败，恢复备份..."
        cp "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG" 2>/dev/null
        systemctl restart "$SSH_SERVICE" 2>/dev/null || service ssh restart 2>/dev/null || true
        err "已恢复原配置"
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
    echo -e "${GREEN}║${NC}  ${ICON_INFO} 备份: ${WHITE}$BACKUP_DIR${NC}"
    echo -e "${GREEN}║${NC}  ${ICON_INFO} 日志: ${WHITE}$LOG_FILE${NC}"
    echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

main "$@"
