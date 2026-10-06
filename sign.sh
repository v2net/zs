#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Let's Encrypt 自动签发 + 自动续期 + 续期后自动重启 VPS
#
# 用法：
# curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
#   | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>
#
# 参数：
#   $1 = 域名
#   $2 = 证书目录
#   $3 = 证书文件名
#   $4 = 私钥文件名
#
# 示例（请替换成你自己的参数）：
#   curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
#     | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>
#
# 要求：
#   - Linux
#   - TCP 80 必须能够从公网访问
#   - 使用 HTTP-01 验证
#   - systemd 用于自动续期
# ============================================================

LEGO_VERSION="v5.5.2"

LEGO_BIN="/usr/local/bin/lego"
LEGO_PATH="/var/lib/lego"

RENEW_BIN="/usr/local/sbin/lego-cert-renew"
CONFIG_DIR="/etc/lego-cert-renew"

RENEW_DAYS="30"

# ------------------------------------------------------------
# 基础函数
# ------------------------------------------------------------

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
}

die() {
    error "$*"
    exit 1
}

cleanup() {
    rm -rf "${TMP_DIR:-}"
}

trap cleanup EXIT

# ------------------------------------------------------------
# Root 检查
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行此脚本"
fi

# ------------------------------------------------------------
# 参数检查
# ------------------------------------------------------------

if [[ "$#" -ne 4 ]]; then
    cat >&2 <<'EOF'

用法：

  curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
    | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>

参数：

  DOMAIN     域名
  CERT_DIR   证书目录
  CERT_NAME  证书文件名
  KEY_NAME   私钥文件名

例如：

  curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
    | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>

EOF
    exit 1
fi

DOMAIN="$1"
CERT_DIR="$2"
CERT_NAME="$3"
KEY_NAME="$4"

TARGET_CERT="${CERT_DIR}/${CERT_NAME}"
TARGET_KEY="${CERT_DIR}/${KEY_NAME}"

# ------------------------------------------------------------
# 参数安全检查
# ------------------------------------------------------------

