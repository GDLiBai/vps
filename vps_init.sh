#!/bin/bash
#==================================================
# VPS 一键初始化 & 管理脚本 v3.0.3
# 修复：颜色显示问题
# 时区：Asia/Hong_Kong
#==================================================
set -o pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/vps_init_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/root/vps_backup_$(date +%Y%m%d_%H%M%S)"

#-------- 颜色 --------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; WHITE=''; NC=''
fi

ICON_OK="✅"; ICON_ERR="❌"; ICON_WARN="⚠️"; ICON_INFO="📌"
ICON_ROCKET="🚀"; ICON_LOCK="🔒"; ICON_USER="👤"; ICON_HOST="🖥️"
ICON_CLOCK="🕐"; ICON_PORT="🔌"; ICON_DONE="🎉"; ICON_PKG="📦"
ICON_SWAP="💾"; ICON_CLIENT="🔗"; ICON_IPV4="🌐"; ICON_IPV6="🌏"
ICON_CPU="🧠"; ICON_DISK="💿"; ICON_AUTO="🔄"; ICON_MENU="📋"
ICON_TRASH="🗑️"

# ★ 修复：print_row 用 echo -e 解析颜色 ★
print_row() {
    printf "  %-12s " "$1"
    echo -e "$2"
}

log()        { echo -e "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
ok()         { log "  ${ICON_OK} $*"; }
warn()       { log "  ${ICON_WARN} $*"; }
err()        { log "  ${ICON_ERR} $*"; exit 1; }

check_root() {
    [ "$EUID" -eq 0 ] || { echo -e "${RED}${ICON_ERR} 请使用root运行${NC}"; exit 1; }
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

confirm() {
    local prompt="$1" default="$2" input
    while true; do
        echo -ne "$prompt [${default}]: "
        read input
        input=$(echo "$input" | xargs)
        [ -z "$input" ] && input="$default"
        case "$input" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo -e "${YELLOW}请输入 Y 或 N${NC}" ;;
        esac
    done
}

read_nonempty() {
    local prompt="$1" var_name="$2" input
    while true; do
        echo -ne "$prompt"
        read input
        input=$(echo "$input" | xargs)
        if [ -n "$input" ]; then eval "$var_name=\"$input\""; return; fi
        echo -e "${YELLOW}输入不能为空${NC}"
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

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] || { warn "无效主机名: $1"; return 1; }
}

validate_username() {
    local u="$1" r
    local reserved=(root bin daemon adm lp sync shutdown halt mail news uucp operator games gopher ftp nobody)
    for r in "${reserved[@]}"; do [ "$u" = "$r" ] && { warn "系统保留用户: $u"; return 1; }; done
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn "用户名格式错误"; return 1; }
    return 0
}

safe_sed() {
    local f="$1" p="$2" r="$3"
    if grep -q "^${p}" "$f" 2>/dev/null; then sed -i "s/^${p}.*/${r}/" "$f"
    elif grep -q "^#${p}" "$f" 2>/dev/null; then sed -i "s/^#${p}.*/${r}/" "$f"
    else echo "$r" >> "$f"; fi
}

detect_ssh_service() {
    systemctl list-units --type=service 2>/dev/null | grep -q "sshd.service" && echo "sshd" && return
    systemctl list-units --type=service 2>/dev/null | grep -q "ssh.service" && echo "ssh" && return
    echo "ssh"
}

show_current_port() { grep -E "^Port [0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22"; }

verify_ssh_port() {
    local port="$1" max_wait=5 waited=0
    while [ $waited -lt $max_wait ]; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then return 0; fi
        sleep 1; ((waited++))
    done
    return 1
}

restart_ssh_safe() {
    local svc="$1" new_port="$2" backup="$3" SSHD_CONFIG="$4" success=false
    if systemctl restart "$svc" 2>/dev/null; then success=true
    elif service "$svc" restart 2>/dev/null; then success=true
    elif service ssh restart 2>/dev/null; then success=true
    elif service sshd restart 2>/dev/null; then success=true
    fi
    if ! $success; then
        warn "SSH 服务重启失败，恢复配置..."
        cp "$backup" "$SSHD_CONFIG" 2>/dev/null
        systemctl restart "$svc" 2>/dev/null || service ssh restart 2>/dev/null || true
        err "已恢复原配置"
    fi
    if ! verify_ssh_port "$new_port"; then
        warn "新端口 $new_port 未监听，恢复..."
        cp "$backup" "$SSHD_CONFIG" 2>/dev/null
        systemctl restart "$svc" 2>/dev/null || service ssh restart 2>/dev/null || true
        err "已恢复原配置"
    fi
}

