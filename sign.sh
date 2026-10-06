#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Let's Encrypt 自动签发 + 自动续签
# lego v3.7.0
#
# 用法：
#
# curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
#   | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>
#
# 参数：
#   $1 DOMAIN
#   $2 CERT_DIR
#   $3 CERT_NAME
#   $4 KEY_NAME
#
# 功能：
#   1. 首次申请 Let's Encrypt 证书
#   2. HTTP-01 challenge，TCP 80
#   3. lego 数据保存到 /var/lib/lego
#   4. 每天 systemd 自动检查
#   5. 剩余 <= 30 天自动续签
#   6. 续签成功后覆盖指定 cert/key
#   7. 验证 cert/key 是否匹配
#   8. 只有真正续签成功才自动重启 VPS
# ============================================================

set -o pipefail

# ------------------------------------------------------------
# 固定版本
# ------------------------------------------------------------

LEGO_VERSION="v3.7.0"
LEGO_BIN="/usr/local/bin/lego"
LEGO_PATH="/var/lib/lego"

CONFIG_DIR="/etc/lego-cert-renew"
CONFIG_FILE="${CONFIG_DIR}/config"

RENEW_BIN="/usr/local/sbin/lego-cert-renew"

RENEW_DAYS="30"

# ------------------------------------------------------------
# 日志
# ------------------------------------------------------------

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

# ------------------------------------------------------------
# root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "必须使用 root 运行"
fi

# ------------------------------------------------------------
# 参数
# ------------------------------------------------------------

if [[ "$#" -ne 4 ]]; then

    cat >&2 <<'EOF'

用法：

curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
  | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>

例如：

curl -fsSL https://raw.githubusercontent.com/v2net/zs/main/sign.sh \
  | bash -s <DOMAIN> <CERT_DIR> <CERT_NAME> <KEY_NAME>

参数：

  DOMAIN      域名
  CERT_DIR    证书目录
  CERT_NAME   证书文件名
  KEY_NAME    私钥文件名

EOF

    exit 1
fi

DOMAIN="$1"
CERT_DIR="$2"
CERT_NAME="$3"
KEY_NAME="$4"

TARGET_CERT="${CERT_DIR}/${CERT_NAME}"
TARGET_KEY="${CERT_DIR}/${KEY_NAME}"

log "域名：${DOMAIN}"
log "证书：${TARGET_CERT}"
log "私钥：${TARGET_KEY}"

# ------------------------------------------------------------
# 基础检查
# ------------------------------------------------------------

command -v curl >/dev/null 2>&1 \
    || die "缺少 curl"

command -v tar >/dev/null 2>&1 \
    || die "缺少 tar"

command -v openssl >/dev/null 2>&1 \
    || die "缺少 openssl"

command -v systemctl >/dev/null 2>&1 \
    || die "缺少 systemctl"

# ------------------------------------------------------------
# 安装依赖
# ------------------------------------------------------------

install_dependencies() {

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y

        apt-get install -y \
            curl \
            ca-certificates \
            openssl \
            tar \
            gzip \
            coreutils \
            iproute2 \
            systemd \
            dnsutils

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            ca-certificates \
            openssl \
            tar \
            gzip \
            coreutils \
            iproute \
            systemd \
            bind-utils

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            ca-certificates \
            openssl \
            tar \
            gzip \
            coreutils \
            iproute \
            systemd \
            bind-utils

    else

        warn "无法自动识别包管理器"
        warn "继续执行，前提是 curl/tar/openssl/systemctl 已存在"

    fi
}

install_dependencies

# ------------------------------------------------------------
# 重新检查依赖
# ------------------------------------------------------------

for cmd in curl tar openssl systemctl; do

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "缺少依赖：${cmd}"
    fi

done

# ------------------------------------------------------------
# CPU 架构
# ------------------------------------------------------------

case "$(uname -m)" in

    x86_64|amd64)
        LEGO_ARCH="amd64"
        ;;

    aarch64|arm64)
        LEGO_ARCH="arm64"
        ;;

    armv7l)
        LEGO_ARCH="arm"
        ;;

    i386|i686)
        LEGO_ARCH="386"
        ;;

    *)
        die "不支持的 CPU 架构：$(uname -m)"
        ;;