[[ "$DOMAIN" != */* ]] || die "域名参数不正确：$DOMAIN"

[[ "$CERT_DIR" = /* ]] || die "证书目录必须使用绝对路径：$CERT_DIR"

[[ -n "$CERT_NAME" ]] || die "证书文件名不能为空"
[[ -n "$KEY_NAME" ]] || die "私钥文件名不能为空"

[[ "$CERT_NAME" != */* ]] || die "证书文件名不能包含 /"
[[ "$KEY_NAME" != */* ]] || die "私钥文件名不能包含 /"

# ------------------------------------------------------------
# 检查系统
# ------------------------------------------------------------

log "检查系统依赖..."

if command -v apt-get >/dev/null 2>&1; then

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y >/dev/null 2>&1 || true

    apt-get install -y \
        curl \
        tar \
        gzip \
        openssl \
        ca-certificates \
        coreutils \
        iproute2 \
        >/dev/null

elif command -v dnf >/dev/null 2>&1; then

    dnf install -y \
        curl \
        tar \
        gzip \
        openssl \
        ca-certificates \
        coreutils \
        iproute \
        >/dev/null

elif command -v yum >/dev/null 2>&1; then

    yum install -y \
        curl \
        tar \
        gzip \
        openssl \
        ca-certificates \
        coreutils \
        iproute \
        >/dev/null

else
    die "不支持的 Linux 发行版：找不到 apt-get / dnf / yum"
fi

# ------------------------------------------------------------
# 检查 systemd
# ------------------------------------------------------------

command -v systemctl >/dev/null 2>&1 \
    || die "系统没有 systemd，无法配置自动续期"

# ------------------------------------------------------------
# 检测 CPU 架构
# ------------------------------------------------------------

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

    i386|i686|386)
        LEGO_ARCH="386"
        ;;

    *)
        die "不支持的 CPU 架构：$SYSTEM_ARCH"
        ;;

esac

log "系统架构：$SYSTEM_ARCH"
log "lego 架构：$LEGO_ARCH"

# ------------------------------------------------------------
# 检查 80 端口
# ------------------------------------------------------------

log "检查 TCP 80..."

if command -v ss >/dev/null 2>&1; then

    if ss -ltnH '( sport = :80 )' 2>/dev/null | grep -q .; then
        warn "TCP 80 当前已经被其他程序监听。"
        warn "lego 使用 HTTP-01 验证时需要使用 TCP 80。"
        warn "请停止占用 80 端口的程序后重新运行。"
        ss -ltnp '( sport = :80 )' 2>/dev/null || true
        exit 1
    fi

fi

# ------------------------------------------------------------
# DNS 检查
# ------------------------------------------------------------

log "检查 DNS..."

if command -v getent >/dev/null 2>&1; then

    DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}')"

    if [[ -n "$DNS_IP" ]]; then
        log "DNS IPv4：$DNS_IP"
    else
        warn "无法通过本机 DNS 解析 $DOMAIN"
    fi

fi

# ------------------------------------------------------------
# 获取 VPS 公网 IPv4
# ------------------------------------------------------------

PUBLIC_IP=""

if PUBLIC_IP="$(curl -4fsSL --max-time 10 https://api.ipify.org 2>/dev/null)"; then
    log "VPS 公网 IPv4：$PUBLIC_IP"

    if [[ -n "${DNS_IP:-}" && "$DNS_IP" != "$PUBLIC_IP" ]]; then
        warn "DNS IPv4 ($DNS_IP) 与 VPS 公网 IPv4 ($PUBLIC_IP) 不一致。"
        warn "请确认域名已经解析到当前 VPS。"
    fi
else
    warn "无法获取 VPS 公网 IPv4，跳过 IP 对比。"
fi

# ------------------------------------------------------------
# 创建目录
# ------------------------------------------------------------

mkdir -p "$LEGO_PATH"
mkdir -p "$CONFIG_DIR"
mkdir -p "$CERT_DIR"

chmod 700 "$LEGO_PATH"
chmod 700 "$CONFIG_DIR"

# ------------------------------------------------------------
# 下载 lego
# ------------------------------------------------------------

TMP_DIR="$(mktemp -d)"

LEGO_FILE="lego_${LEGO_VERSION}_linux_${LEGO_ARCH}.tar.gz"
CHECKSUM_FILE="lego_${LEGO_VERSION#v}_checksums.txt"

LEGO_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${LEGO_FILE}"
CHECKSUM_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${CHECKSUM_FILE}"

log "下载 lego ${LEGO_VERSION}..."

log "下载地址："
log "$LEGO_URL"

if ! curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$TMP_DIR/$LEGO_FILE" \
    "$LEGO_URL"; then

    die "lego 下载失败：$LEGO_URL"
fi

log "下载 checksum..."

if ! curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$TMP_DIR/$CHECKSUM_FILE" \
    "$CHECKSUM_URL"; then

    die "checksum 下载失败：$CHECKSUM_URL"
fi

# ------------------------------------------------------------
# SHA256 验证
# ------------------------------------------------------------

log "验证 lego SHA256..."

EXPECTED_HASH="$(
    awk -v file="$LEGO_FILE" '
        $2 == file || $2 == "*" file {
            print $1
            exit
        }
    ' "$TMP_DIR/$CHECKSUM_FILE"
)"

if [[ -z "$EXPECTED_HASH" ]]; then
    die "无法从 checksum 文件中找到 $LEGO_FILE"
fi

ACTUAL_HASH="$(
    sha256sum "$TMP_DIR/$LEGO_FILE" | awk '{print $1}'
)"

if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
    die "lego SHA256 校验失败"
fi

log "SHA256 校验通过"

# ------------------------------------------------------------
# 安装 lego
# ------------------------------------------------------------

log "安装 lego..."

tar -xzf "$TMP_DIR/$LEGO_FILE" -C "$TMP_DIR"

if [[ ! -f "$TMP_DIR/lego" ]]; then
    die "解压后没有找到 lego 可执行文件"
fi

install -m 0755 "$TMP_DIR/lego" "$LEGO_BIN"

log "lego 安装完成：$LEGO_BIN"

# ------------------------------------------------------------
# 写入配置
# ------------------------------------------------------------

CONFIG_FILE="$CONFIG_DIR/config"

cat > "$CONFIG_FILE" <<EOF
DOMAIN='$DOMAIN'
CERT_DIR='$CERT_DIR'
CERT_NAME='$CERT_NAME'
KEY_NAME='$KEY_NAME'
TARGET_CERT='$TARGET_CERT'
TARGET_KEY='$TARGET_KEY'
LEGO_BIN='$LEGO_BIN'
LEGO_PATH='$LEGO_PATH'
RENEW_DAYS='$RENEW_DAYS'
EOF

chmod 600 "$CONFIG_FILE"

# ------------------------------------------------------------
# 备份已有证书
# ------------------------------------------------------------

BACKUP_DIR=""

if [[ -f "$TARGET_CERT" || -f "$TARGET_KEY" ]]; then

    BACKUP_DIR="${CERT_DIR}/.lego-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    if [[ -f "$TARGET_CERT" ]]; then
        cp -a "$TARGET_CERT" "$BACKUP_DIR/"
    fi

    if [[ -f "$TARGET_KEY" ]]; then
        cp -a "$TARGET_KEY" "$BACKUP_DIR/"
    fi

    log "旧证书已备份到：$BACKUP_DIR"

fi

# ------------------------------------------------------------
# 申请 / 更新证书
# ------------------------------------------------------------

log "开始申请 Let's Encrypt 证书..."

"$LEGO_BIN" \
    --path="$LEGO_PATH" \
    --accept-tos \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    --renew-days="$RENEW_DAYS" \
    run

# ------------------------------------------------------------
# 查找 lego 生成的证书
# ------------------------------------------------------------

LEGO_CERT="$LEGO_PATH/certificates/${DOMAIN}.crt"
LEGO_KEY="$LEGO_PATH/certificates/${DOMAIN}.key"

if [[ ! -f "$LEGO_CERT" ]]; then
    die "没有找到 lego 生成的证书：$LEGO_CERT"
fi

if [[ ! -f "$LEGO_KEY" ]]; then
    die "没有找到 lego 生成的私钥：$LEGO_KEY"
fi

# ------------------------------------------------------------
# 验证证书
# ------------------------------------------------------------

log "验证证书..."

if ! openssl x509 \
    -in "$LEGO_CERT" \
    -noout \
    -subject \
    -issuer \
    -dates; then

    die "证书验证失败"
fi

# ------------------------------------------------------------
# 验证证书和私钥是否匹配
# ------------------------------------------------------------

log "验证证书与私钥..."

CERT_PUB="$(mktemp)"
KEY_PUB="$(mktemp)"

trap 'rm -f "$CERT_PUB" "$KEY_PUB"; cleanup' EXIT

openssl x509 \
    -in "$LEGO_CERT" \
    -pubkey \
    -noout > "$CERT_PUB"

openssl pkey \
    -in "$LEGO_KEY" \
    -pubout > "$KEY_PUB"

if ! cmp -s "$CERT_PUB" "$KEY_PUB"; then
    die "证书与私钥不匹配"
fi

rm -f "$CERT_PUB" "$KEY_PUB"

log "证书与私钥匹配"

# ------------------------------------------------------------
# 安装证书
# ------------------------------------------------------------

log "安装证书到：$TARGET_CERT"
log "安装私钥到：$TARGET_KEY"

TMP_CERT="${TARGET_CERT}.lego.tmp"
TMP_KEY="${TARGET_KEY}.lego.tmp"

cp "$LEGO_CERT" "$TMP_CERT"
cp "$LEGO_KEY" "$TMP_KEY"

chmod 0644 "$TMP_CERT"
chmod 0600 "$TMP_KEY"

mv -f "$TMP_CERT" "$TARGET_CERT"
mv -f "$TMP_KEY" "$TARGET_KEY"

# ------------------------------------------------------------
# 写入自动续期脚本
# ------------------------------------------------------------

log "配置自动续期..."

cat > "$RENEW_BIN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/lego-cert-renew/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] 配置文件不存在：$CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

log() {
    echo "[RENEW] $*"
}

error() {
    echo "[RENEW][ERROR] $*" >&2
}

# ------------------------------------------------------------
# 检查 TCP 80
# ------------------------------------------------------------

if command -v ss >/dev/null 2>&1; then
    if ss -ltnH '( sport = :80 )' 2>/dev/null | grep -q .; then
        error "TCP 80 已被其他程序占用，HTTP-01 续期无法进行。"
        ss -ltnp '( sport = :80 )' 2>/dev/null || true
        exit 1
    fi
fi

# ------------------------------------------------------------
# 记录续期前证书指纹
# ------------------------------------------------------------

BEFORE=""

if [[ -f "$LEGO_PATH/certificates/${DOMAIN}.crt" ]]; then
    BEFORE="$(
        openssl x509 \
            -in "$LEGO_PATH/certificates/${DOMAIN}.crt" \
            -noout \
            -fingerprint \
            -sha256 2>/dev/null || true
    )"
fi

log "检查证书是否需要续期..."

"$LEGO_BIN" \
    --path="$LEGO_PATH" \
    --accept-tos \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    --renew-days="$RENEW_DAYS" \
    run

# ------------------------------------------------------------
# 记录续期后证书指纹
# ------------------------------------------------------------

AFTER=""

if [[ -f "$LEGO_PATH/certificates/${DOMAIN}.crt" ]]; then
    AFTER="$(
        openssl x509 \
            -in "$LEGO_PATH/certificates/${DOMAIN}.crt" \
            -noout \
            -fingerprint \
            -sha256 2>/dev/null || true
    )"
fi

# ------------------------------------------------------------
# 没有续期
# ------------------------------------------------------------

if [[ -n "$BEFORE" && "$BEFORE" == "$AFTER" ]]; then
    log "证书没有发生变化，不需要重启 VPS。"
    exit 0
fi

# ------------------------------------------------------------
# 找证书
# ------------------------------------------------------------

LEGO_CERT="$LEGO_PATH/certificates/${DOMAIN}.crt"
LEGO_KEY="$LEGO_PATH/certificates/${DOMAIN}.key"

if [[ ! -f "$LEGO_CERT" ]]; then
    error "找不到新证书：$LEGO_CERT"
    exit 1
fi

if [[ ! -f "$LEGO_KEY" ]]; then
    error "找不到新私钥：$LEGO_KEY"
    exit 1
fi

# ------------------------------------------------------------
# 验证证书
# ------------------------------------------------------------

if ! openssl x509 \
    -in "$LEGO_CERT" \
    -noout \
    -checkend 0 >/dev/null; then

    error "新证书已经过期或无效"
    exit 1
fi

# ------------------------------------------------------------
# 验证证书 / 私钥
# ------------------------------------------------------------

CERT_PUB="$(mktemp)"
KEY_PUB="$(mktemp)"

trap 'rm -f "$CERT_PUB" "$KEY_PUB"' EXIT

openssl x509 \
    -in "$LEGO_CERT" \
    -pubkey \
    -noout > "$CERT_PUB"

openssl pkey \
    -in "$LEGO_KEY" \
    -pubout > "$KEY_PUB"

if ! cmp -s "$CERT_PUB" "$KEY_PUB"; then
    error "新证书和私钥不匹配"
    exit 1
fi

rm -f "$CERT_PUB" "$KEY_PUB"

# ------------------------------------------------------------
# 备份当前证书
# ------------------------------------------------------------

BACKUP_DIR="${CERT_DIR}/.lego-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [[ -f "$TARGET_CERT" ]]; then
    cp -a "$TARGET_CERT" "$BACKUP_DIR/"
fi

if [[ -f "$TARGET_KEY" ]]; then
    cp -a "$TARGET_KEY" "$BACKUP_DIR/"
fi

# ------------------------------------------------------------
# 安装新证书
# ------------------------------------------------------------

TMP_CERT="${TARGET_CERT}.lego.tmp"
TMP_KEY="${TARGET_KEY}.lego.tmp"

cp "$LEGO_CERT" "$TMP_CERT"
cp "$LEGO_KEY" "$TMP_KEY"

chmod 0644 "$TMP_CERT"
chmod 0600 "$TMP_KEY"

mv -f "$TMP_CERT" "$TARGET_CERT"
mv -f "$TMP_KEY" "$TARGET_KEY"

log "新证书已安装：$TARGET_CERT"
log "新私钥已安装：$TARGET_KEY"

# ------------------------------------------------------------
# 最终验证
# ------------------------------------------------------------

if ! openssl x509 \
    -in "$TARGET_CERT" \
    -noout \
    -checkend 0 >/dev/null; then

    error "安装后的证书验证失败"
    exit 1
fi

# ------------------------------------------------------------
# 重启 VPS
# ------------------------------------------------------------

log "证书已经更新成功。"
log "准备重启 VPS..."

systemctl reboot
EOF

chmod 0755 "$RENEW_BIN"

# ------------------------------------------------------------
# systemd service
# ------------------------------------------------------------

CONFIG_ID="$(
    printf '%s' \
        "${DOMAIN}|${CERT_DIR}|${CERT_NAME}|${KEY_NAME}" \
        | sha256sum \
        | awk '{print substr($1,1,16)}'
)"

SERVICE_NAME="lego-cert-renew-${CONFIG_ID}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Let's Encrypt certificate renewal for ${DOMAIN}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RENEW_BIN}
EOF

# ------------------------------------------------------------
# systemd timer
# ------------------------------------------------------------

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily Let's Encrypt renewal check for ${DOMAIN}

[Timer]
OnCalendar=*-*-* 03:35:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

# ------------------------------------------------------------
# 启用 timer
# ------------------------------------------------------------

systemctl daemon-reload

systemctl enable --now "${SERVICE_NAME}.timer"

# ------------------------------------------------------------
# 显示结果
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Let's Encrypt 配置完成"
echo "============================================================"
echo
echo "域名：        $DOMAIN"
echo "证书：        $TARGET_CERT"
echo "私钥：        $TARGET_KEY"
echo "lego：        $LEGO_BIN"
echo "lego 数据：   $LEGO_PATH"
echo "续期脚本：    $RENEW_BIN"
echo "续期阈值：    ${RENEW_DAYS} 天"
echo "systemd：     ${SERVICE_NAME}.timer"
echo
echo "自动续期：    已启用"
echo "自动重启：    仅证书实际更新后执行"
echo
echo "查看定时器："
echo "  systemctl list-timers | grep lego-cert-renew"
echo
echo "手动测试续期："
echo "  systemctl start ${SERVICE_NAME}.service"
echo
echo "查看日志："
echo "  journalctl -u ${SERVICE_NAME}.service"
echo
echo "============================================================"
