#!/usr/bin/env bash
# ============================================================================
# 13支 对战服务器 —— frp 服务端一键安装（在有公网 IP 的 Linux 上运行，如腾讯轻量云）
# 用法：
#   bash frps-setup.sh 你的令牌               # 令牌必填（本脚本会公开托管，故不内置密钥）
#   bash frps-setup.sh 你的令牌 7000 8080    # 自定义令牌 / bindPort / 对外端口
# 完成后：
#   systemctl status frps
#   本机侧 deploy/frpc.toml 填这台机器的公网 IP，deploy/tunnel.json 写
#   {"ws":"ws://公网IP:8080/ws","mode":"frp"}
# 注意：云厂商「安全组」需要在控制台手动放行 7000 与 8080（脚本只能开系统防火墙）。
# ============================================================================
set -e

TOKEN="${1:?用法: bash frps-setup.sh <令牌> [bindPort] [remotePort]}"
BIND_PORT="${2:-7000}"
REMOTE_PORT="${3:-8080}"
FRP_DIR="/etc/frp"
DL="/tmp/frp-dl"

echo "==> 1/5 检测系统与架构"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) FRP_ARCH="amd64" ;;
  aarch64|arm64) FRP_ARCH="arm64" ;;
  *) echo "不支持的架构：$ARCH"; exit 1 ;;
esac
echo "    架构: $ARCH -> $FRP_ARCH"

echo "==> 2/5 获取 frp 最新版本号（失败则用备用镜像/固定版本）"
VER=""
for api in "https://api.github.com/repos/fatedier/frp/releases/latest" \
           "https://ghproxy.net/https://api.github.com/repos/fatedier/frp/releases/latest"; do
  VER=$(curl -fsSL --max-time 20 "$api" 2>/dev/null | grep -o '"tag_name": *"v[^"]*"' | head -1 | sed 's/.*"v//; s/"//') || true
  [ -n "$VER" ] && break
done
[ -z "$VER" ] && VER="0.61.1"        # 兜底版本
echo "    frp 版本: v$VER"

echo "==> 3/5 下载并安装 frps"
rm -rf "$DL"; mkdir -p "$DL"
FILE="frp_${VER}_linux_${FRP_ARCH}.tar.gz"
for base in "https://github.com/fatedier/frp/releases/download" \
            "https://ghproxy.net/https://github.com/fatedier/frp/releases/download" \
            "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download"; do
  url="$base/v${VER}/${FILE}"
  echo "    尝试: $url"
  if curl -fL --max-time 120 -o "$DL/$FILE" "$url"; then OK=1; break; fi
done
[ -z "$OK" ] && { echo "下载失败：请手动下载 $FILE 解压后把 frps 放到 /usr/local/bin/"; exit 1; }
tar -xzf "$DL/$FILE" -C "$DL"
install -m 0755 "$DL/frp_${VER}_linux_${FRP_ARCH}/frps" /usr/local/bin/frps
echo "    已安装: $(/usr/local/bin/frps --version 2>/dev/null || echo frps)"

echo "==> 4/5 写入配置 $FRP_DIR/frps.toml"
mkdir -p "$FRP_DIR"
cat > "$FRP_DIR/frps.toml" <<EOF
bindPort = ${BIND_PORT}
auth.token = "${TOKEN}"
log.to = "/var/log/frps.log"
log.level = "info"
allowPorts = [{ start = ${REMOTE_PORT}, end = ${REMOTE_PORT} }]
EOF
cat "$FRP_DIR/frps.toml"

echo "==> 5/5 注册 systemd 服务并启动"
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server (13支对战中转)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c ${FRP_DIR}/frps.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now frps

# 系统防火墙（云安全组仍需在控制台放行）
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${BIND_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${REMOTE_PORT}/tcp" >/dev/null 2>&1 || true
  echo "    已尝试放行 ufw ${BIND_PORT}/${REMOTE_PORT}"
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${BIND_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="${REMOTE_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  echo "    已尝试放行 firewalld ${BIND_PORT}/${REMOTE_PORT}"
fi

sleep 2
systemctl --no-pager --full status frps | head -12 || true
echo
echo "==== 完成 ===="
echo "1) 去云控制台「安全组/防火墙」放行 TCP ${BIND_PORT} 与 ${REMOTE_PORT}"
echo "2) 本机 deploy/frpc.toml: serverAddr = \"这台机器的公网IP\"（auth.token 保持 '${TOKEN}'）"
echo "3) 本机 deploy/tunnel.json: {\"ws\":\"ws://公网IP:${REMOTE_PORT}/ws\",\"mode\":\"frp\"}"
echo "4) 把 frpc.exe 放进本机 deploy\\ 目录，然后重启看门狗"
echo "自检：tail -f /var/log/frps.log   （看到 start proxy success 即通道已通）"