get_public_ipv4() {
    curl -s4 --max-time 3 ifconfig.me 2>/dev/null || curl -s4 --max-time 3 icanhazip.com 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

get_public_ipv6() {
    curl -s6 --max-time 3 ifconfig.me 2>/dev/null || curl -s6 --max-time 3 icanhazip.com 2>/dev/null
}

get_client_ip() {
    [ -n "$SSH_CONNECTION" ] && { echo "$SSH_CONNECTION" | awk '{print $1}'; return; }
    [ -n "$SSH_CLIENT" ] && { echo "$SSH_CLIENT" | awk '{print $1}'; return; }
    local who_line=$(who -m 2>/dev/null)
    [ -n "$who_line" ] && { local ip=$(echo "$who_line" | awk -F'[()]' '{print $2}'); [ -n "$ip" ] && { echo "$ip"; return; }; }
    echo "未知"
}

show_system_info() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              📋 当前系统配置${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"

    if [ -f /etc/os-release ]; then . /etc/os-release; OS_NAME="${PRETTY_NAME:-$NAME $VERSION}"; else OS_NAME="未知"; fi
    KERNEL="$(uname -r) ($(uname -m))"
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | xargs || echo "未知")
    CPU_CORES=$(nproc 2>/dev/null || echo "未知")
    if command -v free &>/dev/null; then
        read MEM_TOTAL MEM_USED MEM_AVAIL <<< $(free -h 2>/dev/null | awk '/^Mem:/{print $2, $3, $7}')
        [ -z "$MEM_TOTAL" ] && MEM_TOTAL="?"; [ -z "$MEM_USED" ] && MEM_USED="?"; [ -z "$MEM_AVAIL" ] && MEM_AVAIL="?"
        MEM_INFO="已用 ${MEM_USED} / 总量 ${MEM_TOTAL} (可用 ${MEM_AVAIL})"
    else MEM_INFO="未知"; fi
    if command -v df &>/dev/null; then
        read DISK_USED DISK_TOTAL DISK_PCT <<< $(df -h / 2>/dev/null | awk 'NR==2{print $3, $2, $5}')
        [ -z "$DISK_USED" ] && DISK_USED="?"; [ -z "$DISK_TOTAL" ] && DISK_TOTAL="?"; [ -z "$DISK_PCT" ] && DISK_PCT="?"
        DISK_INFO="已用 ${DISK_USED} / 总量 ${DISK_TOTAL} (使用率 ${DISK_PCT})"
    else DISK_INFO="未知"; fi
    IPV4=$(get_public_ipv4); [ -z "$IPV4" ] && IPV4="无"
    IPV6=$(get_public_ipv6); [ -z "$IPV6" ] && IPV6="无"
    CLIENT_IP=$(get_client_ip)
    CURRENT_SSH=$(show_current_port)
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "未知")
    SWAP_TOTAL=$(swapon --show=size 2>/dev/null | awk 'NR>1{sum+=$1} END{print sum}')
    [ -z "$SWAP_TOTAL" ] || [ "$SWAP_TOTAL" -eq 0 ] && SWAP_INFO="无" || SWAP_INFO="${SWAP_TOTAL}MB"

    print_row "${ICON_INFO} 系统"   "${GREEN}${OS_NAME}${NC}"
    print_row "${ICON_INFO} 内核"   "${GREEN}${KERNEL}${NC}"
    print_row "${ICON_CPU} CPU"     "${GREEN}${CPU_MODEL} (${CPU_CORES} 核)${NC}"
    print_row "${ICON_INFO} 内存"   "${GREEN}${MEM_INFO}${NC}"
    print_row "${ICON_DISK} 磁盘"   "${GREEN}${DISK_INFO}${NC}"
    print_row "${ICON_IPV4} IPv4"   "${GREEN}${IPV4}${NC}"
    print_row "${ICON_IPV6} IPv6"   "${GREEN}${IPV6}${NC}"
    print_row "${ICON_CLIENT} 连接IP" "${GREEN}${CLIENT_IP}${NC}"
    print_row "${ICON_PORT} SSH端口" "${YELLOW}${CURRENT_SSH}${NC}"
    print_row "${ICON_CLOCK} 时区"   "${YELLOW}${CURRENT_TZ}${NC}"
    print_row "${ICON_SWAP} Swap"    "${YELLOW}${SWAP_INFO}${NC}"
    echo ""
    read -rp "  按回车键继续..." dummy
}