esac

log "CPU 架构：${LEGO_ARCH}"

# ------------------------------------------------------------
# lego 下载文件
#
# v3.7.0：
# lego_v3.7.0_linux_amd64.tar.gz
# lego_v3.7.0_linux_arm64.tar.gz
# lego_v3.7.0_linux_arm.tar.gz
# lego_v3.7.0_linux_386.tar.gz
# ------------------------------------------------------------

LEGO_FILE="lego_${LEGO_VERSION}_linux_${LEGO_ARCH}.tar.gz"

LEGO_URL="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/${LEGO_FILE}"

log "下载 lego ${LEGO_VERSION}"
log "${LEGO_URL}"

# ------------------------------------------------------------
# 临时目录
# ------------------------------------------------------------

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

# ------------------------------------------------------------
# 下载
# ------------------------------------------------------------

curl \
    -fL \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 15 \
    --max-time 180 \
    -o "${TMP_DIR}/${LEGO_FILE}" \
    "${LEGO_URL}"

if [[ ! -s "${TMP_DIR}/${LEGO_FILE}" ]]; then
    die "lego 下载失败"
fi

# ------------------------------------------------------------
# 解压
# ------------------------------------------------------------

log "解压 lego"

tar \
    -xzf "${TMP_DIR}/${LEGO_FILE}" \
    -C "${TMP_DIR}"

if [[ ! -f "${TMP_DIR}/lego" ]]; then
    die "压缩包中没有 lego 文件"
fi

chmod 755 "${TMP_DIR}/lego"

# ------------------------------------------------------------
# 验证下载的 lego
# ------------------------------------------------------------

DOWNLOADED_VERSION="$(
    "${TMP_DIR}/lego" --version 2>&1 || true
)"

log "下载的 lego："
echo "${DOWNLOADED_VERSION}"

if ! echo "${DOWNLOADED_VERSION}" | grep -q "3.7.0"; then
    die "下载到的 lego 不是 v3.7.0"
fi

# ------------------------------------------------------------
# 安装 lego
# ------------------------------------------------------------

log "安装 lego 到 ${LEGO_BIN}"

install \
    -m 0755 \
    "${TMP_DIR}/lego" \
    "${LEGO_BIN}"

# ------------------------------------------------------------
# 验证安装
# ------------------------------------------------------------

INSTALLED_VERSION="$(
    "${LEGO_BIN}" --version 2>&1
)"

log "已安装：${INSTALLED_VERSION}"

if ! echo "${INSTALLED_VERSION}" | grep -q "3.7.0"; then
    die "lego 安装版本不是 v3.7.0"
fi

# ------------------------------------------------------------
# 创建目录
# ------------------------------------------------------------

mkdir -p "${LEGO_PATH}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CERT_DIR}"

chmod 700 "${LEGO_PATH}"
chmod 700 "${CONFIG_DIR}"

# ------------------------------------------------------------
# 检查 TCP 80
# ------------------------------------------------------------

if command -v ss >/dev/null 2>&1; then

    if ss -lnt 2>/dev/null \
        | awk '$4 ~ /(^|:)80$/ { found=1 } END { exit !found }'
    then

        die "TCP 80 已被其他程序占用，HTTP-01 无法使用"

    fi

fi

# ------------------------------------------------------------
# DNS 检查
# ------------------------------------------------------------

log "检查 DNS：${DOMAIN}"

DNS_IP=""

if command -v getent >/dev/null 2>&1; then

    DNS_IP="$(
        getent ahostsv4 "${DOMAIN}" 2>/dev/null \
        | awk '{print $1}' \
        | sort -u \
        | head -n 1
    )"

fi

if [[ -n "${DNS_IP}" ]]; then
    log "DNS IPv4：${DNS_IP}"
else
    warn "无法通过 getent 获取 DNS IPv4"
fi

# ------------------------------------------------------------
# 获取公网 IP
# ------------------------------------------------------------

PUBLIC_IP=""

