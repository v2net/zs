#!/bin/bash

# ============================================================
# Let's Encrypt certificate installer / auto-renewer
#
# 用法：
#
# curl -fsSL https://你的地址/sign.sh | bash -s -- \
#   <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>
#
# 示例格式：
#
# curl -fsSL https://你的地址/sign.sh | bash -s -- \
#   example.com /etc/example example.cer example.key
#
# 功能：
#   1. 安装 lego v5.5.2
#   2. 使用 HTTP-01 申请 Let's Encrypt 证书
#   3. lego 数据永久保存
#   4. 将证书复制到用户指定目录/文件名
#   5. 验证证书和私钥是否匹配
#   6. 安装 systemd 自动续期
#   7. 每天自动检查
#   8. 证书剩余 <= 30 天时自动续期
#   9. 证书真正更新后才覆盖目标证书
#  10. 证书更新成功后才重启 VPS
#
# 注意：
#   HTTP-01 模式需要 TCP 80 能够被 lego 使用。
#   如果 Nginx / Apache / Caddy 占用 80，需要改用 webroot。
# ============================================================

set -u

# ============================================================
# 基础配置
# ============================================================

LEGO_VERSION="v5.5.2"
LEGO_BIN="/usr/local/bin/lego"
LEGO_PATH="/var/lib/lego"

RENEW_BIN="/usr/local/sbin/lego-cert-renew"

SYSTEMD_DIR="/etc/systemd/system"

WORK_DIR="/tmp/lego-install-$$"

RENEW_DAYS="30"

# ============================================================
# 参数
# ============================================================

DOMAIN="${1:-}"
CERT_DIR="${2:-}"
CERT_NAME="${3:-}"
KEY_NAME="${4:-}"

# ============================================================
# 输出
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
    echo "用法："
    echo ""
    echo "curl -fsSL https://你的地址/sign.sh | bash -s -- <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>"
    echo ""

    exit 1
fi

# ============================================================
# Root
# ============================================================

if [ "$(id -u)" != "0" ]; then
    die "必须使用 root 用户执行"
fi

# ============================================================
# 域名检查
# ============================================================

if ! echo "$DOMAIN" | grep -Eq \
    '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then

    die "域名格式不正确：$DOMAIN"
fi

# ============================================================
# 文件名安全检查
# ============================================================

case "$CERT_NAME" in
    ""|"/"|*/*|"."|"..")
        die "证书文件名非法：$CERT_NAME"
        ;;
esac

case "$KEY_NAME" in
    ""|"/"|*/*|"."|"..")
        die "私钥文件名非法：$KEY_NAME"
        ;;
esac

# ============================================================
# 目录检查
# ============================================================

if [ "$CERT_DIR" = "/" ]; then
    die "CERT_DIR 不能设置为 /"
fi

mkdir -p "$CERT_DIR" || \
    die "无法创建证书目录：$CERT_DIR"

mkdir -p "$LEGO_PATH" || \
    die "无法创建 lego 数据目录：$LEGO_PATH"

chmod 700 "$LEGO_PATH"

# ============================================================
# 目标文件
# ============================================================

TARGET_CERT="$CERT_DIR/$CERT_NAME"
TARGET_KEY="$CERT_DIR/$KEY_NAME"

# ============================================================
# 配置显示
# ============================================================

echo ""
echo "================================================"
echo " Let's Encrypt Certificate Installer"
echo "================================================"
echo ""
echo "Domain       : $DOMAIN"
echo "Certificate  : $TARGET_CERT"
echo "Private Key  : $TARGET_KEY"
echo "lego         : $LEGO_VERSION"
echo "lego data    : $LEGO_PATH"
echo "Renew window : $RENEW_DAYS days"
echo "Challenge    : HTTP-01"
echo ""
echo "================================================"
echo ""

# ============================================================
# 安装系统依赖
# ============================================================

info "检查系统依赖..."

install_dependencies_apt() {

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y >/dev/null 2>&1 || \
        die "apt-get update 失败"

    apt-get install -y \
        curl \
        ca-certificates \
        tar \
        openssl \
        >/dev/null 2>&1 || \
        die "依赖安装失败"
}

