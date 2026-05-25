# CloudStudio 透明代理方案

通过 CloudStudio 搭建一条公有流量隧道，实现国内访问 Google/Gemini 等服务。

## 架构

```
macOS 浏览器                                    CloudStudio 服务器
┌─────────────┐     WebSocket (WSS)     ┌──────────────────────────────┐
│  SOCKS5     │ ──────────────────────► │  Xray VLESS+WS (:8080)       │
│  127.0.0.1  │                         │    │                         │
│  :1080      │                         │    ├─ Google IP → iptables   │
│  (proxy.py) │                         │    │   DNAT → 198.18.0.36:443│
└─────────────┘                         │    │        (透明代理)         │
                                        │    │                         │
                                        │    └─ 其他 IP → freedom 直连  │
                                        └──────────────────────────────┘
```

## CloudStudio 可代理的范围

| 网站类别 | 方式 | 状态 |
|----------|------|:----:|
| Google / Gemini / Gmail / YouTube | 透明代理 (198.18.0.36:443) | ✅ |
| GitHub | freedom 直连 | ✅ |
| 国内站点（百度、B站、知乎等） | freedom 直连 | ✅ |
| Cloudflare / Microsoft / Apple | freedom 直连 | ✅ |
| Wikipedia / DuckDuckGo | — | ❌ 被 CloudStudio 额外封锁 |

> CloudStudio 的透明代理 `198.18.0.36` **仅允许 Google 服务**，非 Google 请求会返回 404。

---

## 一、服务端（CloudStudio）

### 1. 安装 Xray

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

### 2. 写入 Xray 配置

```bash
cat > /usr/local/etc/xray/config.json << 'EOF'
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 8080,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/proxy"}
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"}
  ]
}
EOF
```

### 3. 写入启动脚本（含 iptables DNAT）

```bash
cat > /workspace/start.sh << 'STARTEOF'
#!/bin/bash
# CloudStudio 出口封锁了 Google CDN 部分 IP 段，但提供了透明代理
# 启动时自动检测透明代理 IP，然后追加上 iptables DNAT 规则

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
    "142.250.0.0/15"   # gemini.gstatic.com
    "172.217.0.0/16"   # www.google.com
    "216.58.192.0/19"  # www.google.com
    "74.125.0.0/16"    # Google 前端
    "64.233.160.0/19"  # Google 搜索
    "173.194.0.0/16"   # Google 服务
    "66.102.0.0/20"    # Googlebot
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
STARTEOF
chmod +x /workspace/start.sh
```

### 4. 暴露 8080 端口

在 CloudStudio 界面的 **端口面板** 中暴露 `8080` 端口，获得对外访问地址，例如：

```
7800234939e540a9ab98ceedc4e9732f--8080.ap-shanghai2.cloudstudio.club
```

### 5. 启动服务

```bash
cd /workspace && bash start.sh
```

---

## 二、客户端（macOS）

### 1. 保存代理脚本

将 `SERVER` 替换为你的 CloudStudio 端口地址：