PUBLIC_IP="$(
    curl \
        -4 \
        -fsSL \
        --connect-timeout 10 \
        --max-time 20 \
        https://api.ipify.org \
        2>/dev/null \
        || true
)"

if [[ -n "${PUBLIC_IP}" ]]; then

    log "VPS 公网 IPv4：${PUBLIC_IP}"

    if [[ -n "${DNS_IP}" && "${DNS_IP}" != "${PUBLIC_IP}" ]]; then

        warn "DNS IPv4 (${DNS_IP}) 与 VPS 公网 IPv4 (${PUBLIC_IP}) 不一致"
        warn "如果证书申请失败，请检查 DNS A 记录"

    fi

else

    warn "无法获取 VPS 公网 IPv4"

fi

# ------------------------------------------------------------
# 保存配置
# ------------------------------------------------------------

cat > "${CONFIG_FILE}" <<EOF
DOMAIN=$(printf '%q' "${DOMAIN}")
CERT_DIR=$(printf '%q' "${CERT_DIR}")
CERT_NAME=$(printf '%q' "${CERT_NAME}")
KEY_NAME=$(printf '%q' "${KEY_NAME}")
EOF

chmod 600 "${CONFIG_FILE}"

# ------------------------------------------------------------
# lego 证书路径
# ------------------------------------------------------------

LEGO_CERT="${LEGO_PATH}/certificates/${DOMAIN}.crt"
LEGO_KEY="${LEGO_PATH}/certificates/${DOMAIN}.key"

# ------------------------------------------------------------
# 首次申请证书
# ------------------------------------------------------------

if [[ ! -f "${LEGO_CERT}" || ! -f "${LEGO_KEY}" ]]; then

    log "没有找到现有 lego 证书"
    log "开始申请 Let's Encrypt 证书"

    "${LEGO_BIN}" \
        --accept-tos \
        --email="admin@${DOMAIN}" \
        --domains="${DOMAIN}" \
        --path="${LEGO_PATH}" \
        --http \
        run

    if [[ ! -f "${LEGO_CERT}" ]]; then
        die "证书申请失败：${LEGO_CERT} 不存在"
    fi

    if [[ ! -f "${LEGO_KEY}" ]]; then
        die "证书申请失败：${LEGO_KEY} 不存在"
    fi

else

    log "检测到已有 lego 证书"
    log "跳过首次申请"

fi

# ------------------------------------------------------------
# 验证证书
# ------------------------------------------------------------

log "验证 lego 证书"

if ! openssl x509 \
    -in "${LEGO_CERT}" \
    -noout \
    -subject \
    -issuer \
    -dates
then

    die "lego 证书无效"

fi

# ------------------------------------------------------------
# 验证 cert/key 匹配
# ------------------------------------------------------------

get_cert_hash() {

    openssl x509 \
        -noout \
        -modulus \
        -in "$1" \
        2>/dev/null \
    | openssl sha256 \
    | awk '{print $2}'

}

get_key_hash() {

    openssl rsa \
        -noout \
        -modulus \
        -in "$1" \
        2>/dev/null \
    | openssl sha256 \
    | awk '{print $2}'

}

CERT_HASH="$(get_cert_hash "${LEGO_CERT}")"
KEY_HASH="$(get_key_hash "${LEGO_KEY}")"

if [[ -z "${CERT_HASH}" || -z "${KEY_HASH}" ]]; then
    die "无法读取证书或私钥"
fi

if [[ "${CERT_HASH}" != "${KEY_HASH}" ]]; then
    die "证书和私钥不匹配"
fi

log "证书和私钥匹配"

# ------------------------------------------------------------
# 安装首次申请的证书
# ------------------------------------------------------------

