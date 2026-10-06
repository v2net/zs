#!/bin/bash

# ============================================================
# sign.sh
#
# 首次申请：
#
# curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s \
# <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>
#
# 示例：
#
# curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s \
# node.example.com /etc/node 99.cer 99.key
#
# 功能：
#
# 1. 首次申请 Let's Encrypt 证书
# 2. HTTP-01 / TCP 80 验证
# 3. 持久化 lego ACME 状态
# 4. 自动安装 systemd 定时续期
# 5. 每天检查证书
# 6. 剩余 30 天以内自动续期
# 7. 续期成功后覆盖目标证书和私钥
# 8. 验证证书与私钥匹配
# 9. 确认真正换证后自动重启 VPS
#
# ============================================================

set -u

# ============================================================
# 参数
# ============================================================

DOMAIN="${1:-}"
CERT_DIR="${2:-}"
CERT_NAME="${3:-}"
KEY_NAME="${4:-}"

# 自动续期模式
MODE="${5:-install}"

# ============================================================
# lego
# ============================================================

LEGO_VERSION="v3.7.0"
LEGO_FILE="lego_v3.7.0_linux_amd64.tar.gz"
LEGO_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${LEGO_FILE}"

# ============================================================
# 持久化目录
# ============================================================

LEGO_PATH="/var/lib/lego"
CONFIG_DIR="/etc/acme-cert"
CONFIG_FILE="$CONFIG_DIR/config"

SYSTEMD_SERVICE="acme-cert-renew.service"
SYSTEMD_TIMER="acme-cert-renew.timer"

LOCAL_SCRIPT="/root/acme-cert-renew"

# 自动续期脚本仅在首次安装/重新安装时从这里下载一次。
REMOTE_SCRIPT="https://raw.githubusercontent.com/v2net/zs/main/sign.sh"

# ============================================================
# 临时工作目录
# ============================================================

WORK_DIR="/tmp/acme-cert"

# ============================================================
# 输出函数
# ============================================================

info() {
    echo "[INFO] $1"
}

warn() {
    echo "[WARN] $1"
}

error() {
    echo "[ERROR] $1"
}

die() {
    error "$1"
    exit 1
}

# ============================================================
# Root
# ============================================================

if [ "$(id -u)" != "0" ]; then
    die "请使用 root 用户执行"
fi

# ============================================================
# 参数检查
# ============================================================

if [ "$MODE" = "renew" ]; then
    :
else

    if [ -z "$DOMAIN" ] || \
       [ -z "$CERT_DIR" ] || \
       [ -z "$CERT_NAME" ] || \
       [ -z "$KEY_NAME" ]; then

        echo ""
        echo "参数错误！"
        echo ""
        echo "正确用法："
        echo ""
        echo "curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>"
        echo ""
        exit 1
    fi

fi

# ============================================================
# 自动续期模式
# ============================================================

if [ "$MODE" = "renew" ]; then

    if [ ! -f "$CONFIG_FILE" ]; then
        die "找不到自动续期配置：$CONFIG_FILE"
    fi

    # shellcheck disable=SC1090
    . "$CONFIG_FILE"

    if [ -z "${DOMAIN:-}" ] || \
       [ -z "${CERT_DIR:-}" ] || \
       [ -z "${CERT_NAME:-}" ] || \
       [ -z "${KEY_NAME:-}" ]; then

        die "自动续期配置不完整"
    fi

fi

# ============================================================
# 域名检查
# ============================================================

if ! echo "$DOMAIN" | grep -Eq \
    '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then

    die "域名格式不正确"
fi

# ============================================================
# 文件名检查
# ============================================================

case "$CERT_NAME" in
    */*|"")
        die "证书文件名不能包含 /"
        ;;
esac

case "$KEY_NAME" in
    */*|"")
        die "私钥文件名不能包含 /"
        ;;
esac

# ============================================================
# 创建持久化目录
# ============================================================

mkdir -p "$LEGO_PATH" || \
    die "无法创建 ACME 状态目录"

mkdir -p "$CONFIG_DIR" || \
    die "无法创建配置目录"

chmod 700 "$LEGO_PATH"
chmod 700 "$CONFIG_DIR"