install_dependencies_dnf() {

    dnf install -y \
        curl \
        ca-certificates \
        tar \
        openssl \
        >/dev/null 2>&1 || \
        die "依赖安装失败"
}

install_dependencies_yum() {

    yum install -y \
        curl \
        ca-certificates \
        tar \
        openssl \
        >/dev/null 2>&1 || \
        die "依赖安装失败"
}

if command -v apt-get >/dev/null 2>&1; then

    install_dependencies_apt

elif command -v dnf >/dev/null 2>&1; then

    install_dependencies_dnf

elif command -v yum >/dev/null 2>&1; then

    install_dependencies_yum

else

    die "无法识别系统包管理器"
fi

# ============================================================
# 检查必要命令
# ============================================================

for cmd in curl tar openssl sha256sum; do

    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "缺少命令：$cmd"
    fi

done

# ============================================================
# CPU 架构
# ============================================================

SYSTEM_ARCH="$(uname -m)"

case "$SYSTEM_ARCH" in

    x86_64|amd64)
        LEGO_ARCH="amd64"
        ;;

    aarch64|arm64)
        LEGO_ARCH="arm64"
        ;;

    armv7l|armv7)
        LEGO_ARCH="armv7"
        ;;

    386|i386|i686)
        LEGO_ARCH="386"
        ;;

    *)
        die "不支持的 CPU 架构：$SYSTEM_ARCH"
        ;;

esac

info "系统架构：$SYSTEM_ARCH"
info "lego 架构：$LEGO_ARCH"

# ============================================================
# lego 下载
# ============================================================

mkdir -p "$WORK_DIR"

LEGO_FILE="lego_${LEGO_VERSION#v}_linux_${LEGO_ARCH}.tar.gz"

LEGO_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${LEGO_FILE}"

CHECKSUM_FILE="lego_${LEGO_VERSION#v}_checksums.txt"

CHECKSUM_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${CHECKSUM_FILE}"

info "下载 lego ${LEGO_VERSION}..."

curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$WORK_DIR/$LEGO_FILE" \
    "$LEGO_URL" || {

    die "lego 下载失败：$LEGO_URL"
}

# ============================================================
# 下载官方 SHA256
# ============================================================

info "下载 lego SHA256 校验文件..."

curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$WORK_DIR/$CHECKSUM_FILE" \
    "$CHECKSUM_URL" || {

    die "lego SHA256 文件下载失败"
}

# ============================================================
# SHA256 验证
# ============================================================

info "验证 lego SHA256..."

EXPECTED_SHA256="$(
    awk -v file="$LEGO_FILE" '
        $NF == file {
            print $1
            exit
        }
    ' "$WORK_DIR/$CHECKSUM_FILE"
)"

if [ -z "$EXPECTED_SHA256" ]; then
    die "官方 SHA256 文件中找不到：$LEGO_FILE"
fi

ACTUAL_SHA256="$(
    sha256sum "$WORK_DIR/$LEGO_FILE" |
    awk '{print $1}'
)"

if [ "$EXPECTED_SHA256" != "$ACTUAL_SHA256" ]; then

    error "lego SHA256 校验失败"
    error "Expected: $EXPECTED_SHA256"
    error "Actual  : $ACTUAL_SHA256"

    exit 1
fi

info "lego SHA256 校验通过"

# ============================================================
# 解压
# ============================================================

info "解压 lego..."

tar -xzf "$WORK_DIR/$LEGO_FILE" \
    -C "$WORK_DIR" \
    lego || {

    die "lego 解压失败"
}

if [ ! -f "$WORK_DIR/lego" ]; then
    die "解压后找不到 lego"
fi

chmod 0755 "$WORK_DIR/lego"

# ============================================================
# 安装 lego
# ============================================================

info "安装 lego..."

install -m 0755 \
    "$WORK_DIR/lego" \
    "$LEGO_BIN" || {

    die "安装 lego 失败"
}

# ============================================================
# 检查版本
# ============================================================

INSTALLED_VERSION="$(
    "$LEGO_BIN" --version 2>/dev/null |
    head -n 1
)"

info "已安装：$INSTALLED_VERSION"

