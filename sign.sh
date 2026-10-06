#!/usr/bin/env bash
set -Eeuo pipefail

LEGO_VERSION="v5.5.2"

LEGO_BIN="/usr/local/bin/lego"
LEGO_PATH="/var/lib/lego"

CONFIG_DIR="/etc/lego-cert-renew"
CONFIG_FILE="${CONFIG_DIR}/config"
RENEW_BIN="/usr/local/sbin/lego-cert-renew"

RENEW_DAYS="30"

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

# ============================================================
# Root
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行"
fi

# ============================================================
# 参数
# ============================================================

if [[ "$#" -ne 4 ]]; then
    echo
    echo "用法："
    echo
    echo "curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \\"
    echo "  | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>"
    echo
    exit 1
fi

DOMAIN="$1"
CERT_DIR="$2"
CERT_NAME="$3"
KEY_NAME="$4"

TARGET_CERT="${CERT_DIR}/${CERT_NAME}"
TARGET_KEY="${CERT_DIR}/${KEY_NAME}"

[[ -n "$DOMAIN" ]] || die "域名不能为空"
[[ "$DOMAIN" != */* ]] || die "域名不正确：$DOMAIN"

[[ "$CERT_DIR" == /* ]] \
    || die "证书目录必须是绝对路径"

[[ "$CERT_NAME" != */* ]] \
    || die "证书文件名不能包含 /"