# ============================================================
# 保存配置
#
# 不把域名 / 路径直接写进 systemd unit。
# 配置文件仅 root 可读。
# ============================================================

save_config() {

    cat > "$CONFIG_FILE" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
CERT_DIR=$(printf '%q' "$CERT_DIR")
CERT_NAME=$(printf '%q' "$CERT_NAME")
KEY_NAME=$(printf '%q' "$KEY_NAME")
EOF

    chmod 600 "$CONFIG_FILE"
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    info "检查系统依赖..."

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1 || \
            die "apt update 失败"

        apt-get install -y \
            curl \
            wget \
            tar \
            ca-certificates \
            openssl \
            >/dev/null 2>&1 || \
            die "依赖安装失败"

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            wget \
            tar \
            ca-certificates \
            openssl \
            >/dev/null 2>&1 || \
            die "依赖安装失败"

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            wget \
            tar \
            ca-certificates \
            openssl \
            >/dev/null 2>&1 || \
            die "依赖安装失败"

    else

        die "无法识别包管理器"

    fi
}

# ============================================================
# 安装 / 获取 lego
# ============================================================

install_lego() {

    mkdir -p "$WORK_DIR"

    chmod 700 "$WORK_DIR"

    if [ -x "$LEGO_PATH/lego" ]; then
        return 0
    fi

    info "下载 lego ${LEGO_VERSION}..."

    cd "$WORK_DIR" || \
        die "无法进入工作目录"

    rm -f "$LEGO_FILE"

    wget -q --show-progress \
        -O "$LEGO_FILE" \
        "$LEGO_URL" || \
        die "lego 下载失败"

    if [ ! -s "$LEGO_FILE" ]; then
        die "lego 下载文件为空"
    fi

    info "安装 lego..."

    tar -zxf "$LEGO_FILE" || \
        die "lego 解压失败"

    if [ ! -f "$WORK_DIR/lego" ]; then
        die "找不到 lego 可执行文件"
    fi

    chmod 755 "$WORK_DIR/lego"

    cp -f "$WORK_DIR/lego" "$LEGO_PATH/lego" || \
        die "无法安装 lego"

    chmod 755 "$LEGO_PATH/lego"

    rm -f "$WORK_DIR/$LEGO_FILE"
    rm -f "$WORK_DIR/lego"
}

# ============================================================
# DNS 检查
# ============================================================

check_dns() {

    info "检查 DNS 解析..."

    DOMAIN_IPS=""

    if command -v getent >/dev/null 2>&1; then

        DOMAIN_IPS="$(
            getent ahostsv4 "$DOMAIN" 2>/dev/null |
            awk '{print $1}' |
            sort -u
        )"

    fi

    if [ -z "$DOMAIN_IPS" ]; then
        die "域名没有解析到 IPv4"
    fi

    echo ""
    echo "DNS IPv4："
    echo "$DOMAIN_IPS" | while read -r ip; do
        echo "  $ip"
    done
    echo ""

    PUBLIC_IP=""

    if command -v curl >/dev/null 2>&1; then

        PUBLIC_IP="$(
            curl -4 -fsSL \
                --max-time 10 \
                https://api.ipify.org \
                2>/dev/null || true
        )"

    fi

    if [ -z "$PUBLIC_IP" ] && \
       command -v wget >/dev/null 2>&1; then

        PUBLIC_IP="$(
            wget -4 -qO- \
                --timeout=10 \
                https://api.ipify.org \
                2>/dev/null || true
        )"

    fi

    if [ -n "$PUBLIC_IP" ]; then

        if echo "$DOMAIN_IPS" | grep -qx "$PUBLIC_IP"; then

            info "DNS 检查通过"

        else

            warn "域名解析 IP 与当前服务器公网 IPv4 不一致"
            warn "如果使用 CDN、NAT 或代理，可以忽略"

        fi

    fi
}

# ============================================================
# 检查 TCP 80
# ============================================================

