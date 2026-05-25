#!/bin/bash
# CloudStudio 出口封锁了 Google CDN 部分 IP 段，但提供了透明代理
# 通过 iptables DNAT 将 Google 流量重定向到透明代理，其余流量由 Xray freedom 直连
#
# CloudStudio 直连能力：
#   ✅ Google (通过透明代理), 中国站点, GitHub, Cloudflare, Microsoft, Apple 等
#   ❌ Wikipedia, DuckDuckGo 等（被 CloudStudio 额外封锁）

# ── 自动检测透明代理 IP ──
find_proxy() {
    local found=""
    for n in $(seq 1 100); do
        local ip="198.18.0.$n"
        local code
        code=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 2 \
               -H "Host: www.google.com" "https://$ip" 2>/dev/null)
        if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

PROXY_IP=$(find_proxy)
if [ -z "$PROXY_IP" ]; then
    echo "[!] 198.18.0.x 未找到，扫描 198.18.1.x..."
    for n in $(seq 1 100); do
        tip="198.18.1.$n"
        tcode=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 2 \
               -H "Host: www.google.com" "https://$tip" 2>/dev/null)
        if [ "$tcode" = "200" ] || [ "$tcode" = "301" ] || [ "$tcode" = "302" ]; then
            PROXY_IP="$tip"
            break
        fi
    done
fi

if [ -z "$PROXY_IP" ]; then
    echo "[!] 未找到透明代理，回退到默认 198.18.0.36"
    PROXY_IP="198.18.0.36"
fi

echo "[*] 透明代理: $PROXY_IP:443"

# ── Google IP 段 ──
GOOGLE_RANGES=(
    "142.250.0.0/15"   # gemini.gstatic.com, lh3.googleusercontent.com 等
    "172.217.0.0/16"   # www.google.com (经典 IP 段)
    "216.58.192.0/19"  # www.google.com (另一 IP 段)
    "74.125.0.0/16"    # Google 前端服务
    "64.233.160.0/19"  # Google 搜索等
    "173.194.0.0/16"   # Google 服务
    "66.102.0.0/20"    # Googlebot/爬虫相关
)

for range in "${GOOGLE_RANGES[@]}"; do
    sudo iptables -t nat -C OUTPUT -d "$range" -p tcp --dport 443 -j DNAT --to-destination "$PROXY_IP:443" 2>/dev/null || \
      sudo iptables -t nat -A OUTPUT -d "$range" -p tcp --dport 443 -j DNAT --to-destination "$PROXY_IP:443"
done

echo "[*] iptables DNAT rules added (Google IP ranges -> $PROXY_IP:443)"
echo "[*] Starting Xray..."
pkill xray 2>/dev/null
nohup xray run -c /usr/local/etc/xray/config.json > /tmp/xray.log 2>&1 &
echo "[*] Xray started in background (log: /tmp/xray.log)"