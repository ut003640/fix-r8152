#!/bin/bash
#
# fix-r8152 一键安装脚本
# 本脚本已内嵌所有需要安装的文件内容，直接将内容写入目标路径，
# 不生成临时文件。单独发送本脚本即可完成安装，
# 效果等价于安装本项目构建出的 debian 包。
#
# 安装内容:
#   修复脚本    /etc/network/shell/10-fix-r8152
#   守护脚本    /etc/network/bin/fix-r8152-watch
#   定制配置    /etc/dsg/configs/overrides/org.deepin.dde.network/org.deepin.dde.network/org.deepin.dde.network.override.json
#   systemd 服务 /etc/systemd/system/fix-r8152.service  (并启用、启动服务)
#
# 使用方法: sudo ./install.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# root 检查
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[!] 此脚本需要 root 权限运行"
    echo "[!] 请使用: sudo ${BASH_SOURCE[0]}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 安装依赖
# ---------------------------------------------------------------------------
echo "[*] 检查依赖包..."
MISSING_DEPS=()
for pkg in network-manager ethtool iproute2 dbus; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
        MISSING_DEPS+=("${pkg}")
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo "[*] 安装缺失依赖: ${MISSING_DEPS[*]}"
    apt-get install -y "${MISSING_DEPS[@]}" || {
        echo "[!] 依赖安装失败"
        exit 1
    }
else
    echo "[*] 依赖已全部安装"
fi

# ---------------------------------------------------------------------------
# 安装路径固定到 /etc/network
# ---------------------------------------------------------------------------
INSTALL_BASE="/etc/network"

SHELL_DIR="${INSTALL_BASE}/shell"
BIN_DIR="${INSTALL_BASE}/bin"
DISPATCHER_PATH="${SHELL_DIR}/10-fix-r8152"
WATCH_PATH="${BIN_DIR}/fix-r8152-watch"
OVERRIDE_PATH="/etc/dsg/configs/overrides/org.deepin.dde.network/org.deepin.dde.network/org.deepin.dde.network.override.json"
SERVICE_PATH="/etc/systemd/system/fix-r8152.service"

# ---------------------------------------------------------------------------
# 写入文件前检查目标目录是否存在，不存在则先创建，再写入内容
# ---------------------------------------------------------------------------