check_port80() {

    info "检查 TCP 80 端口..."

    PORT80_PROCESS=""

    if command -v ss >/dev/null 2>&1; then

        PORT80_PROCESS="$(
            ss -ltnp 2>/dev/null |
            grep -E ':[[:space:]]*80[[:space:]]' ||
            true
        )"

    elif command -v netstat >/dev/null 2>&1; then

        PORT80_PROCESS="$(
            netstat -ltnp 2>/dev/null |
            grep -E ':[[:space:]]*80[[:space:]]' ||
            true
        )"

    fi

    if [ -n "$PORT80_PROCESS" ]; then

        echo ""
        warn "发现程序正在监听 TCP 80："
        echo "$PORT80_PROCESS"
        echo ""

        if [ "$MODE" = "renew" ]; then

            warn "自动续期模式不会进行交互确认"

        else

            read -r -p "是否继续申请？[y/N]: " CONTINUE

            case "$CONTINUE" in
                y|Y|yes|YES)
                    ;;
                *)
                    echo "已取消"
                    exit 1
                    ;;
            esac

        fi

    fi
}

# ============================================================
# 备份证书
# ============================================================

backup_current_certificate() {

    OLD_CERT="$CERT_DIR/$CERT_NAME"
    OLD_KEY="$CERT_DIR/$KEY_NAME"

    if [ ! -f "$OLD_CERT" ] && [ ! -f "$OLD_KEY" ]; then
        return 0
    fi

    BACKUP_DIR="$CERT_DIR/.backup-$(date +%Y%m%d-%H%M%S)"

    info "备份当前证书"

    mkdir -p "$BACKUP_DIR"

    [ -f "$OLD_CERT" ] && \
        cp -a "$OLD_CERT" "$BACKUP_DIR/"

    [ -f "$OLD_KEY" ] && \
        cp -a "$OLD_KEY" "$BACKUP_DIR/"

    chmod 700 "$BACKUP_DIR"
}

# ============================================================
# 验证证书与私钥
# ============================================================

verify_certificate() {

    CERT_FILE="$1"
    KEY_FILE="$2"

    if [ ! -s "$CERT_FILE" ]; then
        die "证书文件不存在或为空"
    fi

    if [ ! -s "$KEY_FILE" ]; then
        die "私钥文件不存在或为空"
    fi

    if ! openssl x509 \
        -in "$CERT_FILE" \
        -noout \
        -subject \
        -issuer \
        -dates >/dev/null 2>&1; then

        die "证书格式验证失败"
    fi

    CERT_PUBLIC_KEY="$WORK_DIR/cert.pub"
    KEY_PUBLIC_KEY="$WORK_DIR/key.pub"

    openssl x509 \
        -in "$CERT_FILE" \
        -pubkey \
        -noout > "$CERT_PUBLIC_KEY" || \
        die "无法读取证书公钥"

    openssl pkey \
        -in "$KEY_FILE" \
        -pubout > "$KEY_PUBLIC_KEY" || \
        die "无法读取私钥公钥"

    if ! cmp -s \
        "$CERT_PUBLIC_KEY" \
        "$KEY_PUBLIC_KEY"; then

        die "证书与私钥不匹配"
    fi

    info "证书与私钥匹配"
}

# ============================================================
# 安装自动续期脚本
#
# 首次安装时只从 GitHub 下载一次当前版本，保存到
# /usr/local/sbin/acme-cert-renew。
# 后续 systemd 续期直接执行本地脚本，不会每天重新拉取远程代码。
# 如需更新续期脚本，重新执行一次首次安装命令即可。
# ============================================================

install_local_renew_script() {

    info "安装自动续期入口..."

    mkdir -p "$(dirname "$LOCAL_SCRIPT")" || \
        die "无法创建自动续期脚本目录"

    if ! command -v curl >/dev/null 2>&1; then
        die "找不到 curl，无法安装自动续期脚本"
    fi

    TEMP_SCRIPT="$LOCAL_SCRIPT.tmp.$$"

    rm -f "$TEMP_SCRIPT"

    curl -fsSL \
        --max-time 30 \
        -o "$TEMP_SCRIPT" \
        "$REMOTE_SCRIPT" || \
        die "无法下载自动续期脚本"

    if [ ! -s "$TEMP_SCRIPT" ]; then
        rm -f "$TEMP_SCRIPT"
        die "自动续期脚本下载结果为空"
    fi

    chmod 700 "$TEMP_SCRIPT"

    mv -f "$TEMP_SCRIPT" "$LOCAL_SCRIPT" || {
        rm -f "$TEMP_SCRIPT"
        die "无法安装自动续期脚本"
    }

    chmod 700 "$LOCAL_SCRIPT"
}