```bash
cat > ~/proxy.py << 'PYEOF'
import socket, ssl, struct, os, threading, base64, time

SERVER = "你的地址--8080.ap-shanghai2.cloudstudio.club"
PORT = 443
UUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
WS_PATH = "/proxy"
LOCAL_PORT = 1080
UUID_BYTES = bytes.fromhex(UUID.replace("-", ""))

# ──────────── WebSocket 帧编解码 ────────────

def ws_frame(data):
    payload = data if isinstance(data, bytes) else data.encode()
    length = len(payload)
    frame = bytearray([0x82])
    if length < 126:
        frame.append(0x80 | length)
    elif length < 65536:
        frame.append(0x80 | 126)
        frame.extend(struct.pack(">H", length))
    else:
        frame.append(0x80 | 127)
        frame.extend(struct.pack(">Q", length))
    mask_key = os.urandom(4)
    frame.extend(mask_key)
    frame.extend(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    return bytes(frame)

class WsReader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
    def read(self):
        while True:
            if len(self.buf) >= 2:
                length = self.buf[1] & 0x7F
                offset = 2
                if length == 126:
                    if len(self.buf) < 4: self._fill(); continue
                    length = struct.unpack(">H", self.buf[2:4])[0]
                    offset = 4
                elif length == 127:
                    if len(self.buf) < 10: self._fill(); continue
                    length = struct.unpack(">Q", self.buf[2:10])[0]
                    offset = 10
                masked = bool(self.buf[1] & 0x80)
                if masked: offset += 4
                total = offset + length
                if len(self.buf) >= total:
                    opcode = self.buf[0] & 0x0F
                    ps = offset
                    if masked:
                        mk = self.buf[offset-4:offset]
                        payload = bytearray(self.buf[ps:ps+length])
                        for i in range(len(payload)):
                            payload[i] ^= mk[i % 4]
                        payload = bytes(payload)
                    else:
                        payload = self.buf[ps:ps+length]
                    self.buf = self.buf[total:]
                    if opcode == 0x08: return None
                    if opcode == 0x09:
                        try: self.sock.sendall(b"\x8a\x80" + os.urandom(2))
                        except: pass
                        continue
                    if opcode == 0x0A: continue
                    return payload
            self._fill()
    def _fill(self):
        d = self.sock.recv(131072)
        if not d: raise ConnectionError("WS closed")
        self.buf += d

# ──────────── WebSocket 连接 ────────────

def ws_handshake(sock):
    key = base64.b64encode(os.urandom(16)).decode()
    req = f"GET {WS_PATH} HTTP/1.1\r\nHost: {SERVER}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk: raise ConnectionError("WS handshake failed")
        resp += chunk
    if b" 101 " not in resp.split(b"\r\n")[0]:
        raise ConnectionError(f"WS rejected: {resp[:200]}")

def connect_ws():
    raw = socket.create_connection((SERVER, PORT), timeout=15)
    raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock = ssl.create_default_context().wrap_socket(raw, server_hostname=SERVER)
    ws_handshake(sock)
    return sock

# ──────────── VLESS 协议头 ────────────

def vless_header(vless_atype, addr, port):
    h = bytearray()
    h.append(0x00); h.extend(UUID_BYTES); h.append(0x00); h.append(0x01)
    h.extend(struct.pack(">H", port)); h.append(vless_atype)
    if vless_atype == 0x01: h.extend(socket.inet_aton(addr))
    elif vless_atype == 0x02: h.append(len(addr)); h.extend(addr.encode())
    elif vless_atype == 0x03: h.extend(socket.inet_pton(socket.AF_INET6, addr))
    return bytes(h)

# ──────────── SOCKS5 处理 ────────────

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk: raise ConnectionError("closed")
        buf += chunk
    return buf

def handle_socks5(client):
    header = recv_exact(client, 2)
    if header[0] != 0x05: raise ValueError("Not SOCKS5")
    recv_exact(client, header[1])
    client.sendall(b"\x05\x00")
    req = recv_exact(client, 4)
    atype = req[3]
    if req[1] != 0x01:
        client.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
        raise ValueError(f"Unsupported cmd={req[1]}")
    if atype == 0x01:
        addr = socket.inet_ntoa(recv_exact(client, 4)); vless_atype = 0x01
    elif atype == 0x03:
        dl = recv_exact(client, 1)[0]; addr = recv_exact(client, dl).decode(); vless_atype = 0x02
    elif atype == 0x04:
        addr = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16)); vless_atype = 0x03
    else:
        client.sendall(b"\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00")
        raise ValueError(f"Unknown atype={atype}")
    port = struct.unpack(">H", recv_exact(client, 2))[0]
    client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    return vless_atype, addr, port

# ──────────── 数据中继 + 心跳保活 ────────────

def ws_ping():
    """WebSocket ping frame (opcode 0x9, masked, zero-length)"""
    return bytes([0x89, 0x80]) + os.urandom(4)

def keepalive(ws, done):
    """每 10s 发送 WebSocket ping，防止 CloudStudio 杀掉空闲连接（约 15-19s 超时）"""
    while not done.wait(10):
        try:
            ws.sendall(ws_ping())
        except:
            done.set()
            break

def relay(c, w):
    reader = WsReader(w)
    header_stripped = [False]
    header_buf = [b""]
    done = threading.Event()
    def c2w():
        try:
            while not done.is_set():
                d = c.recv(131072)
                if not d: break
                w.sendall(ws_frame(d))
        except: pass
        finally: done.set()
    def w2c():
        try:
            while not done.is_set():
                payload = reader.read()
                if payload is None: break
                if not header_stripped[0]:
                    header_buf[0] += payload
                    if len(header_buf[0]) >= 1 and header_buf[0][0] != 0x00:
                        header_stripped[0] = True
                        c.sendall(header_buf[0])
                        header_buf[0] = b""
                        continue
                    if len(header_buf[0]) < 2: continue
                    al = header_buf[0][1]
                    he = 2 + al
                    if len(header_buf[0]) < he: continue
                    remainder = header_buf[0][he:]
                    header_stripped[0] = True
                    if remainder: c.sendall(remainder)
                    continue
                c.sendall(payload)
        except: pass
        finally: done.set()
    t1 = threading.Thread(target=c2w, daemon=True)
    t2 = threading.Thread(target=w2c, daemon=True)
    tk = threading.Thread(target=keepalive, args=(w, done), daemon=True)
    t1.start(); t2.start(); tk.start()
    done.wait(timeout=180)
    try: c.shutdown(socket.SHUT_RDWR)
    except: pass
    try: w.shutdown(socket.SHUT_RDWR)
    except: pass

def handle(client, addr):
    ws = None
    try:
        vless_atype, target_addr, target_port = handle_socks5(client)
        print(f"[+] {addr[0]}:{addr[1]} -> {target_addr}:{target_port}", flush=True)
        ws = connect_ws()
        ws.sendall(ws_frame(vless_header(vless_atype, target_addr, target_port)))
        relay(client, ws)
    except Exception as e:
        print(f"[-] {e}", flush=True)
    finally:
        try: client.close()
        except: pass
        if ws:
            try: ws.close()
            except: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LOCAL_PORT))
    srv.listen(200)
    print(f"[*] SOCKS5 on 127.0.0.1:{LOCAL_PORT} -> {SERVER}:{PORT}{WS_PATH}", flush=True)
    try:
        while True:
            c, addr = srv.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=handle, args=(c, addr), daemon=True).start()
    except KeyboardInterrupt:
        print("\n[*] Stopped", flush=True)
    finally:
        srv.close()

if __name__ == "__main__":
    main()
PYEOF
```

