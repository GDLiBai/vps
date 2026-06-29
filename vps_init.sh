#!/bin/bash
#==================================================
# VPS 一键安全初始化脚本 v4.1 - 代码结构优化 + 快捷命令
# 时区默认：Asia/Hong_Kong
#==================================================
set -o pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/vps_init_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/root/vps_backup_$(date +%Y%m%d_%H%M%S)"

#-------- 颜色（自动检测终端支持）--------
if [ -t 1 ] && command -v tput &>/dev/null && tput setaf 1 &>/dev/null; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; WHITE=''; NC=''
fi

ICON_OK="✅"; ICON_ERR="❌"; ICON_WARN="⚠️"; ICON_INFO="📌"
ICON_ROCKET="🚀"; ICON_LOCK="🔒"; ICON_USER="👤"; ICON_HOST="🖥️"
ICON_CLOCK="🕐"; ICON_PORT="🔌"; ICON_DONE="🎉"; ICON_PKG="📦"
ICON_SWAP="💾"; ICON_BBR="⚡"; ICON_F2B="🛡️"; ICON_MON="📊"
ICON_FW="🔥"; ICON_HARD="🧹"; ICON_CLIENT="🔗"

#-------- 工具函数 --------
log()    { printf "%s %b\n" "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
ok()     { log "  ${ICON_OK} $*"; }
warn()   { log "  ${ICON_WARN} $*"; }
err()    { log "  ${ICON_ERR} $*"; exit 1; }

check_root() {
    [ "$EUID" -eq 0 ] || { printf "%b\n" "${RED}${ICON_ERR} 请使用root运行${NC}"; exit 1; }
}

detect_pkg_manager() {
    if command -v apt &>/dev/null; then
        PKG_MGR="apt"; UPDATE_CMD="apt update -y"; INSTALL_CMD="apt install -y"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"; UPDATE_CMD="dnf check-update -y || true"; INSTALL_CMD="dnf install -y"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"; UPDATE_CMD="yum check-update -y || true"; INSTALL_CMD="yum install -y"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"; UPDATE_CMD="apk update"; INSTALL_CMD="apk add"
    else
        err "不支持的包管理器"
    fi
}

pkg_install() {
    case $PKG_MGR in
        apt) $INSTALL_CMD $* 2>/dev/null || true ;;
        dnf|yum) $INSTALL_CMD epel-release 2>/dev/null || true; $INSTALL_CMD $* 2>/dev/null || true ;;
        apk) $INSTALL_CMD $* 2>/dev/null || true ;;
    esac
}

# 安全确认（仅返回状态码，无多余输出）
confirm() {
    local prompt="$1" default="$2" input
    while true; do
        printf "%b" "$prompt [${default}]: "
        read input
        input=$(echo "$input" | xargs)
        [ -z "$input" ] && input="$default"
        case "$input" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) printf "%b\n" "${YELLOW}请输入 Y 或 N${NC}" ;;
        esac
    done
}

read_nonempty() {
    local prompt="$1" var_name="$2" input
    while true; do
        printf "%b" "$prompt"
        read input
        input=$(echo "$input" | xargs)
        if [ -n "$input" ]; then eval "$var_name=\"$input\""; return; fi
        printf "%b\n" "${YELLOW}输入不能为空${NC}"
    done
}

generate_random_port() {
    local port
    local excluded=(21 22 23 25 53 80 110 143 443 465 587 993 995 3306 5432 6379 8080 8443 8888 9090)
    while true; do
        port=$(( RANDOM % 55536 + 10000 ))
        for ep in "${excluded[@]}"; do [ "$port" -eq "$ep" ] && continue 2; done
        ss -tlnp 2>/dev/null | grep -q ":$port " || { echo "$port"; return; }
    done
}

validate_hostname() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] || err "无效主机名: $1"; }

validate_username() {
    local u="$1" r
    local reserved=(root bin daemon adm lp sync shutdown halt mail news uucp operator games gopher ftp nobody)
    for r in "${reserved[@]}"; do [ "$u" = "$r" ] && err "系统保留用户: $u"; done
    id "$u" &>/dev/null && err "用户 $u 已存在"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || err "用户名格式错误"
}