# ============================================================
# systemd
# ============================================================

install_systemd_timer() {

    if ! command -v systemctl >/dev/null 2>&1; then

        warn "当前系统没有 systemd"
        warn "无法安装自动续期 timer"

        return 0
    fi

    info "安装自动续期 systemd..."

    install_local_renew_script

    cat > "/etc/systemd/system/$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Let's Encrypt Certificate Renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$LOCAL_SCRIPT
EOF

    cat > "/etc/systemd/system/$SYSTEMD_TIMER" <<EOF
[Unit]
Description=Daily Let's Encrypt Certificate Renewal Check

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable "$SYSTEMD_TIMER" >/dev/null 2>&1 || \
        die "无法启用自动续期 timer"

    systemctl restart "$SYSTEMD_TIMER" || \
        die "无法启动自动续期 timer"

    info "自动续期已启用"
}

# ============================================================
# 计算证书指纹
# ============================================================

certificate_fingerprint() {

    local CERT="$1"

    if [ ! -f "$CERT" ]; then
        echo ""
        return
    fi

    openssl x509 \
        -in "$CERT" \
        -noout \
        -fingerprint \
        -sha256 2>/dev/null |
        tr -d '\r\n'
}

# ============================================================
# 自动续期
# ============================================================

renew_certificate() {

    # 防止手动执行与 systemd timer 同时续期。
    LOCK_FILE="/run/acme-cert-renew.lock"

    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        info "已有自动续期任务正在运行，本次跳过"
        exit 0
    fi

    OLD_CERT="$CERT_DIR/$CERT_NAME"
    OLD_KEY="$CERT_DIR/$KEY_NAME"

    mkdir -p "$CERT_DIR"

    chmod 755 "$CERT_DIR"

    BEFORE_FINGERPRINT="$(
        certificate_fingerprint "$OLD_CERT"
    )"

    info "检查证书是否需要续期..."

    cd "$WORK_DIR" || \
        die "无法进入工作目录"

    "$LEGO_PATH/lego" \
        --path="$LEGO_PATH" \
        --email="admin@$DOMAIN" \
        --domains="$DOMAIN" \
        --http \
        renew \
        --days=30

    LEGO_RESULT=$?

    if [ "$LEGO_RESULT" -ne 0 ]; then

        warn "自动续期检查失败"

        exit "$LEGO_RESULT"
    fi

    SOURCE_CERT="$LEGO_PATH/certificates/$DOMAIN.crt"
    SOURCE_KEY="$LEGO_PATH/certificates/$DOMAIN.key"

    if [ ! -f "$SOURCE_CERT" ] || \
       [ ! -f "$SOURCE_KEY" ]; then

        die "续期后找不到证书文件"
    fi

    AFTER_FINGERPRINT="$(
        certificate_fingerprint "$SOURCE_CERT"
    )"

    # ========================================================
    # 没有真正换证
    # ========================================================

    if [ -n "$BEFORE_FINGERPRINT" ] && \
       [ "$BEFORE_FINGERPRINT" = "$AFTER_FINGERPRINT" ]; then

        info "当前证书无需续期"

        exit 0
    fi

    # ========================================================
    # 证书发生变化
    # ========================================================

    info "检测到新证书"

    BACKUP_DIR="$CERT_DIR/.backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    [ -f "$OLD_CERT" ] && \
        cp -a "$OLD_CERT" "$BACKUP_DIR/"

    [ -f "$OLD_KEY" ] && \
        cp -a "$OLD_KEY" "$BACKUP_DIR/"

    cp -f "$SOURCE_CERT" "$OLD_CERT" || \
        die "复制新证书失败"

    cp -f "$SOURCE_KEY" "$OLD_KEY" || \
        die "复制新私钥失败"

    chmod 644 "$OLD_CERT"
    chmod 600 "$OLD_KEY"

    # ========================================================
    # 最终验证
    # ========================================================

    verify_certificate "$OLD_CERT" "$OLD_KEY"

    FINAL_FINGERPRINT="$(
        certificate_fingerprint "$OLD_CERT"
    )"

    if [ -z "$FINAL_FINGERPRINT" ]; then
        die "无法确认新证书指纹"
    fi

    if [ "$FINAL_FINGERPRINT" = "$BEFORE_FINGERPRINT" ]; then

        warn "证书指纹没有发生变化"
        exit 0
    fi

    echo ""
    echo "=============================================="
    echo "          证书已成功续期"
    echo "=============================================="
    echo ""
    echo "证书：$OLD_CERT"
    echo "私钥：$OLD_KEY"
    echo ""
    echo "正在重启 VPS..."
    echo ""

    sync

    systemctl reboot
}