### 2. 启动客户端

```bash
python3 ~/proxy.py
```

保持终端运行，SOCKS5 代理监听在 `127.0.0.1:1080`。

---

## 三、浏览器使用

### Chrome（命令行启动，所有流量走代理）

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --proxy-server="socks5://127.0.0.1:1080" \
  --disable-quic &
```

快捷别名：

```bash
echo 'alias chrome-proxy="/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --proxy-server=\"socks5://127.0.0.1:1080\" --disable-quic &"' >> ~/.zshrc
source ~/.zshrc
```

之后输入 `chrome-proxy` 即可。

### Chrome（SwitchyOmega 智能分流）

不想所有流量都走代理？用 SwitchyOmega 只让需要的网站走代理：

1. 安装 [SwitchyOmega](https://chrome.google.com/webstore/detail/proxy-switchyomega/padekgcemlokbadohgkifijomclgjgif) 扩展
2. 新建代理情景 → SOCKS5, `127.0.0.1`, `1080` → 命名 `CloudStudio`
3. 新建自动切换模式 → 规则走 `CloudStudio`，默认走 `直接连接`
4. 添加规则：`*.google.com`, `*.gstatic.com`, `*.googleapis.com`, `*.googleusercontent.com`, `*.github.com` 等
5. 插件图标选自动切换模式

### Safari（PAC 文件）

```bash
cat > ~/proxy.pac << 'EOF'
function FindProxyForURL(url, host) {
    if (shExpMatch(host, "*.google.com") ||
        shExpMatch(host, "*.googleapis.com") ||
        shExpMatch(host, "*.gstatic.com") ||
        shExpMatch(host, "*.googleusercontent.com") ||
        shExpMatch(host, "*.youtube.com") ||
        shExpMatch(host, "*.ytimg.com") ||
        shExpMatch(host, "*.ggpht.com") ||
        shExpMatch(host, "*.googlevideo.com") ||
        shExpMatch(host, "*.github.com") ||
        shExpMatch(host, "*.githubusercontent.com") ||
        shExpMatch(host, "twitter.com") ||
        shExpMatch(host, "*.twitter.com") ||
        shExpMatch(host, "*.x.com") ||
        shExpMatch(host, "*.twimg.com")) {
        return "SOCKS5 127.0.0.1:1080";
    }
    return "DIRECT";
}
EOF
```

启用：

```bash
networksetup -setautoproxyurl Wi-Fi "file://$HOME/proxy.pac"
networksetup -setautoproxystate Wi-Fi on
```

关闭：

```bash
networksetup -setautoproxystate Wi-Fi off
```

---

## 四、常用操作速查

| 操作 | 命令 |
|------|------|
| 启动服务端 | `cd /workspace && bash start.sh` |
| 启动客户端 | `python3 ~/proxy.py` |
| Chrome 走代理 | `chrome-proxy` |
| Safari 开启代理 | `networksetup -setautoproxystate Wi-Fi on` |
| Safari 关闭代理 | `networksetup -setautoproxystate Wi-Fi off` |
| 查看 Xray 日志 | `tail -f /tmp/xray.log` |
| 停止客户端 | `Ctrl+C` |

---

## 五、常见问题

### ERR_CONNECTION_CLOSED

**现象：** Gemini 页面能打开但功能不可用，或长时间空闲后断开。

**原因：** CloudStudio 会在大约 15-19 秒空闲后杀掉 WebSocket 连接。

**解决：** 客户端 `proxy.py` 已内置 WebSocket 心跳（每 10 秒 ping），确保使用最新版本。

### 非 Google 网站 404

CloudStudio 透明代理 `198.18.0.36` 仅允许 Google 服务，其他网站返回 404。需走 `freedom` 直连即可（已配置），但 Wikipedia、DuckDuckGo 等部分站点被 CloudStudio 额外封锁。

### 网站加载慢

CloudStudio 位于上海，国内访问首次握手可能需要 1-3 秒。DNS 解析由 Xray 服务端 `sniffing` 自动处理，无需客户端额外配置。
