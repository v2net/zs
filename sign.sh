#!/bin/bash

# ============================================================
# Let's Encrypt 自动申请 + 自动续签
# lego v5.5.2
#
# 参数：
#
#   $1 = DOMAIN
#   $2 = CERT_DIR
#   $3 = CERT_NAME
#   $4 = KEY_NAME
#
# 用法：
#
# curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
# | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>
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

# ============================================================
# lego 配置
# ============================================================

LEGO_VERSION="v5.5.2"

LEGO_BIN="/usr/local/bin/lego"

# 独立保存新版 lego 数据
LEGO_PATH="/etc/lego"

# 自动续签脚本
RENEW_SCRIPT="/usr/local/bin/acme-cert-renew"

# systemd
SERVICE_FILE="/etc/systemd/system/acme-cert-renew.service"
TIMER_FILE="/etc/systemd/system/acme-cert-renew.timer"

# 日志
LOG_FILE="/var/log/acme-cert-renew.log"

# 临时目录
WORK_DIR="/tmp/acme-lego"

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
# 参数检查
# ============================================================

if [ -z "$DOMAIN" ] || \
   [ -z "$CERT_DIR" ] || \
   [ -z "$CERT_NAME" ] || \
   [ -z "$KEY_NAME" ]; then

    echo ""
    echo "参数错误"
    echo ""
    echo "用法："
    echo ""
    echo "curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>"
    echo ""

    exit 1
fi

# ============================================================
# Root 检查
# ============================================================

if [ "$(id -u)" != "0" ]; then
    die "请使用 root 用户执行"
fi

# ============================================================
# 域名检查
# ============================================================

if ! echo "$DOMAIN" | grep -Eq \
    '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then

    die "域名格式不正确：$DOMAIN"
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
# 最终文件路径
# ============================================================

CERT_FILE="$CERT_DIR/$CERT_NAME"
KEY_FILE="$CERT_DIR/$KEY_NAME"

LEGO_CERT="$LEGO_PATH/certificates/$DOMAIN.crt"
LEGO_KEY="$LEGO_PATH/certificates/$DOMAIN.key"

# ============================================================
# 检测 CPU 架构
# ============================================================

ARCH="$(uname -m)"

case "$ARCH" in

    x86_64|amd64)
        LEGO_ARCH="amd64"
        ;;

    aarch64|arm64)
        LEGO_ARCH="arm64"
        ;;

    armv7l|armv7)
        LEGO_ARCH="armv7"
        ;;

    *)
        die "暂不支持的 CPU 架构：$ARCH"
        ;;

esac

LEGO_FILE="lego_${LEGO_VERSION}_${LEGO_ARCH}.tar.gz"

LEGO_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${LEGO_FILE}"

# ============================================================
# 显示配置
# ============================================================

echo ""
echo "================================================"
echo "       Let's Encrypt Certificate Manager"
echo "================================================"
echo ""
echo "Domain       : $DOMAIN"
echo "Certificate  : $CERT_FILE"
echo "Private Key  : $KEY_FILE"
echo ""
echo "lego Version : $LEGO_VERSION"
echo "Architecture : $LEGO_ARCH"
echo "lego Path    : $LEGO_PATH"
echo ""
echo "Validation   : HTTP-01"
echo "Port         : 80"
echo ""
echo "Auto Renew   : Enabled"
echo "Renew Days   : 30"
echo "After Renew  : Reboot"
echo ""
echo "================================================"
echo ""

# ============================================================
# 安装系统依赖
# ============================================================

info "检查系统依赖..."

if command -v apt-get >/dev/null 2>&1; then

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y >/dev/null 2>&1 || \
        die "apt update 失败"

    apt-get install -y \
        wget \
        curl \
        tar \
        ca-certificates \
        openssl \
        >/dev/null 2>&1 || \
        die "依赖安装失败"

elif command -v dnf >/dev/null 2>&1; then

    dnf install -y \
        wget \
        curl \
        tar \
        ca-certificates \
        openssl \
        >/dev/null 2>&1 || \
        die "依赖安装失败"

elif command -v yum >/dev/null 2>&1; then

    yum install -y \
        wget \
        curl \
        tar \
        ca-certificates \
        openssl \
        >/dev/null 2>&1 || \
        die "依赖安装失败"

else

    die "无法识别系统包管理器"

fi

# ============================================================
# 创建目录
# ============================================================

mkdir -p "$CERT_DIR" || \
    die "无法创建证书目录：$CERT_DIR"