if [[ ! -d ${DISPATCHER_PATH%/*} ]]; then
    echo "[*] 目录不存在，创建目录: ${DISPATCHER_PATH%/*}"
    mkdir -p ${DISPATCHER_PATH%/*} || { echo "[!] 创建目录失败: ${DISPATCHER_PATH%/*}"; exit 1; }
fi
echo "[*] 写入 ${DISPATCHER_PATH}"
cat > ${DISPATCHER_PATH} <<'__10_FIX_R8152_EMBEDDED_EOF__'
#!/bin/bash
#
# NetworkManager dispatcher 脚本
# 查找 DeviceType=1 (Ethernet) 且 Driver=r8152 的 NetworkManager 设备，
# 对其下所有连接设置 autoconnect-retries 和 autoconnect-reset-retries。
#
# dispatcher 调用方式（自动传入两个参数）:
#   $1 = 接口名 (如 eth0)
#   $2 = 动作   (如 up, down, dhcp4-change)
#
# 手动测试方式:
#   ./fix_r8152_autoconnect.sh [retries值]
#   当不传 $1 $2 时，跳过 dispatcher 事件过滤，直接扫描所有设备。

set -uo pipefail

# --- dispatcher 事件过滤 ---
if [[ $# -ge 2 ]]; then
    # dispatcher 模式: 由 NetworkManager 自动调用
    IFACE="$1"
    ACTION="$2"
    # 只在接口 up 时执行，其他事件忽略
    [[ "$ACTION" != "up" ]] && exit 0
    # 用 ethtool 快速检查驱动，非 r8152 直接退出
    DRIVER_CHECK=$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
    [[ "$DRIVER_CHECK" != "r8152" ]] && exit 0
fi

# --- 手动运行时仍需 root ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] 此脚本需要 root 权限运行 (修改系统连接配置)。"
    echo "[!] 请使用: sudo $0${1:+ $1}"
    exit 1
fi

NM_DEST="org.freedesktop.NetworkManager"
NM_PATH="/org/freedesktop/NetworkManager"
NM_IFACE="org.freedesktop.NetworkManager"
DEV_IFACE="org.freedesktop.NetworkManager.Device"
CONN_IFACE="org.freedesktop.NetworkManager.Connection"
PROPS_IFACE="org.freedesktop.DBus.Properties"

DEVICE_TYPE_ETHERNET=1
TARGET_DRIVER="r8152"
# 手动模式支持传 retries 值；dispatcher 模式使用默认值
# 默认值 -1 表示恢复为 NetworkManager 默认值（无限重试）
RETRIES="${1:-0}"
# dispatcher 模式下 $1 是接口名不是 retries，需要重置
[[ $# -ge 2 ]] && RETRIES=0

logger -t fix-r8152 "开始查找 Driver=${TARGET_DRIVER} 的以太网设备 (retries=${RETRIES})..."

# ---------------------------------------------------------------------------
# 1. 通过 D-Bus 读取 AllDevices 属性
#    注意: AllDevices 属于 org.freedesktop.NetworkManager 接口，
#          不能用 org.freedesktop.DBus.Properties 读取。
# ---------------------------------------------------------------------------
logger -t fix-r8152 "调用: busctl get-property AllDevices"
ALL_DEVICES_RAW=$(busctl get-property "${NM_DEST}" "${NM_PATH}" "${NM_IFACE}" AllDevices 2>&1)
RET=$?

if [[ $RET -ne 0 ]] || [[ -z "${ALL_DEVICES_RAW}" ]]; then
    logger -t fix-r8152 -p user.err "busctl 调用失败: ${ALL_DEVICES_RAW}"
    exit 1
fi

# busctl 输出格式: ao 5 "/path1" "/path2" ...
# 路径带双引号，需要用 tr 去掉引号后再按空格分割
readarray -t DEVICE_PATHS <<< "$(echo "${ALL_DEVICES_RAW}" | tr -d '"' | awk '{for(i=3;i<=NF;i++) print $i}')"

if [[ ${#DEVICE_PATHS[@]} -eq 0 ]]; then
    logger -t fix-r8152 "未找到任何设备"
    exit 0
fi

logger -t fix-r8152 "共发现 ${#DEVICE_PATHS[@]} 个设备，开始筛选..."

# ---------------------------------------------------------------------------
# 2. 遍历每个设备，检查 DeviceType 和 Driver
# ---------------------------------------------------------------------------
CONNECTION_IDS=()

for DEV_PATH in "${DEVICE_PATHS[@]}"; do
    [[ -z "${DEV_PATH}" ]] && continue

    # ---------------------------------------------------------------------------
    # 获取 DeviceType: 用 Properties.Get 读取
    # ---------------------------------------------------------------------------
    DEV_TYPE_RAW=$(busctl get-property "${NM_DEST}" "${DEV_PATH}" "${DEV_IFACE}" DeviceType 2>&1)
    RET=$?
    if [[ $RET -ne 0 ]] || [[ -z "${DEV_TYPE_RAW}" ]]; then
        continue
    fi
    DEV_TYPE=$(echo "${DEV_TYPE_RAW}" | awk '{print $2}')

    # ---------------------------------------------------------------------------
    # 获取 Driver: 用 Properties.Get 读取
    # ---------------------------------------------------------------------------
    DRIVER_RAW=$(busctl get-property "${NM_DEST}" "${DEV_PATH}" "${DEV_IFACE}" Driver 2>&1)
    RET=$?
    if [[ $RET -ne 0 ]] || [[ -z "${DRIVER_RAW}" ]]; then
        continue
    fi
    # busctl 输出格式: s "driver_name"，去掉 s 和引号
    DRIVER=$(echo "${DRIVER_RAW}" | awk '{print $2}' | tr -d "'\"")

    if [[ "${DEV_TYPE}" != "${DEVICE_TYPE_ETHERNET}" || "${DRIVER}" != "${TARGET_DRIVER}" ]]; then
        continue
    fi

    logger -t fix-r8152 "找到目标设备: ${DEV_PATH} (Driver=${DRIVER})"

    # ---------------------------------------------------------------------------
    # 3. 获取该设备的 AvailableConnections
    # ---------------------------------------------------------------------------
    CONNS_RAW=$(busctl get-property "${NM_DEST}" "${DEV_PATH}" "${DEV_IFACE}" AvailableConnections 2>&1)
    RET=$?
    if [[ $RET -ne 0 ]] || [[ -z "${CONNS_RAW}" ]]; then
        continue
    fi

    # 去掉 "ao N" 前缀，取所有路径（同样需要去引号）
    readarray -t CONN_PATHS <<< "$(echo "${CONNS_RAW}" | tr -d '"' | awk '{for(i=3;i<=NF;i++) print $i}')"

    for CONN_PATH in "${CONN_PATHS[@]}"; do
        [[ -z "${CONN_PATH}" ]] && continue

        # ---------------------------------------------------------------------------
        # 4. 通过 Filename 属性获取连接名 (不需要 PolicyKit)
        #    GetSettings 方法需要 PolicyKit 鉴权，busctl 无法处理，
        #    但 Filename 属性是普通属性，可直接读取。
        # ---------------------------------------------------------------------------
        CONN_FILE_RAW=$(busctl get-property "${NM_DEST}" "${CONN_PATH}" \
            "org.freedesktop.NetworkManager.Settings.Connection" Filename 2>&1)
        RET=$?
        if [[ $RET -ne 0 ]] || [[ -z "${CONN_FILE_RAW}" ]]; then
            continue
        fi

        # busctl 输出: s "/path/to/file.nmconnection"
        # 用 sed 提取引号内的完整路径（处理含空格的文件名）
        CONN_FILE_PATH=$(echo "${CONN_FILE_RAW}" | sed -n 's/^s "\(.*\)"$/\1/p')
        CONN_FILE_NAME=$(basename "${CONN_FILE_PATH}" .nmconnection)

        # 文件名含 \xxx 八进制转义（如中文），用 printf '%b' 解码
        CONN_ID=$(printf '%b' "${CONN_FILE_NAME}" 2>/dev/null || echo "${CONN_FILE_NAME}")

        # 文件名可能带 UUID 后缀，如 "有线连接 1-UUID"，需去掉
        CONN_ID=$(echo "${CONN_ID}" | sed 's/-[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}$//')

        if [[ -z "${CONN_ID}" ]]; then
            continue
        fi

        CONNECTION_IDS+=("${CONN_ID}")
        logger -t fix-r8152 "  - 连接: ${CONN_ID}"
    done
done

# ---------------------------------------------------------------------------
# 5. 对找到的每个连接执行 nmcli modify
# ---------------------------------------------------------------------------
if [[ ${#CONNECTION_IDS[@]} -eq 0 ]]; then
    logger -t fix-r8152 "未找到匹配的设备或连接"
    exit 0
fi

logger -t fix-r8152 "开始修改 ${#CONNECTION_IDS[@]} 个连接..."

for CONN_ID in "${CONNECTION_IDS[@]}"; do
    nmcli connection modify "${CONN_ID}" connection.autoconnect-retries "${RETRIES}" 2>&1 | while read line; do
        logger -t fix-r8152 -p user.err "  [${CONN_ID}] ${line}"
    done
    nmcli connection modify "${CONN_ID}" connection.autoconnect-reset-retries -1 2>&1 | while read line; do
        logger -t fix-r8152 -p user.err "  [${CONN_ID}] ${line}"
    done
    logger -t fix-r8152 "  [OK] ${CONN_ID} 设置完成 (retries=${RETRIES}, reset-retries=-1)"
done

logger -t fix-r8152 "全部完成，共修改 ${#CONNECTION_IDS[@]} 个连接"
__10_FIX_R8152_EMBEDDED_EOF__
chmod 755 ${DISPATCHER_PATH}

if [[ ! -d ${WATCH_PATH%/*} ]]; then
    echo "[*] 目录不存在，创建目录: ${WATCH_PATH%/*}"
    mkdir -p ${WATCH_PATH%/*} || { echo "[!] 创建目录失败: ${WATCH_PATH%/*}"; exit 1; }
fi
echo "[*] 写入 ${WATCH_PATH}"
cat > ${WATCH_PATH} <<'__FIX_R8152_WATCH_EMBEDDED_EOF__'
#!/bin/bash
#
# 监听 NetworkManager 的 StateChanged D-Bus 信号，
# 当 NM 状态变为 NM_STATE_CONNECTED_LOCAL 及以上时，
# 执行 10-fix-r8152 脚本修复 r8152 自动连接配置。
#
# NM 状态值:
#   0  NM_STATE_UNKNOWN
#  10 NM_STATE_ASLEEP
#  20 NM_STATE_DISCONNECTED
#  30 NM_STATE_DISCONNECTING
#  40 NM_STATE_CONNECTING
#  50 NM_STATE_CONNECTED_LOCAL      <-- NM 就绪，开始检测设备
#  60 NM_STATE_CONNECTED_SITE
#  70 NM_STATE_CONNECTED_GLOBAL

# 根据自身安装位置解析修复脚本路径，兼容 /lib、/usr/lib 等不同基目录
DISPATCHER_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../shell/10-fix-r8152"
STATE_NM_READY=50  # NM_STATE_CONNECTED_LOCAL 及以上

NM_DEST="org.freedesktop.NetworkManager"
NM_PATH="/org/freedesktop/NetworkManager"
NM_IFACE="org.freedesktop.NetworkManager"

# ---------------------------------------------------------------------------
# 立即执行一次，捕获 NM 已处于运行状态的情况
# ---------------------------------------------------------------------------
run_fix() {
    logger -t fix-r8152-watch "NM 状态变化，执行修复脚本..."
    "$DISPATCHER_SCRIPT" 2>/dev/null || {
        logger -t fix-r8152-watch -p user.err "修复脚本执行失败"
    }
}

# ---------------------------------------------------------------------------
# 读取当前 NM 状态，如果已就绪则立即执行
# ---------------------------------------------------------------------------
current_state=$(busctl get-property "${NM_DEST}" "${NM_PATH}" "${NM_IFACE}" "State" 2>/dev/null | awk '{print $2}')
if [[ -n "$current_state" ]] && [[ "$current_state" -ge "$STATE_NM_READY" ]]; then
    logger -t fix-r8152-watch "当前 NM 状态=${current_state}，NM 已就绪，立即执行"
    run_fix
else
    logger -t fix-r8152-watch "当前 NM 状态=${current_state:-unknown}，等待 NM 就绪..."
fi

# ---------------------------------------------------------------------------
# 监听 StateChanged 信号，等待 NM 变为 CONNECTED_LOCAL 及以上
# dbus-monitor 比 busctl subscribe 兼容更广的系统版本
# ---------------------------------------------------------------------------
dbus-monitor --system "type='signal',sender='${NM_DEST}',interface='${NM_IFACE}',member='StateChanged'" 2>/dev/null | while read -r line; do
    # dbus-monitor 输出包含 member=StateChanged 时表示信号到达
    echo "$line" | grep -q "member=StateChanged" || continue
    new_state=$(busctl get-property "${NM_DEST}" "${NM_PATH}" "${NM_IFACE}" "State" 2>/dev/null | awk '{print $2}')
    if [[ -n "$new_state" ]] && [[ "$new_state" -ge "$STATE_NM_READY" ]]; then
        logger -t fix-r8152-watch "NM 状态变为 ${new_state}，执行修复脚本"
        run_fix
    fi
done

# dbus-monitor 退出意味着监听断开（NM 重启或 dbus 异常），
# 以非零码退出以触发 systemd Restart=on-failure 重启本服务
logger -t fix-r8152-watch "dbus-monitor 已退出，终止服务以触发 systemd 重启"
exit 1
__FIX_R8152_WATCH_EMBEDDED_EOF__
chmod 755 ${WATCH_PATH}

if [[ ! -d ${OVERRIDE_PATH%/*} ]]; then
    echo "[*] 目录不存在，创建目录: ${OVERRIDE_PATH%/*}"
    mkdir -p ${OVERRIDE_PATH%/*} || { echo "[!] 创建目录失败: ${OVERRIDE_PATH%/*}"; exit 1; }
fi
echo "[*] 写入 ${OVERRIDE_PATH}"
cat > ${OVERRIDE_PATH} <<'__OVERRIDE_JSON_EMBEDDED_EOF__'
{
    "contents": {
        "disableAllNotify": {
            "permissions": "readwrite",
            "serial": 1,
            "value": true
        },
        "disableConnectingAnimation": {
            "permissions": "readwrite",
            "serial": 1,
            "value": true
        },
        "needCheckNetwork": {
            "permissions": "readwrite",
            "serial": 1,
            "value": true
        },
        "reapplyFlags": {
            "permissions": "readwrite",
            "serial": 1,
            "value": "2"
        }
    },
    "magic": "dsg.config.override",
    "version": "1.0"
}
__OVERRIDE_JSON_EMBEDDED_EOF__
chmod 644 ${OVERRIDE_PATH}

if [[ ! -d ${SERVICE_PATH%/*} ]]; then
    echo "[*] 目录不存在，创建目录: ${SERVICE_PATH%/*}"
    mkdir -p ${SERVICE_PATH%/*} || { echo "[!] 创建目录失败: ${SERVICE_PATH%/*}"; exit 1; }
fi
echo "[*] 写入 ${SERVICE_PATH}"
cat > ${SERVICE_PATH} <<EOF
[Unit]
Description=Watch NetworkManager and fix r8152 autoconnect
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=${WATCH_PATH}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 644 ${SERVICE_PATH}

# ---------------------------------------------------------------------------
# 启用服务 (默认开机自启，镜像构建环境下 systemctl 可能不可用，
# 失败时手动创建 multi-user.target 软链接兜底)
# ---------------------------------------------------------------------------
echo "[*] 启用 fix-r8152.service 开机自启..."
systemctl daemon-reload >/dev/null 2>&1 || true
if ! systemctl enable fix-r8152.service >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf ${SERVICE_PATH} /etc/systemd/system/multi-user.target.wants/fix-r8152.service
    echo "[*] systemctl 不可用，已手动创建开机自启软链接"
fi

echo ""
echo "[OK] fix-r8152 安装完成，服务已设为开机自启"
echo "     修复脚本: ${DISPATCHER_PATH}"
echo "     守护脚本: ${WATCH_PATH}"