install_certificate() {

    local source_cert="$1"
    local source_key="$2"

    local tmp_cert="${TARGET_CERT}.new"
    local tmp_key="${TARGET_KEY}.new"

    mkdir -p "${CERT_DIR}"

    # 临时文件
    cp "${source_cert}" "${tmp_cert}"
    cp "${source_key}" "${tmp_key}"

    chmod 600 "${tmp_cert}"
    chmod 600 "${tmp_key}"

    # 验证临时证书
    local cert_hash
    local key_hash

    cert_hash="$(get_cert_hash "${tmp_cert}")"
    key_hash="$(get_key_hash "${tmp_key}")"

    if [[ -z "${cert_hash}" || -z "${key_hash}" ]]; then

        rm -f \
            "${tmp_cert}" \
            "${tmp_key}"

        die "临时证书验证失败"

    fi

    if [[ "${cert_hash}" != "${key_hash}" ]]; then

        rm -f \
            "${tmp_cert}" \
            "${tmp_key}"

        die "临时证书和私钥不匹配"

    fi

    # 备份旧证书
    if [[ -f "${TARGET_CERT}" ]]; then

        cp -a \
            "${TARGET_CERT}" \
            "${TARGET_CERT}.bak"

    fi

    # 备份旧私钥
    if [[ -f "${TARGET_KEY}" ]]; then

        cp -a \
            "${TARGET_KEY}" \
            "${TARGET_KEY}.bak"

    fi

    # 原子替换
    mv -f \
        "${tmp_cert}" \
        "${TARGET_CERT}"

    mv -f \
        "${tmp_key}" \
        "${TARGET_KEY}"

    chmod 600 "${TARGET_CERT}"
    chmod 600 "${TARGET_KEY}"

}

install_certificate \
    "${LEGO_CERT}" \
    "${LEGO_KEY}"

log "证书已安装到：${TARGET_CERT}"
log "私钥已安装到：${TARGET_KEY}"

# ============================================================
# 创建自动续签脚本
# ============================================================

log "创建自动续签脚本：${RENEW_BIN}"

cat > "${RENEW_BIN}" <<'RENEW_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail
set -o pipefail

# ------------------------------------------------------------
# 自动续签配置
# ------------------------------------------------------------

source "/etc/lego-cert-renew/config"

LEGO_BIN="/usr/local/bin/lego"
LEGO_PATH="/var/lib/lego"

RENEW_DAYS="30"

LEGO_CERT="${LEGO_PATH}/certificates/${DOMAIN}.crt"
LEGO_KEY="${LEGO_PATH}/certificates/${DOMAIN}.key"

TARGET_CERT="${CERT_DIR}/${CERT_NAME}"
TARGET_KEY="${CERT_DIR}/${KEY_NAME}"

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

# ------------------------------------------------------------
# root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "必须使用 root"
fi

# ------------------------------------------------------------
# 检查 lego
# ------------------------------------------------------------

if [[ ! -x "${LEGO_BIN}" ]]; then
    die "找不到 lego：${LEGO_BIN}"
fi

LEGO_VERSION_OUTPUT="$(
    "${LEGO_BIN}" --version 2>&1 || true
)"

if ! echo "${LEGO_VERSION_OUTPUT}" | grep -q "3.7.0"; then
    die "当前 lego 不是 v3.7.0：${LEGO_VERSION_OUTPUT}"
fi

# ------------------------------------------------------------
# 检查证书
# ------------------------------------------------------------

if [[ ! -f "${LEGO_CERT}" ]]; then
    die "找不到 lego 证书：${LEGO_CERT}"
fi

if [[ ! -f "${LEGO_KEY}" ]]; then
    die "找不到 lego 私钥：${LEGO_KEY}"
fi

# ------------------------------------------------------------
# 获取续签前证书 SHA256
# ------------------------------------------------------------

BEFORE_HASH="$(
    openssl x509 \
        -in "${LEGO_CERT}" \
        -noout \
        -fingerprint \
        -sha256 \
    | sed 's/^.*=//' \
    | tr -d ':'
)"

BEFORE_END_DATE="$(
    openssl x509 \
        -in "${LEGO_CERT}" \
        -noout \
        -enddate \
    | cut -d= -f2
)"

log "当前证书到期：${BEFORE_END_DATE}"
log "检查是否需要续签"

# ------------------------------------------------------------
# lego v3.7.0 续签
#
# 注意：
# v3 使用 renew --days
# ------------------------------------------------------------

if ! "${LEGO_BIN}" \
    --accept-tos \
    --email="admin@${DOMAIN}" \
    --domains="${DOMAIN}" \
    --path="${LEGO_PATH}" \
    --http \
    renew \
    --days="${RENEW_DAYS}"