# ============================================================
# 检查 HTTP 80
# ============================================================

PORT80_IN_USE=""

if command -v ss >/dev/null 2>&1; then

    PORT80_IN_USE="$(
        ss -ltnp 2>/dev/null |
        awk '$4 ~ /:80$/ || $4 ~ /\]:80$/'
    )"

elif command -v netstat >/dev/null 2>&1; then

    PORT80_IN_USE="$(
        netstat -ltnp 2>/dev/null |
        awk '$4 ~ /:80$/ || $4 ~ /\]:80$/'
    )"

fi

if [ -n "$PORT80_IN_USE" ]; then

    echo ""
    warn "检测到 TCP 80 已经被程序监听："
    echo "$PORT80_IN_USE"
    echo ""
    warn "当前使用 HTTP-01 内置 HTTP 服务。"
    warn "lego 需要使用 TCP 80。"
    echo ""

    read -r -p "继续申请证书吗？[y/N]: " ANSWER

    case "$ANSWER" in

        y|Y|yes|YES)
            info "继续..."
            ;;

        *)
            die "已取消"
            ;;

    esac

else

    info "TCP 80 未发现监听程序"

fi

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

    warn "系统 DNS 没有解析到 IPv4：$DOMAIN"
    warn "Let's Encrypt HTTP-01 可能无法验证。"

else

    echo ""
    echo "DNS IPv4："
    echo "$DOMAIN_IPS"
    echo ""

fi

# ============================================================
# 检查公网 IPv4
# ============================================================

PUBLIC_IP="$(
    curl -4 -fsSL \
        --connect-timeout 10 \
        --max-time 15 \
        https://api.ipify.org \
        2>/dev/null ||
        true
)"

if [ -n "$PUBLIC_IP" ]; then

    info "服务器公网 IPv4：$PUBLIC_IP"

    if [ -n "$DOMAIN_IPS" ]; then

        if echo "$DOMAIN_IPS" | grep -Fxq "$PUBLIC_IP"; then

            info "DNS IPv4 与服务器公网 IPv4 匹配"

        else

            warn "DNS IPv4 与服务器公网 IPv4 不一致"

            echo "DNS："
            echo "$DOMAIN_IPS"

            echo "Server："
            echo "$PUBLIC_IP"

            warn "如果你使用 CDN / NAT / 反向代理，这可能是正常的。"

        fi

    fi
fi

# ============================================================
# 证书备份
# ============================================================

BACKUP_DIR=""

if [ -f "$TARGET_CERT" ] || [ -f "$TARGET_KEY" ]; then

    BACKUP_DIR="$CERT_DIR/.lego-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_DIR"

    if [ -f "$TARGET_CERT" ]; then
        cp -a "$TARGET_CERT" "$BACKUP_DIR/"
    fi

    if [ -f "$TARGET_KEY" ]; then
        cp -a "$TARGET_KEY" "$BACKUP_DIR/"
    fi

    info "已有证书已备份到：$BACKUP_DIR"
fi

# ============================================================
# lego 证书路径
# ============================================================

LEGO_CERT="$LEGO_PATH/certificates/$DOMAIN.crt"
LEGO_KEY="$LEGO_PATH/certificates/$DOMAIN.key"

# ============================================================
# 获取旧证书指纹
# ============================================================

OLD_FINGERPRINT=""

if [ -f "$LEGO_CERT" ]; then

    OLD_FINGERPRINT="$(
        openssl x509 \
            -in "$LEGO_CERT" \
            -noout \
            -fingerprint \
            -sha256 2>/dev/null |
        sed 's/.*=//'
    )"

fi

# ============================================================
# 首次申请 / 检查续期
# ============================================================

echo ""
echo "================================================"
echo "运行 lego"
echo "================================================"
echo ""

info "执行证书申请/续期..."

"$LEGO_BIN" \
    --path="$LEGO_PATH" \
    run \
    --accept-tos \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    --renew-days="$RENEW_DAYS"

LEGO_EXIT_CODE=$?

if [ "$LEGO_EXIT_CODE" -ne 0 ]; then

    die "lego 执行失败，退出码：$LEGO_EXIT_CODE"
fi

