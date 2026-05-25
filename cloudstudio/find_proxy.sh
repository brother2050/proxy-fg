#!/bin/bash
# 扫 CloudStudio 透明代理 IP
# 透明代理通常位于 198.18.0.0/15（RFC 2544 保留段）
# 它会处理 Google 的 HTTPS 请求，非 Google 返回 404

echo "[*] 开始扫描透明代理 IP (198.18.0.0/24)..."
echo "[*] 测试方式: curl https://<IP> --connect-timeout 2"
echo ""

check_ip() {
    local ip="$1"
    local label="${ip##*.}"
    local result
    result=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 2 "https://$ip" 2>/dev/null)
    if [ "$result" = "301" ] || [ "$result" = "302" ] || [ "$result" = "200" ]; then
        # 只要返回 HTTP 就确认是可用的透明代理（整个 198.18.0.0/15 路由到同一个代理池）
        # 进一步区分：请求 google.com 确认是 Google 代理
        local gresult
        gresult=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 2 -H "Host: www.google.com" "https://$ip" 2>/dev/null)
        if [ "$gresult" = "200" ] || [ "$gresult" = "301" ] || [ "$gresult" = "302" ]; then
            echo "✅ $ip  -> HTTP $result (Google OK)"
            echo "$ip" >> /tmp/proxy_candidates.txt
        fi
    fi
}

export -f check_ip

# 并行扫描 198.18.0.1-100
rm -f /tmp/proxy_candidates.txt
seq 1 100 | xargs -P 50 -I {} bash -c "check_ip 198.18.0.{}"

echo ""
if [ -f /tmp/proxy_candidates.txt ] && [ -s /tmp/proxy_candidates.txt ]; then
    echo "========== 找到的透明代理 =========="
    echo ""
    sort -t. -k4 -n /tmp/proxy_candidates.txt | while read ip; do
        echo "  $ip:443"
    done
    echo ""
    echo "推荐使用第一个 IP，选任意一个都行（整个网段路由到同一个代理池）"
    echo ""
    echo "用法:"
    echo "  sudo iptables -t nat -A OUTPUT -d <Google_IP> -p tcp --dport 443 -j DNAT --to-destination $ip:443"
    rm -f /tmp/proxy_candidates.txt
else
    echo "❌ 198.18.0.1-100 没有找到代理"
    echo "[*] 扩大搜索 198.18.1.0/24 ..."
    seq 1 100 | xargs -P 50 -I {} bash -c "check_ip 198.18.1.{}"
    echo ""
    if [ -f /tmp/proxy_candidates.txt ] && [ -s /tmp/proxy_candidates.txt ]; then
        echo "========== 找到的透明代理 =========="
        sort -t. -k4 -n /tmp/proxy_candidates.txt | while read ip; do
            echo "  $ip:443"
        done
        rm -f /tmp/proxy_candidates.txt
    else
        echo "❌ 均未找到，请手动检查其他网段或联系 CloudStudio 支持"
        rm -f /tmp/proxy_candidates.txt
    fi
fi