then

    die "lego renew 执行失败"

fi

# ------------------------------------------------------------
# 检查续签后的证书
# ------------------------------------------------------------

if [[ ! -f "${LEGO_CERT}" ]]; then
    die "续签后找不到证书"
fi

if [[ ! -f "${LEGO_KEY}" ]]; then
    die "续签后找不到私钥"
fi

AFTER_HASH="$(
    openssl x509 \
        -in "${LEGO_CERT}" \
        -noout \
        -fingerprint \
        -sha256 \
    | sed 's/^.*=//' \
    | tr -d ':'
)"

AFTER_END_DATE="$(
    openssl x509 \
        -in "${LEGO_CERT}" \
        -noout \
        -enddate \
    | cut -d= -f2
)"

log "当前证书到期：${AFTER_END_DATE}"

# ------------------------------------------------------------
# 判断有没有真正续签
# ------------------------------------------------------------

if [[ "${BEFORE_HASH}" == "${AFTER_HASH}" ]]; then

    log "证书没有变化"
    log "当前证书不需要续签"
    log "不会覆盖目标证书"
    log "不会重启 VPS"

    exit 0

fi

log "检测到新的证书"
log "续签已经发生"

# ------------------------------------------------------------
# 验证新证书
# ------------------------------------------------------------

if ! openssl x509 \
    -in "${LEGO_CERT}" \
    -noout \
    -subject \
    -issuer \
    -dates
then

    die "新证书无效"

fi

# ------------------------------------------------------------
# 验证 cert/key
# ------------------------------------------------------------

get_cert_hash() {

    openssl x509 \
        -noout \
        -modulus \
        -in "$1" \
        2>/dev/null \
    | openssl sha256 \
    | awk '{print $2}'

}

get_key_hash() {

    openssl rsa \
        -noout \
        -modulus \
        -in "$1" \
        2>/dev/null \
    | openssl sha256 \
    | awk '{print $2}'

}

CERT_HASH="$(get_cert_hash "${LEGO_CERT}")"
KEY_HASH="$(get_key_hash "${LEGO_KEY}")"

if [[ -z "${CERT_HASH}" || -z "${KEY_HASH}" ]]; then
    die "无法验证新证书和私钥"
fi

if [[ "${CERT_HASH}" != "${KEY_HASH}" ]]; then
    die "新证书和私钥不匹配"
fi

log "新证书和新私钥匹配"

# ------------------------------------------------------------
# 创建临时文件
# ------------------------------------------------------------

TMP_CERT="${TARGET_CERT}.new"
TMP_KEY="${TARGET_KEY}.new"

mkdir -p "${CERT_DIR}"

cp "${LEGO_CERT}" "${TMP_CERT}"
cp "${LEGO_KEY}" "${TMP_KEY}"

chmod 600 "${TMP_CERT}"
chmod 600 "${TMP_KEY}"

# ------------------------------------------------------------
# 再次验证临时文件
# ------------------------------------------------------------

TMP_CERT_HASH="$(get_cert_hash "${TMP_CERT}")"
TMP_KEY_HASH="$(get_key_hash "${TMP_KEY}")"

if [[ "${TMP_CERT_HASH}" != "${TMP_KEY_HASH}" ]]; then

    rm -f \
        "${TMP_CERT}" \
        "${TMP_KEY}"

    die "临时证书和私钥不匹配"

fi

# ------------------------------------------------------------
# 备份旧证书
# ------------------------------------------------------------

if [[ -f "${TARGET_CERT}" ]]; then

    cp -a \
        "${TARGET_CERT}" \
        "${TARGET_CERT}.bak"

fi

# ------------------------------------------------------------
# 备份旧私钥
# ------------------------------------------------------------

if [[ -f "${TARGET_KEY}" ]]; then

    cp -a \
        "${TARGET_KEY}" \
        "${TARGET_KEY}.bak"

fi

# ------------------------------------------------------------
# 替换证书
# ------------------------------------------------------------