safe_sed() {
    local f="$1" p="$2" r="$3"
    if grep -q "^${p}" "$f" 2>/dev/null; then
        sed -i "s/^${p}.*/${r}/" "$f"
    elif grep -q "^#${p}" "$f" 2>/dev/null; then
        sed -i "s/^#${p}.*/${r}/" "$f"
    else
        echo "$r" >> "$f"
    fi
}

detect_ssh_service() {
    systemctl list-units --type=service 2>/dev/null | grep -q "sshd.service" && echo "sshd" && return
    systemctl list-units --type=service 2>/dev/null | grep -q "ssh.service" && echo "ssh" && return
    echo "ssh"
}

show_current_port() { grep -E "^Port [0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22"; }

restart_ssh() {
    local svc="$1"
    systemctl restart "$svc" 2>/dev/null || service "$svc" restart 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
}

# 显示系统信息（精简版）
show_system_info() {
    clear
    printf "%b\n" "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${BLUE}║${NC}           ${WHITE}📋 当前系统配置详情${NC}               ${BLUE}║${NC}"
    printf "%b\n" "${BLUE}╚══════════════════════════════════════════════╝${NC}"
    [ -f /etc/os-release ] && { . /etc/os-release; OS_NAME="${PRETTY_NAME:-$NAME $VERSION}"; } || OS_NAME="未知"
    KERNEL=$(uname -r)
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | xargs || echo "未知")
    CPU_CORES=$(nproc 2>/dev/null || echo "未知")
    MEM_TOTAL=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo "未知")
    MEM_USED=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}' || echo "未知")
    DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}' || echo "未知")
    IPV4=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "未知")
    CLIENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    [ -z "$CLIENT_IP" ] && CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    [ -z "$CLIENT_IP" ] && CLIENT_IP="本地/未知"
    CURRENT_HOST=$(hostname)
    CURRENT_SSH=$(show_current_port)
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "未知")
    SWAP_INFO=$(swapon --show 2>/dev/null | awk 'NR>1{print $3}' | paste -sd+ | bc 2>/dev/null)
    [ -z "$SWAP_INFO" ] && SWAP_INFO="无"
    USERS=$(who | awk '{print $1}' | sort -u | paste -sd,)
    [ -z "$USERS" ] && USERS="无"

    printf "%b\n" "  ${ICON_INFO} 系统    : ${GREEN}${OS_NAME}${NC}"
    printf "%b\n" "  ${ICON_INFO} 内核    : ${GREEN}${KERNEL}${NC}"
    printf "%b\n" "  ${ICON_INFO} CPU     : ${GREEN}${CPU_MODEL} (${CPU_CORES} 核)${NC}"
    printf "%b\n" "  ${ICON_INFO} 内存    : ${GREEN}${MEM_USED} / ${MEM_TOTAL}${NC}"
    printf "%b\n" "  ${ICON_INFO} 磁盘    : ${GREEN}${DISK_INFO}${NC}"
    printf "%b\n" "  ${ICON_INFO} 公网IP  : ${GREEN}${IPV4}${NC}"
    printf "%b\n" "  ${ICON_CLIENT} 连接IP  : ${GREEN}${CLIENT_IP}${NC}"
    printf "%b\n" "  ${ICON_HOST} 主机名  : ${YELLOW}${CURRENT_HOST}${NC}"
    printf "%b\n" "  ${ICON_PORT} SSH端口 : ${YELLOW}${CURRENT_SSH}${NC}"
    printf "%b\n" "  ${ICON_CLOCK} 时区    : ${YELLOW}${CURRENT_TZ}${NC}"
    printf "%b\n" "  ${ICON_SWAP} Swap    : ${YELLOW}${SWAP_INFO}${NC}"
    printf "%b\n" "  ${ICON_USER} 在线用户: ${YELLOW}${USERS}${NC}"
    printf "\n"
    read -rp "  按回车键继续初始化..." dummy
}

#---- 扩展功能 ----
install_base_packages() {
    printf "\n%b\n" "${CYAN}[扩展]${NC} ${ICON_PKG} 安装基础软件包..."
    pkg_install curl wget vim git htop net-tools unzip zip lrzsz
    ok "基础软件包安装完成"
}

enable_bbr() {
    printf "\n%b\n" "${CYAN}[扩展]${NC} ${ICON_BBR} 开启 BBR..."
    [ $(uname -r | cut -d. -f1) -lt 4 ] && { warn "内核版本过低，无法开启 BBR"; return; }
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p 2>/dev/null
    ok "BBR 已开启"
}