manage_users_menu() {
    while true; do
        clear
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}              👤 用户管理${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${WHITE}现有用户:${NC}"
        awk -F: '($3>=1000 && $7 !~ /nologin|false/){printf "    %-15s (UID:%s)\n", $1, $3}' /etc/passwd
        echo ""
        echo -e "  ${GREEN}1${NC}) 新建用户"
        echo -e "  ${GREEN}2${NC}) 修改用户密码"
        echo -e "  ${GREEN}3${NC}) 删除用户"
        echo -e "  ${GREEN}0${NC}) 返回"
        echo ""
        echo -ne "  ${CYAN}➤${NC} 请选择 [0]: "
        read CHOICE
        CHOICE=${CHOICE:-0}
        case $CHOICE in
            1) create_new_user ;;
            2) change_user_password ;;
            3) delete_user ;;
            0) break ;;
            *) warn "无效选项" ;;
        esac
    done
}

create_new_user() {
    local new_user user_pass user_pass2
    while true; do
        read_nonempty "  用户名: " new_user
        validate_username "$new_user" && break
    done
    id "$new_user" &>/dev/null && { warn "用户 $new_user 已存在"; return; }
    while true; do
        echo -ne "  密码 (至少6位): "
        read -s user_pass; echo
        [ ${#user_pass} -ge 6 ] || { warn "长度不足6位"; continue; }
        echo -ne "  确认密码: "
        read -s user_pass2; echo
        [ "$user_pass" = "$user_pass2" ] && break || warn "两次不一致"
    done
    useradd -m -s /bin/bash "$new_user" 2>/dev/null || adduser -D -s /bin/bash "$new_user" 2>/dev/null || true
    echo "$new_user:$user_pass" | chpasswd 2>/dev/null || passwd "$new_user" <<< "$user_pass"$'\n'"$user_pass" 2>/dev/null || true
    getent group sudo &>/dev/null && usermod -aG sudo "$new_user" 2>/dev/null
    getent group wheel &>/dev/null && usermod -aG wheel "$new_user" 2>/dev/null
    getent group sudo &>/dev/null || { groupadd sudo 2>/dev/null; usermod -aG sudo "$new_user" 2>/dev/null; }
    ok "用户 ${GREEN}$new_user${NC} 创建成功 (sudo 需密码)"
}

change_user_password() {
    local target_user user_pass user_pass2
    read_nonempty "  用户名: " target_user
    id "$target_user" &>/dev/null || { warn "用户 $target_user 不存在"; return; }
    while true; do
        echo -ne "  新密码 (至少6位): "
        read -s user_pass; echo
        [ ${#user_pass} -ge 6 ] || { warn "长度不足6位"; continue; }
        echo -ne "  确认新密码: "
        read -s user_pass2; echo
        [ "$user_pass" = "$user_pass2" ] && break || warn "两次不一致"
    done
    echo "$target_user:$user_pass" | chpasswd 2>/dev/null || passwd "$target_user" <<< "$user_pass"$'\n'"$user_pass" 2>/dev/null
    ok "用户 ${GREEN}$target_user${NC} 密码已修改"
}

delete_user() {
    local target_user
    read_nonempty "  用户名: " target_user
    id "$target_user" &>/dev/null || { warn "用户 $target_user 不存在"; return; }
    [ "$target_user" = "root" ] && { warn "不能删除 root"; return; }
    if confirm "  确认删除用户 ${target_user} 及其主目录?" "N"; then
        userdel -r "$target_user" 2>/dev/null || deluser --remove-home "$target_user" 2>/dev/null
        ok "用户 ${GREEN}$target_user${NC} 已删除"
    fi
}

self_destruct() {
    echo ""
    echo -e "  ${RED}${ICON_WARN} 警告：此操作将删除脚本及所有相关文件！${NC}"
    echo -e "  ${YELLOW}（不会撤销已修改的系统配置）${NC}"
    echo ""
    if ! confirm "  确认删除脚本?" "N"; then
        echo -e "  ${ICON_INFO} 已取消"
        read -rp "  按回车键返回..." dummy
        return
    fi
    echo ""
    if [ -f /usr/local/bin/vps ]; then rm -f /usr/local/bin/vps && ok "已删除 /usr/local/bin/vps"; fi
    rm -rf /root/vps_backup_* 2>/dev/null && ok "已清理备份文件"
    rm -f /var/log/vps_init_*.log 2>/dev/null && ok "已清理日志文件"
    echo ""
    echo -e "  ${ICON_DONE} ${GREEN}脚本已完全删除，退出...${NC}"
    echo ""
    SCRIPT_PATH="$(readlink -f "$0")"
    rm -f /root/vps_init.sh 2>/dev/null
    rm -f "$SCRIPT_PATH" 2>/dev/null
    exit 0
}

management_menu() {
    while true; do
        clear
        echo -e "${BLUE}════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}              📋 VPS 管理菜单${NC}"
        echo -e "${BLUE}════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${GREEN}1${NC}) ${ICON_HOST} 修改主机名"
        echo -e "  ${GREEN}2${NC}) ${ICON_USER} 管理用户 (新建/修改/删除)"
        echo -e "  ${GREEN}3${NC}) ${ICON_PORT} 修改 SSH 端口"
        echo -e "  ${GREEN}4${NC}) ${ICON_SWAP} 创建 Swap 虚拟内存"
        echo -e "  ${GREEN}5${NC}) ${ICON_INFO} 查看系统信息"
        echo -e "  ${RED}9${NC}) ${RED}${ICON_TRASH} 删除此脚本${NC}"
        echo -e "  ${GREEN}0${NC}) 退出"
        echo ""
        echo -ne "  ${CYAN}➤${NC} 请选择 [0]: "
        read CHOICE
        CHOICE=${CHOICE:-0}
        case $CHOICE in
            1) change_hostname ;;
            2) manage_users_menu ;;
            3) change_ssh_port ;;
            4) create_swap_menu ;;
            5) show_system_info; read -rp "  按回车键返回..." dummy ;;
            9) self_destruct; break ;;
            0) break ;;
            *) warn "无效选项" ;;
        esac
    done
}