mkdir -p "$LEGO_PATH" || \
    die "无法创建 lego 数据目录：$LEGO_PATH"

chmod 700 "$LEGO_PATH"

mkdir -p "$WORK_DIR"

# ============================================================
# 安装 lego
# ============================================================

if [ -x "$LEGO_BIN" ]; then

    CURRENT_VERSION="$("$LEGO_BIN" --version 2>/dev/null || true)"

    if echo "$CURRENT_VERSION" | grep -q "$LEGO_VERSION"; then

        info "lego $LEGO_VERSION 已安装"

    else

        info "更新 lego 到 $LEGO_VERSION"

        rm -f "$LEGO_BIN"

    fi

fi

if [ ! -x "$LEGO_BIN" ]; then

    info "下载 lego $LEGO_VERSION..."

    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    cd "$WORK_DIR" || \
        die "无法进入临时目录"

    wget \
        --https-only \
        --timeout=30 \
        --tries=3 \
        -O "$LEGO_FILE" \
        "$LEGO_URL" || \
        die "lego 下载失败"

    [ -s "$LEGO_FILE" ] || \
        die "lego 下载文件为空"

    info "解压 lego..."

    tar -xzf "$LEGO_FILE" || \
        die "lego 解压失败"

    [ -f "$WORK_DIR/lego" ] || \
        die "解压后找不到 lego"

    chmod 755 "$WORK_DIR/lego"

    mv -f "$WORK_DIR/lego" "$LEGO_BIN"

    chmod 755 "$LEGO_BIN"

fi

# ============================================================
# 检查 lego
# ============================================================

info "检查 lego..."

"$LEGO_BIN" --version || \
    die "lego 无法正常运行"

# ============================================================
# DNS 检查
# ============================================================

info "检查 DNS..."

DOMAIN_IPS=""

if command -v getent >/dev/null 2>&1; then

    DOMAIN_IPS="$(
        getent ahostsv4 "$DOMAIN" 2>/dev/null |
        awk '{print $1}' |
        sort -u
    )"

fi

if [ -z "$DOMAIN_IPS" ]; then

    die "域名没有解析到 IPv4：$DOMAIN"

fi

echo ""
echo "DNS IPv4:"
echo "$DOMAIN_IPS"
echo ""

# ============================================================
# TCP 80 检查
# ============================================================

info "检查 TCP 80..."

PORT80_USED=""

if command -v ss >/dev/null 2>&1; then

    PORT80_USED="$(
        ss -lntp 2>/dev/null |
        awk '$4 ~ /:80$/ {print}'
    )"

elif command -v netstat >/dev/null 2>&1; then

    PORT80_USED="$(
        netstat -lntp 2>/dev/null |
        awk '$4 ~ /:80$/ {print}'
    )"

fi

if [ -n "$PORT80_USED" ]; then

    warn "TCP 80 当前已经被程序监听："
    echo "$PORT80_USED"
    echo ""
    warn "HTTP-01 验证需要使用 TCP 80"
    echo ""

fi

# ============================================================
# 备份当前证书
# ============================================================

if [ -f "$CERT_FILE" ] || [ -f "$KEY_FILE" ]; then

    BACKUP_DIR="$CERT_DIR/.backup-$(date +%Y%m%d-%H%M%S)"

    info "备份现有证书：$BACKUP_DIR"

    mkdir -p "$BACKUP_DIR"

    [ -f "$CERT_FILE" ] && \
        cp -a "$CERT_FILE" "$BACKUP_DIR/"

    [ -f "$KEY_FILE" ] && \
        cp -a "$KEY_FILE" "$BACKUP_DIR/"

fi

# ============================================================
# 首次申请证书
# ============================================================

echo ""
echo "================================================"
echo "开始申请 Let's Encrypt 证书"
echo "================================================"
echo ""

"$LEGO_BIN" \
    --path="$LEGO_PATH" \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    run

RESULT=$?

if [ "$RESULT" -ne 0 ]; then

    echo ""
    echo "================================================"
    error "证书申请失败"
    echo "================================================"
    echo ""

    exit "$RESULT"

fi

# ============================================================
# 检查证书文件
# ============================================================

[ -f "$LEGO_CERT" ] || \
    die "找不到生成的证书：$LEGO_CERT"

[ -f "$LEGO_KEY" ] || \
    die "找不到生成的私钥：$LEGO_KEY"

# ============================================================
# 验证证书
# ============================================================

info "验证证书..."

openssl x509 \
    -in "$LEGO_CERT" \
    -noout \
    -subject \
    -issuer \
    -dates || \
    die "证书验证失败"