# ============================================================
# 检查 lego 证书
# ============================================================

if [ ! -f "$LEGO_CERT" ]; then
    die "找不到 lego 生成的证书：$LEGO_CERT"
fi

if [ ! -f "$LEGO_KEY" ]; then
    die "找不到 lego 生成的私钥：$LEGO_KEY"
fi

# ============================================================
# 新证书指纹
# ============================================================

NEW_FINGERPRINT="$(
    openssl x509 \
        -in "$LEGO_CERT" \
        -noout \
        -fingerprint \
        -sha256 2>/dev/null |
    sed 's/.*=//'
)"

if [ -z "$NEW_FINGERPRINT" ]; then
    die "无法读取 lego 证书指纹"
fi

info "lego 证书 SHA256：$NEW_FINGERPRINT"

# ============================================================
# 验证证书
# ============================================================

info "验证证书..."

openssl x509 \
    -in "$LEGO_CERT" \
    -noout \
    -subject \
    -issuer \
    -dates || {

    die "证书格式验证失败"
}

# ============================================================
# 验证证书和私钥
# ============================================================

info "验证证书与私钥..."

CERT_PUB="$WORK_DIR/cert.pub"
KEY_PUB="$WORK_DIR/key.pub"

openssl x509 \
    -in "$LEGO_CERT" \
    -pubkey \
    -noout \
    > "$CERT_PUB" || {

    die "无法读取证书公钥"
}

openssl pkey \
    -in "$LEGO_KEY" \
    -pubout \
    > "$KEY_PUB" || {

    die "无法读取私钥公钥"
}

if ! cmp -s "$CERT_PUB" "$KEY_PUB"; then

    die "证书和私钥不匹配，拒绝安装"
fi

info "证书和私钥匹配"

# ============================================================
# 安装证书到目标位置
# ============================================================

info "安装证书到指定位置..."

install -m 0644 \
    "$LEGO_CERT" \
    "$TARGET_CERT" || {

    die "安装证书失败"
}

install -m 0600 \
    "$LEGO_KEY" \
    "$TARGET_KEY" || {

    die "安装私钥失败"
}

# ============================================================
# 最终验证目标证书
# ============================================================

openssl x509 \
    -in "$TARGET_CERT" \
    -noout \
    >/dev/null || {

    die "目标证书验证失败"
}

openssl pkey \
    -in "$TARGET_KEY" \
    -noout \
    >/dev/null || {

    die "目标私钥验证失败"
}

TARGET_FINGERPRINT="$(
    openssl x509 \
        -in "$TARGET_CERT" \
        -noout \
        -fingerprint \
        -sha256 2>/dev/null |
    sed 's/.*=//'
)"

if [ "$TARGET_FINGERPRINT" != "$NEW_FINGERPRINT" ]; then

    die "目标证书与 lego 证书指纹不一致"
fi

info "目标证书验证成功"

# ============================================================
# 自动续期配置
# ============================================================

CONFIG_DIR="/etc/lego-cert-renew"

mkdir -p "$CONFIG_DIR"

chmod 700 "$CONFIG_DIR"

# 使用配置内容生成唯一 ID
CONFIG_ID="$(
    printf '%s\n' \
        "$DOMAIN" \
        "$CERT_DIR" \
        "$CERT_NAME" \
        "$KEY_NAME" |
    sha256sum |
    cut -c1-16
)"

CONFIG_FILE="$CONFIG_DIR/$CONFIG_ID.conf"

cat > "$CONFIG_FILE" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
CERT_DIR=$(printf '%q' "$CERT_DIR")
CERT_NAME=$(printf '%q' "$CERT_NAME")
KEY_NAME=$(printf '%q' "$KEY_NAME")
LEGO_BIN=$(printf '%q' "$LEGO_BIN")
LEGO_PATH=$(printf '%q' "$LEGO_PATH")
RENEW_DAYS=$(printf '%q' "$RENEW_DAYS")
EOF

chmod 600 "$CONFIG_FILE"

SERVICE_NAME="lego-cert-renew-$CONFIG_ID"

SERVICE_FILE="$SYSTEMD_DIR/$SERVICE_NAME.service"
TIMER_FILE="$SYSTEMD_DIR/$SERVICE_NAME.timer"