change_hostname() {
    local new_host
    while true; do
        read_nonempty "  新主机名: " new_host
        validate_hostname "$new_host" && break
    done
    local old_host=$(hostname)
    hostnamectl set-hostname "$new_host" 2>/dev/null || hostname "$new_host" 2>/dev/null || true
    echo "$new_host" > /etc/hostname
    sed -i "s/\b${old_host}\b/${new_host}/g" /etc/hosts 2>/dev/null || true
    grep -q "$new_host" /etc/hosts || echo "127.0.1.1 $new_host" >> /etc/hosts
    ok "主机名: ${GREEN}$old_host${NC} → ${GREEN}$new_host${NC}"
}

change_ssh_port() {
    local current=$(show_current_port) rand_port=$(generate_random_port) new_port input
    echo "  当前端口: ${YELLOW}$current${NC}  随机推荐: ${GREEN}$rand_port${NC}"
    echo -ne "  新端口 [随机:$rand_port]: "
    read input
    input=$(echo "$input" | xargs)
    [ -z "$input" ] && new_port=$rand_port || new_port=$input
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        warn "端口无效"; return
    fi
    local SSH_SERVICE=$(detect_ssh_service)
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    [ -f "$SSHD_CONFIG" ] || SSHD_CONFIG="/etc/ssh/ssh_config"
    cp "$SSHD_CONFIG" /root/sshd_config.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null
    safe_sed "$SSHD_CONFIG" "Port" "Port $new_port"
    if command -v ufw &>/dev/null; then ufw allow "$new_port"/tcp 2>/dev/null; fi
    if command -v firewall-cmd &>/dev/null; then firewall-cmd --permanent --add-port="$new_port"/tcp 2>/dev/null && firewall-cmd --reload 2>/dev/null; fi
    if sshd -t 2>/dev/null; then
        restart_ssh_safe "$SSH_SERVICE" "$new_port" "/root/sshd_config.bak."* "$SSHD_CONFIG"
        ok "SSH 端口: ${GREEN}$current${NC} → ${GREEN}$new_port${NC}"
    else
        warn "SSH 配置测试失败，已恢复"
    fi
}

create_swap_menu() {
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

install_base_packages_quiet() {
    pkg_install curl wget vim git htop net-tools unzip zip lrzsz 2>/dev/null
}

enable_auto_updates() {
    case $PKG_MGR in
        apt)
            pkg_install unattended-upgrades 2>/dev/null
            cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
            ok "Unattended Upgrades 已启用"
            ;;
        dnf|yum)
            pkg_install dnf-automatic 2>/dev/null
            sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
            systemctl enable --now dnf-automatic.timer 2>/dev/null
            ok "dnf-automatic 已启用"
            ;;
        apk)
            (crontab -l 2>/dev/null; echo "0 3 * * * apk update && apk upgrade -y") | crontab -
            ok "每日自动更新已添加"
            ;;
    esac
}