create_swap() {
    printf "\n%b\n" "${CYAN}[扩展]${NC} ${ICON_SWAP} 创建 Swap..."
    swapon --show 2>/dev/null | grep -q "swap" && { ok "Swap 已存在，跳过"; return; }
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}') swap_size
    if [ "$mem_mb" -le 1024 ]; then swap_size=$(( mem_mb * 2 ))
    elif [ "$mem_mb" -le 4096 ]; then swap_size=$(( mem_mb / 2 ))
    else swap_size=4096; fi
    read -rp "  Swap 大小(MB) [推荐: $swap_size]: " input_size
    swap_size=${input_size:-$swap_size}
    [ "$swap_size" -le 0 ] && { warn "大小无效"; return; }
    fallocate -l ${swap_size}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size 2>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile 2>/dev/null && swapon /swapfile 2>/dev/null
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    ok "Swap 创建成功 (${swap_size}MB)"
}

install_fail2ban() {
    printf "\n%b\n" "${CYAN}[扩展]${NC} ${ICON_F2B} 安装 Fail2Ban..."
    pkg_install fail2ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
[sshd]
enabled = true
port = ${NEW_PORT:-22}
EOF
    systemctl enable fail2ban 2>/dev/null
    systemctl restart fail2ban 2>/dev/null
    ok "Fail2Ban 已配置"
}

install_monitoring() {
    printf "\n%b\n" "${CYAN}[扩展]${NC} ${ICON_MON} 安装监控工具..."
    if command -v snap &>/dev/null; then snap install btop 2>/dev/null; else pkg_install btop 2>/dev/null || true; fi
    pip install glances 2>/dev/null || pkg_install glances 2>/dev/null || true
    ok "监控安装完成"
}

configure_firewall_rules() {
    printf "\n%b\n" "${CYAN}[扩展]${NC} ${ICON_FW} 配置防火墙规则..."
    local ssh_port=${NEW_PORT:-22}
    if command -v ufw &>/dev/null; then
        ufw --force reset 2>/dev/null
        ufw default deny incoming 2>/dev/null
        ufw default allow outgoing 2>/dev/null
        ufw allow $ssh_port/tcp 2>/dev/null
        if confirm "  开放 HTTP(80)/HTTPS(443)?" "N"; then
            ufw allow 80/tcp; ufw allow 443/tcp
        fi
        ufw --force enable 2>/dev/null
        ok "UFW 规则已应用"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=$ssh_port/tcp 2>/dev/null
        if confirm "  开放 HTTP/HTTPS 服务?" "N"; then
            firewall-cmd --permanent --add-service=http 2>/dev/null
            firewall-cmd --permanent --add-service=https 2>/dev/null
        fi
        firewall-cmd --reload 2>/dev/null
        ok "firewalld 规则已应用"
    else
        warn "未检测到防火墙"
    fi
}

system_hardening() {
    printf "\n%b\n" "${CYAN}[扩展]${NC} ${ICON_HARD} 系统安全加固..."
    passwd -l root 2>/dev/null && ok "已锁定 root 密码" || true
    [ -f /etc/ssh/sshd_config ] && {
        safe_sed /etc/ssh/sshd_config "PermitEmptyPasswords" "PermitEmptyPasswords no"
        safe_sed /etc/ssh/sshd_config "X11Forwarding" "X11Forwarding no"
    }
    $UPDATE_CMD 2>/dev/null
    case $PKG_MGR in
        apt) apt upgrade -y 2>/dev/null ;;
        dnf|yum) $INSTALL_CMD -y update 2>/dev/null || true ;;
        apk) apk upgrade 2>/dev/null || true ;;
    esac
    ok "系统加固完成"
}