# ============================================================
# 创建自动续期程序
# ============================================================

info "安装自动续期程序..."

cat > "$RENEW_BIN" <<'RENEW_EOF'
#!/bin/bash

set -u

CONFIG_FILE="${1:-}"

if [ -z "$CONFIG_FILE" ]; then
    echo "[ERROR] 没有指定配置文件"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 配置文件不存在：$CONFIG_FILE"
    exit 1
fi

. "$CONFIG_FILE"

TARGET_CERT="$CERT_DIR/$CERT_NAME"
TARGET_KEY="$CERT_DIR/$KEY_NAME"

WORK_DIR="/tmp/lego-renew-$$"

mkdir -p "$WORK_DIR"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
}

# ============================================================
# Root
# ============================================================

if [ "$(id -u)" != "0" ]; then
    error "必须使用 root"
    exit 1
fi

# ============================================================
# 检查 lego
# ============================================================

if [ ! -x "$LEGO_BIN" ]; then
    error "找不到 lego：$LEGO_BIN"
    exit 1
fi

# ============================================================
# 创建目录
# ============================================================

mkdir -p "$CERT_DIR"

# ============================================================
# 记录续期前证书指纹
# ============================================================

BEFORE_FP=""

if [ -f "$TARGET_CERT" ]; then

    BEFORE_FP="$(
        openssl x509 \
            -in "$TARGET_CERT" \
            -noout \
            -fingerprint \
            -sha256 2>/dev/null |
        sed 's/.*=//'
    )"

fi

if [ -n "$BEFORE_FP" ]; then
    log "当前目标证书 SHA256：$BEFORE_FP"
else
    log "当前没有目标证书"
fi

# ============================================================
# 运行 lego
#
# lego v5：
#   run = 申请或续期
#
# 官方不建议自动化任务使用 --no-random-sleep，
# 因此这里故意不使用该参数。
# ============================================================

log "检查证书是否需要续期..."

if ! "$LEGO_BIN" \
    --path="$LEGO_PATH" \
    run \
    --accept-tos \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    --renew-days="$RENEW_DAYS"; then

    error "lego 续期检查失败"
    exit 1
fi

# ============================================================
# lego 生成的证书
# ============================================================

LEGO_CERT="$LEGO_PATH/certificates/$DOMAIN.crt"
LEGO_KEY="$LEGO_PATH/certificates/$DOMAIN.key"

if [ ! -f "$LEGO_CERT" ]; then
    error "找不到 lego 证书：$LEGO_CERT"
    exit 1
fi

if [ ! -f "$LEGO_KEY" ]; then
    error "找不到 lego 私钥：$LEGO_KEY"
    exit 1
fi

# ============================================================
# 获取新指纹
# ============================================================

AFTER_FP="$(
    openssl x509 \
        -in "$LEGO_CERT" \
        -noout \
        -fingerprint \
        -sha256 2>/dev/null |
    sed 's/.*=//'
)"

if [ -z "$AFTER_FP" ]; then
    error "无法读取新证书指纹"
    exit 1
fi

log "lego 证书 SHA256：$AFTER_FP"

# ============================================================
# 证书没有变化
# ============================================================

if [ -n "$BEFORE_FP" ] && [ "$BEFORE_FP" = "$AFTER_FP" ]; then

    log "证书没有更新"
    log "无需复制"
    log "无需重启 VPS"

    exit 0
fi

# ============================================================
# 证书发生变化
# ============================================================

log "检测到证书发生变化"

# ============================================================
# 验证证书
# ============================================================

if ! openssl x509 \
    -in "$LEGO_CERT" \
    -noout \
    -subject \
    -issuer \
    -dates; then

    error "新证书验证失败"
    exit 1
fi

# ============================================================
# 验证证书 / 私钥
# ============================================================

CERT_PUB="$WORK_DIR/cert.pub"
KEY_PUB="$WORK_DIR/key.pub"

openssl x509 \
    -in "$LEGO_CERT" \
    -pubkey \
    -noout \
    > "$CERT_PUB" || {

    error "无法读取证书公钥"
    exit 1
}