# ============================================================
# 验证私钥
# ============================================================

openssl pkey \
    -in "$LEGO_KEY" \
    -noout >/dev/null 2>&1 || \
    die "私钥验证失败"

# ============================================================
# 验证证书和私钥匹配
# ============================================================

CERT_PUB="$WORK_DIR/cert.pub"
KEY_PUB="$WORK_DIR/key.pub"

openssl x509 \
    -in "$LEGO_CERT" \
    -pubkey \
    -noout > "$CERT_PUB" || \
    die "无法读取证书公钥"

openssl pkey \
    -in "$LEGO_KEY" \
    -pubout > "$KEY_PUB" || \
    die "无法读取私钥公钥"

if ! cmp -s "$CERT_PUB" "$KEY_PUB"; then

    die "证书和私钥不匹配"

fi

info "证书和私钥匹配"

# ============================================================
# 覆盖目标证书
# ============================================================

info "覆盖目标证书..."

cp -f "$LEGO_CERT" "$CERT_FILE" || \
    die "复制证书失败"

cp -f "$LEGO_KEY" "$KEY_FILE" || \
    die "复制私钥失败"

chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

# ============================================================
# 创建自动续签脚本
# ============================================================

info "创建自动续签脚本..."

cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash

set -u

DOMAIN="$DOMAIN"

CERT_DIR="$CERT_DIR"
CERT_NAME="$CERT_NAME"
KEY_NAME="$KEY_NAME"

CERT_FILE="\$CERT_DIR/\$CERT_NAME"
KEY_FILE="\$CERT_DIR/\$KEY_NAME"

LEGO_BIN="$LEGO_BIN"
LEGO_PATH="$LEGO_PATH"

LEGO_CERT="\$LEGO_PATH/certificates/\$DOMAIN.crt"
LEGO_KEY="\$LEGO_PATH/certificates/\$DOMAIN.key"

LOG_FILE="$LOG_FILE"

exec >> "\$LOG_FILE" 2>&1

echo ""
echo "================================================"
echo "\$(date '+%Y-%m-%d %H:%M:%S')"
echo "开始检查证书续签"
echo "================================================"

# ============================================================
# 记录旧证书指纹
# ============================================================

if [ -f "\$LEGO_CERT" ]; then

    OLD_FINGERPRINT="\$(
        openssl x509 \
            -in "\$LEGO_CERT" \
            -noout \
            -fingerprint \
            -sha256 2>/dev/null |
        cut -d= -f2
    )"

else

    OLD_FINGERPRINT=""

fi

echo "旧证书指纹：\$OLD_FINGERPRINT"

# ============================================================
# 执行续签
# ============================================================

echo "执行 lego renew..."

"\$LEGO_BIN" \
    --path="\$LEGO_PATH" \
    --email="admin@\$DOMAIN" \
    --domains="\$DOMAIN" \
    --http \
    --renew-days=30 \
    --no-random-sleep \
    renew

RESULT=\$?

if [ "\$RESULT" -ne 0 ]; then

    echo "[ERROR] lego 续签失败"
    echo "[ERROR] 保留原证书"
    echo "[ERROR] 不重启 VPS"

    exit "\$RESULT"

fi

# ============================================================
# 检查证书文件
# ============================================================

if [ ! -f "\$LEGO_CERT" ] || [ ! -f "\$LEGO_KEY" ]; then

    echo "[ERROR] 找不到证书文件"
    echo "[ERROR] 不重启 VPS"

    exit 1

fi

# ============================================================
# 获取新证书指纹
# ============================================================

NEW_FINGERPRINT="\$(
    openssl x509 \
        -in "\$LEGO_CERT" \
        -noout \
        -fingerprint \
        -sha256 2>/dev/null |
    cut -d= -f2
)"

echo "新证书指纹：\$NEW_FINGERPRINT"

# ============================================================
# 没有实际续签
# ============================================================

if [ -n "\$OLD_FINGERPRINT" ] && \
   [ "\$OLD_FINGERPRINT" = "\$NEW_FINGERPRINT" ]; then

    echo "[INFO] 当前证书暂时不需要续签"
    echo "[INFO] 不覆盖证书"
    echo "[INFO] 不重启 VPS"

    exit 0

fi

# ============================================================
# 验证新证书
# ============================================================

echo "验证新证书..."

openssl x509 \
    -in "\$LEGO_CERT" \
    -noout \
    -subject \
    -issuer \
    -dates || {

    echo "[ERROR] 新证书验证失败"
    echo "[ERROR] 不覆盖旧证书"
    echo "[ERROR] 不重启 VPS"

    exit 1
}