extended_features() {
    printf "\n%b\n" "${CYAN}┌────────────────────────────────────────┐${NC}"
    printf "%b\n" "${CYAN}│${NC}  🧩 可选扩展功能 (空格分隔多选)       ${CYAN}│${NC}"
    printf "%b\n" "${CYAN}└────────────────────────────────────────┘${NC}"
    printf "%b\n" "  ${GREEN}2${NC}) ${ICON_PKG} 安装基础软件包"
    printf "%b\n" "  ${GREEN}3${NC}) ${ICON_BBR} 开启 BBR 加速"
    printf "%b\n" "  ${GREEN}4${NC}) ${ICON_SWAP} 创建 Swap"
    printf "%b\n" "  ${GREEN}5${NC}) ${ICON_F2B} 安装 Fail2Ban"
    printf "%b\n" "  ${GREEN}6${NC}) ${ICON_MON} 安装监控 (btop+glances)"
    printf "%b\n" "  ${GREEN}7${NC}) ${ICON_FW} 配置防火墙规则"
    printf "%b\n" "  ${GREEN}8${NC}) ${ICON_HARD} 系统清理与安全加固"
    printf "%b\n" "  ${GREEN}0${NC}) 跳过 (默认)"
    printf "%b" "  ${CYAN}➤${NC} 请选择 [0]: "
    read -a FEATURES
    [ ${#FEATURES[@]} -eq 0 ] && FEATURES=(0)
    for f in "${FEATURES[@]}"; do
        case $f in
            2) install_base_packages ;;
            3) enable_bbr ;;
            4) create_swap ;;
            5) install_fail2ban ;;
            6) install_monitoring ;;
            7) configure_firewall_rules ;;
            8) system_hardening ;;
            0) break ;;
            *) warn "无效选项: $f" ;;
        esac
    done
}

#-------- 快捷命令安装 --------
install_vps_shortcut() {
    if confirm "  ${CYAN}➤${NC} 是否创建快捷命令 vps (下次直接输入 vps 运行本脚本)?" "N"; then
        local target="/usr/local/bin/vps"
        # 判断脚本自身路径
        if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "/dev/fd/63" ]; then
            cp "$0" "$target"
        else
            # 从 GitHub 下载最新版
            curl -sL "https://raw.githubusercontent.com/GDLiBai/vps/main/vps_init.sh" -o "$target"
        fi
        chmod +x "$target" 2>/dev/null
        if [ -x "$target" ]; then
            ok "快捷命令已创建，下次输入 ${GREEN}vps${NC} 即可运行本脚本"
        else
            warn "快捷命令创建失败，请手动设置"
        fi
    fi
}