openssl pkey \
    -in "$LEGO_KEY" \
    -pubout \
    > "$KEY_PUB" || {

    error "无法读取私钥公钥"
    exit 1
}

if ! cmp -s "$CERT_PUB" "$KEY_PUB"; then

    error "证书和私钥不匹配"
    error "拒绝覆盖正式证书"

    exit 1
fi

log "证书和私钥匹配"

# ============================================================
# 备份旧证书
# ============================================================

BACKUP_DIR=""

if [ -f "$TARGET_CERT" ] || [ -f "$TARGET_KEY" ]; then

    BACKUP_DIR="$CERT_DIR/.lego-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_DIR"

    if [ -f "$TARGET_CERT" ]; then
        cp -a "$TARGET_CERT" "$BACKUP_DIR/"
    fi

    if [ -f "$TARGET_KEY" ]; then
        cp -a "$TARGET_KEY" "$BACKUP_DIR/"
    fi

    log "旧证书备份：$BACKUP_DIR"
fi

# ============================================================
# 安装新证书
# ============================================================

install -m 0644 \
    "$LEGO_CERT" \
    "$TARGET_CERT" || {

    error "安装证书失败"
    exit 1
}

install -m 0600 \
    "$LEGO_KEY" \
    "$TARGET_KEY" || {

    error "安装私钥失败"
    exit 1
}

# ============================================================
# 最终验证
# ============================================================

if ! openssl x509 \
    -in "$TARGET_CERT" \
    -noout \
    >/dev/null; then

    error "正式证书验证失败"
    exit 1
fi

if ! openssl pkey \
    -in "$TARGET_KEY" \
    -noout \
    >/dev/null; then

    error "正式私钥验证失败"
    exit 1
fi

FINAL_FP="$(
    openssl x509 \
        -in "$TARGET_CERT" \
        -noout \
        -fingerprint \
        -sha256 2>/dev/null |
    sed 's/.*=//'
)"

if [ "$FINAL_FP" != "$AFTER_FP" ]; then

    error "正式证书指纹与 lego 证书不一致"
    exit 1
fi

log "正式证书验证成功"

# ============================================================
# 证书真正更新
# ============================================================

log "证书已成功更新"

# ============================================================
# 重启 VPS
# ============================================================

log "准备重启 VPS..."

sync

/sbin/reboot

exit 0
RENEW_EOF

chmod 0755 "$RENEW_BIN"

# ============================================================
# systemd service
# ============================================================

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Let's Encrypt Certificate Renewal - $DOMAIN
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=$RENEW_BIN $CONFIG_FILE
EOF

# ============================================================
# systemd timer
# ============================================================

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily Let's Encrypt Certificate Renewal - $DOMAIN

[Timer]
OnCalendar=*-*-* 03:35:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

# ============================================================
# systemd
# ============================================================

info "加载 systemd..."

systemctl daemon-reload || \
    die "systemd daemon-reload 失败"

systemctl enable "$SERVICE_NAME.timer" >/dev/null 2>&1 || \
    die "无法启用自动续期 timer"

systemctl restart "$SERVICE_NAME.timer" || \
    die "无法启动自动续期 timer"

# ============================================================
# 清理
# ============================================================

rm -rf "$WORK_DIR"

# ============================================================
# 完成
# ============================================================

echo ""
echo "================================================"
echo " 安装完成"
echo "================================================"
echo ""
echo "Domain:"
echo "  $DOMAIN"
echo ""
echo "Certificate:"
echo "  $TARGET_CERT"
echo ""
echo "Private Key:"
echo "  $TARGET_KEY"
echo ""
echo "lego:"
echo "  $LEGO_BIN"
echo ""
echo "lego data:"
echo "  $LEGO_PATH"
echo ""
echo "Renew:"
echo "  每天自动检查"
echo "  剩余 <= $RENEW_DAYS 天自动续期"
echo ""
echo "Timer:"
echo "  $SERVICE_NAME.timer"
echo ""
echo "Renew service:"
echo "  $SERVICE_NAME.service"
echo ""
echo "================================================"
echo ""

systemctl status "$SERVICE_NAME.timer" --no-pager || true

echo ""
info "全部完成"