# ============================================================
# 验证新私钥
# ============================================================

openssl pkey \
    -in "\$LEGO_KEY" \
    -noout >/dev/null 2>&1 || {

    echo "[ERROR] 新私钥验证失败"
    echo "[ERROR] 不覆盖旧私钥"
    echo "[ERROR] 不重启 VPS"

    exit 1
}

# ============================================================
# 验证证书 / 私钥匹配
# ============================================================

CERT_PUB="/tmp/acme-cert.pub"
KEY_PUB="/tmp/acme-key.pub"

openssl x509 \
    -in "\$LEGO_CERT" \
    -pubkey \
    -noout > "\$CERT_PUB" || exit 1

openssl pkey \
    -in "\$LEGO_KEY" \
    -pubout > "\$KEY_PUB" || exit 1

if ! cmp -s "\$CERT_PUB" "\$KEY_PUB"; then

    echo "[ERROR] 新证书和私钥不匹配"

    rm -f "\$CERT_PUB" "\$KEY_PUB"

    exit 1

fi

rm -f "\$CERT_PUB" "\$KEY_PUB"

echo "[INFO] 新证书和私钥匹配"

# ============================================================
# 备份当前证书
# ============================================================

BACKUP_DIR="\$CERT_DIR/.backup-\$(date +%Y%m%d-%H%M%S)"

mkdir -p "\$BACKUP_DIR"

[ -f "\$CERT_FILE" ] && \
    cp -a "\$CERT_FILE" "\$BACKUP_DIR/"

[ -f "\$KEY_FILE" ] && \
    cp -a "\$KEY_FILE" "\$BACKUP_DIR/"

# ============================================================
# 覆盖证书
# ============================================================

echo "覆盖证书..."

cp -f "\$LEGO_CERT" "\$CERT_FILE" || {

    echo "[ERROR] 覆盖证书失败"
    exit 1
}

cp -f "\$LEGO_KEY" "\$KEY_FILE" || {

    echo "[ERROR] 覆盖私钥失败"
    exit 1
}

chmod 644 "\$CERT_FILE"
chmod 600 "\$KEY_FILE"

# ============================================================
# 最终验证
# ============================================================

openssl x509 \
    -in "\$CERT_FILE" \
    -noout >/dev/null 2>&1 || {

    echo "[ERROR] 目标证书验证失败"
    exit 1
}

openssl pkey \
    -in "\$KEY_FILE" \
    -noout >/dev/null 2>&1 || {

    echo "[ERROR] 目标私钥验证失败"
    exit 1
}

echo ""
echo "================================================"
echo "证书续签成功"
echo "================================================"
echo ""
echo "Certificate: \$CERT_FILE"
echo "Private Key : \$KEY_FILE"
echo ""
echo "VPS 将在 5 秒后重启"
echo ""

sleep 5

/sbin/reboot
EOF

chmod 700 "$RENEW_SCRIPT"

# ============================================================
# 创建 systemd service
# ============================================================

info "创建 systemd service..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ACME Certificate Renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RENEW_SCRIPT
EOF

# ============================================================
# 创建 systemd timer
# ============================================================

info "创建 systemd timer..."

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=ACME Certificate Renewal Timer

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

# ============================================================
# 启用自动续签
# ============================================================

systemctl daemon-reload

systemctl enable acme-cert-renew.timer >/dev/null 2>&1 || \
    die "无法启用自动续签定时器"

systemctl restart acme-cert-renew.timer || \
    die "无法启动自动续签定时器"

# ============================================================
# 清理临时文件
# ============================================================

rm -rf "$WORK_DIR"

# ============================================================
# 最终结果
# ============================================================

echo ""
echo "================================================"
echo "              安装完成"
echo "================================================"
echo ""

echo "证书："
echo "  $CERT_FILE"

echo ""
echo "私钥："
echo "  $KEY_FILE"

echo ""
echo "lego："
"$LEGO_BIN" --version

echo ""
echo "自动续签："
echo "  已开启"

echo ""
echo "检查频率："
echo "  每天一次"

echo ""
echo "续签阈值："
echo "  剩余 30 天"

echo ""
echo "续签成功："
echo "  覆盖证书"
echo "  验证证书"
echo "  自动重启 VPS"

echo ""
echo "查看定时器："
echo "  systemctl status acme-cert-renew.timer"

echo ""
echo "查看续签日志："
echo "  cat $LOG_FILE"

echo ""
echo "================================================"
echo ""

exit 0