# ============================================================
# 自动续期入口
# ============================================================

if [ "$MODE" = "renew" ]; then

    # 自动续期不进行 DNS / 80 端口交互检查
    # lego 自己负责 HTTP-01 验证

    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"

    install_dependencies
    install_lego

    renew_certificate

    exit 0
fi

# ============================================================
# 首次申请
# ============================================================

umask 077

echo ""
echo "=============================================="
echo "           ACME 证书申请"
echo "=============================================="
echo ""
echo "域名       : $DOMAIN"
echo "证书目录   : $CERT_DIR"
echo "证书文件   : $CERT_NAME"
echo "私钥文件   : $KEY_NAME"
echo ""
echo "验证方式   : HTTP-01"
echo "验证端口   : TCP 80"
echo ""
echo "=============================================="
echo ""

install_dependencies

check_dns

check_port80

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

install_lego

mkdir -p "$CERT_DIR" || \
    die "无法创建证书目录"

OLD_CERT="$CERT_DIR/$CERT_NAME"
OLD_KEY="$CERT_DIR/$KEY_NAME"

backup_current_certificate

# ============================================================
# 保存自动续期配置
# ============================================================

save_config

# ============================================================
# 首次申请
# ============================================================

SOURCE_CERT="$LEGO_PATH/certificates/$DOMAIN.crt"
SOURCE_KEY="$LEGO_PATH/certificates/$DOMAIN.key"

echo ""
echo "=============================================="
echo "开始申请 Let's Encrypt 证书"
echo "=============================================="
echo ""

"$LEGO_PATH/lego" \
    --path="$LEGO_PATH" \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    -a run

LEGO_RESULT=$?

if [ "$LEGO_RESULT" -ne 0 ]; then

    echo ""
    echo "=============================================="
    error "证书申请失败"
    echo "=============================================="
    echo ""

    exit "$LEGO_RESULT"
fi

# ============================================================
# 检查生成文件
# ============================================================

if [ ! -f "$SOURCE_CERT" ]; then
    die "证书申请完成，但找不到生成的证书"
fi

if [ ! -f "$SOURCE_KEY" ]; then
    die "证书申请完成，但找不到生成的私钥"
fi

# ============================================================
# 复制证书
# ============================================================

info "复制证书..."

cp -f "$SOURCE_CERT" "$OLD_CERT" || \
    die "复制证书失败"

cp -f "$SOURCE_KEY" "$OLD_KEY" || \
    die "复制私钥失败"

chmod 644 "$OLD_CERT"
chmod 600 "$OLD_KEY"

# ============================================================
# 验证
# ============================================================

verify_certificate "$OLD_CERT" "$OLD_KEY"

# ============================================================
# 安装自动续期
# ============================================================

install_systemd_timer

# ============================================================
# 最终检查
# ============================================================

if [ ! -s "$OLD_CERT" ]; then
    die "最终证书文件不存在或为空"
fi

if [ ! -s "$OLD_KEY" ]; then
    die "最终私钥文件不存在或为空"
fi

# ============================================================
# 完成
# ============================================================

echo ""
echo "=============================================="
echo "          证书申请成功"
echo "=============================================="
echo ""
echo "证书："
echo "  $OLD_CERT"
echo ""
echo "私钥："
echo "  $OLD_KEY"
echo ""
echo "ACME 状态："
echo "  $LEGO_PATH"
echo ""
echo "自动续期："
echo "  每天检查一次"
echo "  剩余 30 天以内自动续期"
echo ""
echo "续期成功后："
echo "  自动覆盖证书"
echo "  自动验证证书 / 私钥"
echo "  自动重启 VPS"
echo ""
echo "=============================================="
echo ""

exit 0