mv -f \
    "${TMP_CERT}" \
    "${TARGET_CERT}"

# ------------------------------------------------------------
# 替换私钥
# ------------------------------------------------------------

mv -f \
    "${TMP_KEY}" \
    "${TARGET_KEY}"

chmod 600 "${TARGET_CERT}"
chmod 600 "${TARGET_KEY}"

log "新证书已安装：${TARGET_CERT}"
log "新私钥已安装：${TARGET_KEY}"

# ------------------------------------------------------------
# 最终验证
# ------------------------------------------------------------

FINAL_CERT_HASH="$(get_cert_hash "${TARGET_CERT}")"
FINAL_KEY_HASH="$(get_key_hash "${TARGET_KEY}")"

if [[ -z "${FINAL_CERT_HASH}" || -z "${FINAL_KEY_HASH}" ]]; then
    die "最终证书验证失败，拒绝重启"
fi

if [[ "${FINAL_CERT_HASH}" != "${FINAL_KEY_HASH}" ]]; then
    die "最终证书和私钥不匹配，拒绝重启"
fi

log "最终证书/私钥验证通过"

# ------------------------------------------------------------
# 只有真正续签成功，才重启
# ------------------------------------------------------------

log "证书已经成功续签"
log "证书已经成功安装"
log "证书/私钥验证成功"
log "准备重启 VPS"

sleep 3

systemctl reboot
RENEW_SCRIPT

chmod 700 "${RENEW_BIN}"

# ============================================================
# systemd service
# ============================================================

CONFIG_ID="$(
    printf '%s' "${DOMAIN}|${CERT_DIR}|${CERT_NAME}|${KEY_NAME}" \
    | sha256sum \
    | awk '{print substr($1,1,16)}'
)"

SERVICE_NAME="lego-cert-renew-${CONFIG_ID}"
TIMER_NAME="lego-cert-renew-${CONFIG_ID}"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${TIMER_NAME}.timer"

# ------------------------------------------------------------
# Service
# ------------------------------------------------------------

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Let's Encrypt certificate renewal - ${DOMAIN}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${RENEW_BIN}
EOF

# ------------------------------------------------------------
# Timer
# ------------------------------------------------------------

cat > "${TIMER_FILE}" <<EOF
[Unit]
Description=Daily Let's Encrypt renewal check - ${DOMAIN}

[Timer]
OnCalendar=*-*-* 03:35:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

# ------------------------------------------------------------
# systemd reload
# ------------------------------------------------------------

systemctl daemon-reload

# ------------------------------------------------------------
# 启用 timer
# ------------------------------------------------------------

systemctl enable --now \
    "${TIMER_NAME}.timer"

# ------------------------------------------------------------
# 检查 timer
# ------------------------------------------------------------

if ! systemctl is-enabled \
    "${TIMER_NAME}.timer" \
    >/dev/null 2>&1
then

    die "systemd timer 启用失败"

fi

if ! systemctl is-active \
    "${TIMER_NAME}.timer" \
    >/dev/null 2>&1
then

    die "systemd timer 启动失败"

fi

# ============================================================
# 完成
# ============================================================

echo
echo "============================================================"
echo " Let's Encrypt 自动续签配置完成"
echo "============================================================"
echo
echo "lego："
"${LEGO_BIN}" --version
echo
echo "域名：${DOMAIN}"
echo "证书：${TARGET_CERT}"
echo "私钥：${TARGET_KEY}"
echo
echo "lego 数据目录：${LEGO_PATH}"
echo "续签脚本：${RENEW_BIN}"
echo
echo "续签条件：剩余 ${RENEW_DAYS} 天以内"
echo "HTTP-01：TCP 80"
echo "自动续签：已启用"
echo "续签成功：自动覆盖证书/私钥"
echo "续签成功：自动重启 VPS"
echo "没有续签：不会重启 VPS"
echo
echo "查看 timer："
echo "systemctl list-timers --all | grep lego-cert-renew"
echo
echo "查看 service："
echo "systemctl status ${SERVICE_NAME}.service"
echo
echo "查看日志："
echo "journalctl -u ${SERVICE_NAME}.service"
echo
echo "============================================================"