[[ "$KEY_NAME" != */* ]] \
    || die "私钥文件名不能包含 /"

command -v systemctl >/dev/null 2>&1 \
    || die "系统没有 systemd"

# ============================================================
# 系统依赖
# ============================================================

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
    die "不支持的 Linux 发行版"
fi

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
    i386|i686|386)
        LEGO_ARCH="386"
        ;;
    *)
        die "不支持的 CPU 架构：$SYSTEM_ARCH"
        ;;
esac

log "系统架构：$SYSTEM_ARCH"
log "lego 架构：$LEGO_ARCH"

# ============================================================
# TCP 80
# ============================================================

log "检查 TCP 80..."

if command -v ss >/dev/null 2>&1; then

    if ss -ltnH '( sport = :80 )' 2>/dev/null | grep -q .; then

        echo
        warn "TCP 80 已经被其他程序占用："
        ss -ltnp '( sport = :80 )' 2>/dev/null || true
        echo

        die "HTTP-01 需要 TCP 80 空闲"
    fi
fi

# ============================================================
# DNS
# ============================================================

DNS_IP=""

if command -v getent >/dev/null 2>&1; then
    DNS_IP="$(
        getent ahostsv4 "$DOMAIN" 2>/dev/null |
        awk 'NR==1 {print $1}'
    )"
fi

if [[ -n "$DNS_IP" ]]; then
    log "DNS IPv4：$DNS_IP"
else
    warn "无法解析 $DOMAIN"
fi

# ============================================================
# 公网 IP
# ============================================================

PUBLIC_IP=""

if PUBLIC_IP="$(
    curl -4fsSL \
        --connect-timeout 10 \
        --max-time 15 \
        https://api.ipify.org \
        2>/dev/null
)"; then

    log "VPS 公网 IPv4：$PUBLIC_IP"

    if [[ -n "$DNS_IP" && "$DNS_IP" != "$PUBLIC_IP" ]]; then
        warn "DNS IPv4 与 VPS 公网 IPv4 不一致"
        warn "DNS：$DNS_IP"
        warn "VPS：$PUBLIC_IP"
    fi
else
    warn "无法获取 VPS 公网 IP"
fi

# ============================================================
# 创建目录
# ============================================================

mkdir -p "$LEGO_PATH"
mkdir -p "$CONFIG_DIR"
mkdir -p "$CERT_DIR"

chmod 700 "$LEGO_PATH"
chmod 700 "$CONFIG_DIR"

# ============================================================
# 下载 lego
# ============================================================

TMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TMP_DIR"' EXIT

LEGO_FILE="lego_${LEGO_VERSION}_linux_${LEGO_ARCH}.tar.gz"
CHECKSUM_FILE="lego_${LEGO_VERSION#v}_checksums.txt"

LEGO_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${LEGO_FILE}"
CHECKSUM_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${CHECKSUM_FILE}"

log "下载 lego ${LEGO_VERSION}..."
log "$LEGO_URL"

curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 180 \
    -o "$TMP_DIR/$LEGO_FILE" \
    "$LEGO_URL" \
    || die "lego 下载失败"

log "下载 checksum..."

curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 180 \
    -o "$TMP_DIR/$CHECKSUM_FILE" \
    "$CHECKSUM_URL" \
    || die "checksum 下载失败"

# ============================================================
# SHA256
# ============================================================

log "验证 lego SHA256..."

EXPECTED_HASH="$(
    awk -v file="$LEGO_FILE" '
        $2 == file || $2 == "*" file {
            print $1
            exit
        }
    ' "$TMP_DIR/$CHECKSUM_FILE"
)"

[[ -n "$EXPECTED_HASH" ]] \
    || die "checksum 中找不到 $LEGO_FILE"

ACTUAL_HASH="$(
    sha256sum "$TMP_DIR/$LEGO_FILE" |
    awk '{print $1}'
)"

if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
    error "SHA256 校验失败"
    error "Expected: $EXPECTED_HASH"
    error "Actual:   $ACTUAL_HASH"
    exit 1
fi

log "SHA256 校验通过"

# ============================================================
# 安装 lego
# ============================================================

log "安装 lego..."

tar -xzf "$TMP_DIR/$LEGO_FILE" -C "$TMP_DIR"

[[ -f "$TMP_DIR/lego" ]] \
    || die "解压后找不到 lego"

install -m 0755 \
    "$TMP_DIR/lego" \
    "$LEGO_BIN"

log "lego 版本："

"$LEGO_BIN" --version

# ============================================================
# 使用 LEGO_PATH
#
# 不使用 --path
# 不执行 migrate
# ============================================================

export LEGO_PATH="$LEGO_PATH"

log "LEGO_PATH=$LEGO_PATH"

# ============================================================
# 保存配置
# ============================================================

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

# ============================================================
# 备份旧证书
# ============================================================

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

    log "旧证书备份：$BACKUP_DIR"
fi

# ============================================================
# 申请证书
#
# 注意：
# lego v5：
#
#   lego run ...
#
# LEGO_PATH 通过环境变量提供
# ============================================================

log "开始申请 Let's Encrypt 证书..."

export LEGO_PATH="$LEGO_PATH"

"$LEGO_BIN" \
    run \
    --accept-tos \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    --renew-days="$RENEW_DAYS"

# ============================================================
# 检查生成的证书
# ============================================================

LEGO_CERT="$LEGO_PATH/certificates/${DOMAIN}.crt"
LEGO_KEY="$LEGO_PATH/certificates/${DOMAIN}.key"

[[ -f "$LEGO_CERT" ]] \
    || die "找不到证书：$LEGO_CERT"

[[ -f "$LEGO_KEY" ]] \
    || die "找不到私钥：$LEGO_KEY"

# ============================================================
# 验证证书
# ============================================================

log "验证证书..."

openssl x509 \
    -in "$LEGO_CERT" \
    -noout \
    -subject \
    -issuer \
    -dates \
    || die "证书验证失败"

# ============================================================
# 验证证书和私钥
# ============================================================

log "验证证书和私钥..."

CERT_PUB="$(mktemp)"
KEY_PUB="$(mktemp)"

openssl x509 \
    -in "$LEGO_CERT" \
    -pubkey \
    -noout > "$CERT_PUB"

openssl pkey \
    -in "$LEGO_KEY" \
    -pubout > "$KEY_PUB"

if ! cmp -s "$CERT_PUB" "$KEY_PUB"; then

    rm -f "$CERT_PUB" "$KEY_PUB"

    die "证书和私钥不匹配"
fi

rm -f "$CERT_PUB" "$KEY_PUB"

log "证书和私钥匹配"

# ============================================================
# 安装证书
# ============================================================

log "安装证书：$TARGET_CERT"
log "安装私钥：$TARGET_KEY"

TMP_CERT="${TARGET_CERT}.lego.tmp"
TMP_KEY="${TARGET_KEY}.lego.tmp"

cp "$LEGO_CERT" "$TMP_CERT"
cp "$LEGO_KEY" "$TMP_KEY"

chmod 0644 "$TMP_CERT"
chmod 0600 "$TMP_KEY"

mv -f "$TMP_CERT" "$TARGET_CERT"
mv -f "$TMP_KEY" "$TARGET_KEY"

# ============================================================
# 创建自动续期脚本
# ============================================================

log "创建自动续期脚本..."

cat > "$RENEW_BIN" <<'RENEW_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="/etc/lego-cert-renew/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] 配置文件不存在：$CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

log() {
    echo "[RENEW] $*"
}

error() {
    echo "[RENEW][ERROR] $*" >&2
}

export LEGO_PATH="$LEGO_PATH"

# ============================================================
# 检查 TCP 80
# ============================================================

if command -v ss >/dev/null 2>&1; then

    if ss -ltnH '( sport = :80 )' 2>/dev/null | grep -q .; then

        error "TCP 80 已被其他程序占用"

        ss -ltnp '( sport = :80 )' 2>/dev/null || true

        exit 1
    fi
fi

# ============================================================
# 续期前指纹
# ============================================================

BEFORE=""

if [[ -f "$LEGO_PATH/certificates/${DOMAIN}.crt" ]]; then

    BEFORE="$(
        openssl x509 \
            -in "$LEGO_PATH/certificates/${DOMAIN}.crt" \
            -noout \
            -fingerprint \
            -sha256 \
            2>/dev/null || true
    )"
fi

# ============================================================
# 运行 lego
# ============================================================

log "检查证书是否需要续期..."

export LEGO_PATH="$LEGO_PATH"

"$LEGO_BIN" \
    run \
    --accept-tos \
    --email="admin@$DOMAIN" \
    --domains="$DOMAIN" \
    --http \
    --renew-days="$RENEW_DAYS"

# ============================================================
# 续期后指纹
# ============================================================

AFTER=""

if [[ -f "$LEGO_PATH/certificates/${DOMAIN}.crt" ]]; then

    AFTER="$(
        openssl x509 \
            -in "$LEGO_PATH/certificates/${DOMAIN}.crt" \
            -noout \
            -fingerprint \
            -sha256 \
            2>/dev/null || true
    )"
fi

# ============================================================
# 没有续期
# ============================================================

if [[ -n "$BEFORE" && "$BEFORE" == "$AFTER" ]]; then

    log "证书没有变化"
    log "无需重启 VPS"

    exit 0
fi

# ============================================================
# 新证书
# ============================================================

LEGO_CERT="$LEGO_PATH/certificates/${DOMAIN}.crt"
LEGO_KEY="$LEGO_PATH/certificates/${DOMAIN}.key"

[[ -f "$LEGO_CERT" ]] \
    || {
        error "找不到新证书"
        exit 1
    }

[[ -f "$LEGO_KEY" ]] \
    || {
        error "找不到新私钥"
        exit 1
    }

# ============================================================
# 验证新证书
# ============================================================

if ! openssl x509 \
    -in "$LEGO_CERT" \
    -noout \
    -checkend 0 >/dev/null; then

    error "新证书无效"

    exit 1
fi

# ============================================================
# 验证证书和私钥
# ============================================================

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

# ============================================================
# 备份旧证书
# ============================================================

BACKUP_DIR="${CERT_DIR}/.lego-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [[ -f "$TARGET_CERT" ]]; then
    cp -a "$TARGET_CERT" "$BACKUP_DIR/"
fi

if [[ -f "$TARGET_KEY" ]]; then
    cp -a "$TARGET_KEY" "$BACKUP_DIR/"
fi

# ============================================================
# 安装新证书
# ============================================================

TMP_CERT="${TARGET_CERT}.lego.tmp"
TMP_KEY="${TARGET_KEY}.lego.tmp"

cp "$LEGO_CERT" "$TMP_CERT"
cp "$LEGO_KEY" "$TMP_KEY"

chmod 0644 "$TMP_CERT"
chmod 0600 "$TMP_KEY"

mv -f "$TMP_CERT" "$TARGET_CERT"
mv -f "$TMP_KEY" "$TARGET_KEY"

log "新证书已安装"
log "新证书：$TARGET_CERT"
log "新私钥：$TARGET_KEY"

# ============================================================
# 最终检查
# ============================================================

if ! openssl x509 \
    -in "$TARGET_CERT" \
    -noout \
    -checkend 0 >/dev/null; then

    error "安装后的证书验证失败"

    exit 1
fi

# ============================================================
# 真正续期后才重启
# ============================================================

log "证书已经实际更新"

log "准备重启 VPS..."

systemctl reboot
RENEW_SCRIPT

chmod 0755 "$RENEW_BIN"

# ============================================================
# systemd
# ============================================================

CONFIG_ID="$(
    printf '%s' \
        "${DOMAIN}|${CERT_DIR}|${CERT_NAME}|${KEY_NAME}" |
    sha256sum |
    awk '{print substr($1,1,16)}'
)"

SERVICE_NAME="lego-cert-renew-${CONFIG_ID}"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

# ============================================================
# Service
# ============================================================

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Let's Encrypt renewal for ${DOMAIN}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RENEW_BIN}
EOF

# ============================================================
# Timer
# ============================================================

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

# ============================================================
# 启用 Timer
# ============================================================

log "启用自动续期..."

systemctl daemon-reload

systemctl enable --now "${SERVICE_NAME}.timer"

# ============================================================
# 最终状态
# ============================================================

echo
echo "============================================================"
echo " Let's Encrypt 配置完成"
echo "============================================================"
echo
echo "域名：        $DOMAIN"
echo "证书：        $TARGET_CERT"
echo "私钥：        $TARGET_KEY"
echo
echo "lego：        $LEGO_BIN"
echo "lego 数据：   $LEGO_PATH"
echo
echo "续期脚本：    $RENEW_BIN"
echo "续期阈值：    ${RENEW_DAYS} 天"
echo
echo "自动续期：    已启用"
echo "自动重启：    仅证书实际更新后执行"
echo
echo "查看 Timer："
echo "systemctl list-timers --all | grep lego-cert-renew"
echo
echo "查看日志："
echo "journalctl -u ${SERVICE_NAME}.service"
echo
echo "============================================================"