#========== 主流程 ==========
main() {
    check_root
    detect_pkg_manager
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    log "VPS 初始化开始"

    show_system_info

    clear
    printf "%b\n" "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${BLUE}║${NC}    ${ICON_ROCKET} VPS 一键初始化脚本 v4.1 优化版${NC}         ${BLUE}║${NC}"
    printf "%b\n" "${BLUE}╚══════════════════════════════════════════════╝${NC}"

    #---- 1. 主机名 ----
    printf "\n%b\n" "${CYAN}┌────────────────────────────────────────┐${NC}"
    printf "%b\n" "${CYAN}│${NC}  ${ICON_HOST} 步骤 1/3 · 主机名配置"
    printf "%b\n" "${CYAN}└────────────────────────────────────────┘${NC}"
    while true; do
        read_nonempty "  ${CYAN}➤${NC} 新主机名: " NEW_HOSTNAME
        validate_hostname "$NEW_HOSTNAME" && break
    done

    # 时区预设（香港）
    TIMEZONE="Asia/Hong_Kong"
    printf "\n%b\n" "${CYAN}┌────────────────────────────────────────┐${NC}"
    printf "%b\n" "${CYAN}│${NC}  ${ICON_CLOCK} 时区已预设为: ${GREEN}${TIMEZONE}${NC}"
    printf "%b\n" "${CYAN}└────────────────────────────────────────┘${NC}"

    #---- 2. 新用户 ----
    printf "\n%b\n" "${CYAN}┌────────────────────────────────────────┐${NC}"
    printf "%b\n" "${CYAN}│${NC}  ${ICON_USER} 步骤 2/3 · 创建管理员用户"
    printf "%b\n" "${CYAN}└────────────────────────────────────────┘${NC}"
    while true; do
        read_nonempty "  ${CYAN}➤${NC} 用户名: " NEW_USER
        validate_username "$NEW_USER" && break
    done
    while true; do
        printf "%b" "  ${CYAN}➤${NC} 密码 (至少6位): "
        read -s USER_PASS; echo
        [ ${#USER_PASS} -ge 6 ] || { warn "长度不足6位"; continue; }
        printf "%b" "  ${CYAN}➤${NC} 确认密码: "
        read -s USER_PASS2; echo
        [ "$USER_PASS" = "$USER_PASS2" ] && break || warn "两次不一致"
    done

    #---- 3. SSH端口 ----
    printf "\n%b\n" "${CYAN}┌────────────────────────────────────────┐${NC}"
    printf "%b\n" "${CYAN}│${NC}  ${ICON_PORT} 步骤 3/3 · SSH端口配置"
    printf "%b\n" "${CYAN}└────────────────────────────────────────┘${NC}"
    CURRENT_PORT=$(show_current_port)
    RANDOM_PORT=$(generate_random_port)
    printf "%b\n" "  当前端口: ${YELLOW}$CURRENT_PORT${NC}  随机推荐: ${GREEN}$RANDOM_PORT${NC}"
    while true; do
        printf "%b" "  ${CYAN}➤${NC} 新端口 [随机:$RANDOM_PORT]: "
        read PORT_INPUT
        PORT_INPUT=$(echo "$PORT_INPUT" | xargs)
        if [ -z "$PORT_INPUT" ]; then
            NEW_PORT=$RANDOM_PORT
            printf "%b\n" "  ${GREEN}→ 使用随机端口: $NEW_PORT${NC}"
            break
        fi
        [[ "$PORT_INPUT" =~ ^[0-9]+$ ]] || { warn "端口必须是数字"; continue; }
        [ "$PORT_INPUT" -ge 1024 ] && [ "$PORT_INPUT" -le 65535 ] || { warn "范围: 1024-65535"; continue; }
        if ss -tlnp 2>/dev/null | grep -q ":$PORT_INPUT "; then
            warn "端口 $PORT_INPUT 已被占用"
            if confirm "  仍要使用?" "N"; then NEW_PORT=$PORT_INPUT; break
            else RANDOM_PORT=$(generate_random_port); printf "%b\n" "  ${GREEN}→ 新推荐: $RANDOM_PORT${NC}"; continue; fi
        fi
        NEW_PORT=$PORT_INPUT
        break
    done

    #---- 确认 ----
    clear
    printf "%b\n" "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${BLUE}║${NC}          ${WHITE}📋 配置确认清单${NC}                   ${BLUE}║${NC}"
    printf "%b\n" "${BLUE}╠══════════════════════════════════════════════╣${NC}"
    printf "%b\n" "${BLUE}║${NC}  ${ICON_HOST} 主机名  : ${GREEN}$NEW_HOSTNAME${NC}"
    printf "%b\n" "${BLUE}║${NC}  ${ICON_CLOCK} 时区    : ${GREEN}$TIMEZONE${NC} (已预设)"
    printf "%b\n" "${BLUE}║${NC}  ${ICON_USER} 新用户  : ${GREEN}$NEW_USER${NC}"
    printf "%b\n" "${BLUE}║${NC}  ${ICON_PORT} SSH端口 : ${GREEN}$NEW_PORT${NC} ${YELLOW}(原:$CURRENT_PORT)${NC}"
    printf "%b\n" "${BLUE}║${NC}  ${ICON_LOCK} root登录: ${RED}将被禁止${NC}"
    printf "%b\n" "${BLUE}╚══════════════════════════════════════════════╝${NC}"

    if ! confirm "  ${CYAN}➤${NC} 确认执行?" "N"; then
        printf "\n%b\n" "  ${ICON_WARN} 已取消"; exit 0
    fi

    #---- 执行基础配置 ----
    clear
    printf "\n%b\n" "${CYAN}┌────────────────────────────────────────┐${NC}"
    printf "%b\n" "${CYAN}│${NC}  ${ICON_ROCKET} 正在执行基础配置...            ${CYAN}│${NC}"
    printf "%b\n" "${CYAN}└────────────────────────────────────────┘${NC}"

    # 1. 主机名
    OLD_HOSTNAME=$(hostname)
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME" 2>/dev/null || true
    echo "$NEW_HOSTNAME" > /etc/hostname
    sed -i "s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts 2>/dev/null || true
    grep -q "$NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
    ok "主机名: ${GREEN}$OLD_HOSTNAME${NC} → ${GREEN}$NEW_HOSTNAME${NC}"

    # 2. 时区
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime 2>/dev/null || true
    ok "时区已设置为: ${GREEN}$TIMEZONE${NC}"

    # 3. 用户
    useradd -m -s /bin/bash "$NEW_USER" 2>/dev/null || adduser -D -s /bin/bash "$NEW_USER" 2>/dev/null || true
    echo "$NEW_USER:$USER_PASS" | chpasswd 2>/dev/null || passwd "$NEW_USER" <<< "$USER_PASS"$'\n'"$USER_PASS" 2>/dev/null || true
    getent group sudo &>/dev/null && usermod -aG sudo "$NEW_USER" 2>/dev/null
    getent group wheel &>/dev/null && usermod -aG wheel "$NEW_USER" 2>/dev/null
    getent group sudo &>/dev/null || { groupadd sudo 2>/dev/null; usermod -aG sudo "$NEW_USER" 2>/dev/null; }
    if confirm "  允许 ${NEW_USER} 无密码 sudo?" "N"; then
        echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
        chmod 440 "/etc/sudoers.d/$NEW_USER"
        ok "已配置无密码 sudo"
    else
        ok "sudo 权限已授予 (需密码)"
    fi

    # 4. SSH
    SSH_SERVICE=$(detect_ssh_service)
    SSHD_CONFIG="/etc/ssh/sshd_config"
    [ -f "$SSHD_CONFIG" ] || SSHD_CONFIG="/etc/ssh/ssh_config"
    cp "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config.bak" 2>/dev/null || true
    safe_sed "$SSHD_CONFIG" "Port" "Port $NEW_PORT"
    safe_sed "$SSHD_CONFIG" "PermitRootLogin" "PermitRootLogin no"
    safe_sed "$SSHD_CONFIG" "PasswordAuthentication" "PasswordAuthentication yes"
    safe_sed "$SSHD_CONFIG" "PubkeyAuthentication" "PubkeyAuthentication yes"
    safe_sed "$SSHD_CONFIG" "PermitEmptyPasswords" "PermitEmptyPasswords no"
    safe_sed "$SSHD_CONFIG" "X11Forwarding" "X11Forwarding no"
    grep -q "^Protocol" "$SSHD_CONFIG" 2>/dev/null || echo "Protocol 2" >> "$SSHD_CONFIG"

    # 防火墙
    if command -v ufw &>/dev/null; then ufw allow "$NEW_PORT"/tcp 2>/dev/null; fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="$NEW_PORT"/tcp 2>/dev/null && firewall-cmd --reload 2>/dev/null
    fi

    # 重启 SSH
    if sshd -t 2>/dev/null; then
        restart_ssh "$SSH_SERVICE"
        ok "SSH 服务已重启，新端口: ${GREEN}$NEW_PORT${NC}"
    else
        warn "SSH 配置测试失败，恢复备份..."
        cp "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG" 2>/dev/null
        restart_ssh "$SSH_SERVICE"
        err "已恢复原配置"
    fi

    # 扩展功能
    extended_features

    # 快捷命令创建
    install_vps_shortcut

    # 完成画面
    IP_ADDR=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "未知")
    CLIENT_IP_END=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    [ -z "$CLIENT_IP_END" ] && CLIENT_IP_END=$(echo "$SSH_CLIENT" | awk '{print $1}')
    [ -z "$CLIENT_IP_END" ] && CLIENT_IP_END="本地/未知"

    clear
    printf "%b\n" "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${GREEN}║${NC}       ${ICON_DONE}  初始化全部完成！${ICON_DONE}                ${GREEN}║${NC}"
    printf "%b\n" "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_HOST} 主机名 : ${WHITE}$NEW_HOSTNAME${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_CLOCK} 时区   : ${WHITE}$TIMEZONE${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_USER} 用户   : ${WHITE}$NEW_USER${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_PORT} SSH端口: ${WHITE}$NEW_PORT${NC} ${YELLOW}(原:$CURRENT_PORT)${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_LOCK} root登录: ${RED}已禁止${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_INFO} 服务器IP: ${WHITE}$IP_ADDR${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_CLIENT} 当前连接: ${WHITE}$CLIENT_IP_END${NC}"
    printf "%b\n" "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_WARN} ${YELLOW}立即测试新连接 (不要关闭当前会话):${NC}     ${GREEN}║${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${WHITE}ssh -p $NEW_PORT $NEW_USER@$IP_ADDR${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_INFO} 备份: ${WHITE}$BACKUP_DIR${NC}"
    printf "%b\n" "${GREEN}║${NC}  ${ICON_INFO} 日志: ${WHITE}$LOG_FILE${NC}"
    printf "%b\n" "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    printf "\n"
}

main "$@"