install_vps_shortcut() {
    local target="/usr/local/bin/vps"
    if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "/dev/fd/63" ]; then
        cp "$0" "$target"
    else
        curl -sL "https://raw.githubusercontent.com/GDLiBai/vps/main/vps_init.sh" -o "$target"
    fi
    chmod +x "$target" 2>/dev/null
    [ -x "$target" ] && ok "快捷命令 ${GREEN}vps${NC} 已创建" || warn "快捷命令创建失败"
}

#========== 主流程 ==========
main() {
    check_root
    detect_pkg_manager
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    log "VPS 初始化开始"

    echo -ne "  ${ICON_PKG} 安装基础软件包..."
    install_base_packages_quiet
    ok "完成"

    show_system_info

    clear
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}     🚀 VPS 一键初始化脚本 v3.0.3${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"

    echo -e "\n  ${ICON_HOST} 步骤 1/3 · 设置主机名"
    echo -e "  ${CYAN}────────────────────────────────────────${NC}"
    while true; do
        read_nonempty "  新主机名: " NEW_HOSTNAME
        validate_hostname "$NEW_HOSTNAME" && break
    done

    TIMEZONE="Asia/Hong_Kong"
    echo -e "\n  ${ICON_CLOCK} 时区已预设: ${GREEN}${TIMEZONE}${NC}"

    echo -e "\n  ${ICON_USER} 步骤 2/3 · 创建管理员用户 (sudo需密码)"
    echo -e "  ${CYAN}────────────────────────────────────────${NC}"
    while true; do
        read_nonempty "  用户名: " NEW_USER
        validate_username "$NEW_USER" && break
    done
    while true; do
        echo -ne "  密码 (至少6位): "
        read -s USER_PASS; echo
        [ ${#USER_PASS} -ge 6 ] || { warn "长度不足6位"; continue; }
        echo -ne "  确认密码: "
        read -s USER_PASS2; echo
        [ "$USER_PASS" = "$USER_PASS2" ] && break || warn "两次不一致"
    done

    echo -e "\n  ${ICON_PORT} 步骤 3/3 · 设置 SSH 端口"
    echo -e "  ${CYAN}────────────────────────────────────────${NC}"
    CURRENT_PORT=$(show_current_port)
    RANDOM_PORT=$(generate_random_port)
    echo "  当前端口: ${YELLOW}$CURRENT_PORT${NC}  随机推荐: ${GREEN}$RANDOM_PORT${NC}"
    while true; do
        echo -ne "  新端口 [随机:$RANDOM_PORT]: "
        read PORT_INPUT
        PORT_INPUT=$(echo "$PORT_INPUT" | xargs)
        if [ -z "$PORT_INPUT" ]; then NEW_PORT=$RANDOM_PORT; echo -e "  ${GREEN}→ 随机端口: $NEW_PORT${NC}"; break; fi
        [[ "$PORT_INPUT" =~ ^[0-9]+$ ]] || { warn "端口必须是数字"; continue; }
        [ "$PORT_INPUT" -ge 1024 ] && [ "$PORT_INPUT" -le 65535 ] || { warn "范围: 1024-65535"; continue; }
        if ss -tlnp 2>/dev/null | grep -q ":$PORT_INPUT "; then
            warn "端口 $PORT_INPUT 已被占用"
            if confirm "  仍要使用?" "N"; then NEW_PORT=$PORT_INPUT; break
            else RANDOM_PORT=$(generate_random_port); echo -e "  ${GREEN}→ 新推荐: $RANDOM_PORT${NC}"; continue; fi
        fi
        NEW_PORT=$PORT_INPUT
        break
    done

    clear
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              📋 配置确认${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    print_row "${ICON_HOST} 主机名"   "${GREEN}$NEW_HOSTNAME${NC}"
    print_row "${ICON_CLOCK} 时区"     "${GREEN}$TIMEZONE${NC}"
    print_row "${ICON_USER} 用户"     "${GREEN}$NEW_USER${NC} ${YELLOW}(sudo需密码)${NC}"
    print_row "${ICON_PORT} SSH端口"  "${GREEN}$NEW_PORT${NC} ${YELLOW}(原:$CURRENT_PORT)${NC}"
    print_row "${ICON_LOCK} root登录" "${RED}将被禁止${NC}"
    print_row "${ICON_AUTO} 自动更新" "${GREEN}默认启用${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"

    if ! confirm "  确认执行?" "N"; then echo -e "\n  ${ICON_WARN} 已取消\n"; exit 0; fi

    clear
    echo -e "${CYAN}════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}     🚀 正在执行配置...${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════${NC}"

    OLD_HOSTNAME=$(hostname)
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME" 2>/dev/null || true
    echo "$NEW_HOSTNAME" > /etc/hostname
    sed -i "s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts 2>/dev/null || true
    grep -q "$NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
    ok "主机名: ${GREEN}$OLD_HOSTNAME${NC} → ${GREEN}$NEW_HOSTNAME${NC}"

    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime 2>/dev/null || true
    ok "时区: ${GREEN}$TIMEZONE${NC}"

    useradd -m -s /bin/bash "$NEW_USER" 2>/dev/null || adduser -D -s /bin/bash "$NEW_USER" 2>/dev/null || true
    echo "$NEW_USER:$USER_PASS" | chpasswd 2>/dev/null || passwd "$NEW_USER" <<< "$USER_PASS"$'\n'"$USER_PASS" 2>/dev/null || true
    getent group sudo &>/dev/null && usermod -aG sudo "$NEW_USER" 2>/dev/null
    getent group wheel &>/dev/null && usermod -aG wheel "$NEW_USER" 2>/dev/null
    getent group sudo &>/dev/null || { groupadd sudo 2>/dev/null; usermod -aG sudo "$NEW_USER" 2>/dev/null; }
    ok "用户 ${GREEN}$NEW_USER${NC} 创建成功 (sudo 需密码)"

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

    if command -v ufw &>/dev/null; then ufw allow "$NEW_PORT"/tcp 2>/dev/null; fi
    if command -v firewall-cmd &>/dev/null; then firewall-cmd --permanent --add-port="$NEW_PORT"/tcp 2>/dev/null && firewall-cmd --reload 2>/dev/null; fi

    if sshd -t 2>/dev/null; then
        restart_ssh_safe "$SSH_SERVICE" "$NEW_PORT" "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG"
        ok "SSH 端口: ${GREEN}$NEW_PORT${NC}"
    else
        cp "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG" 2>/dev/null
        systemctl restart "$SSH_SERVICE" 2>/dev/null || service ssh restart 2>/dev/null || true
        err "SSH 配置错误，已回滚"
    fi

    enable_auto_updates
    install_vps_shortcut

    IPV4=$(get_public_ipv4); [ -z "$IPV4" ] && IPV4="无"
    IPV6=$(get_public_ipv6); [ -z "$IPV6" ] && IPV6="无"
    CLIENT_IP_END=$(get_client_ip)

    clear
    echo -e "${GREEN}════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              🎉 初始化完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════${NC}"
    print_row "${ICON_HOST} 主机名"   "${WHITE}$NEW_HOSTNAME${NC}"
    print_row "${ICON_CLOCK} 时区"     "${WHITE}$TIMEZONE${NC}"
    print_row "${ICON_USER} 用户"     "${WHITE}$NEW_USER${NC} ${YELLOW}(sudo需密码)${NC}"
    print_row "${ICON_PORT} SSH端口"  "${WHITE}$NEW_PORT${NC} ${YELLOW}(原:$CURRENT_PORT)${NC}"
    print_row "${ICON_LOCK} root登录" "${RED}已禁止${NC}"
    print_row "${ICON_IPV4} IPv4"     "${WHITE}$IPV4${NC}"
    print_row "${ICON_IPV6} IPv6"     "${WHITE}$IPV6${NC}"
    print_row "${ICON_CLIENT} 连接IP"  "${WHITE}$CLIENT_IP_END${NC}"
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"
    echo -e "  ${ICON_WARN} ${YELLOW}立即测试新连接:${NC}"
    echo -e "  ${WHITE}ssh -p $NEW_PORT $NEW_USER@$IPV4${NC}"
    [ "$IPV6" != "无" ] && echo -e "  ${WHITE}ssh -p $NEW_PORT $NEW_USER@$IPV6${NC}"
    echo -e "  ${ICON_MENU} 输入 ${WHITE}vps${NC} 打开管理菜单"
    echo -e "${GREEN}════════════════════════════════════════════════${NC}"
    echo ""

    management_menu
}

if [ "$(basename "$0")" = "vps" ]; then
    check_root
    detect_pkg_manager
    management_menu
else
    main "$@"
fi
