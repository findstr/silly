---
title: silly.net.tls
icon: lock
category:
  - API参考
tag:
  - 网络
  - TLS
  - SSL
  - 加密
---

# silly.net.tls

`silly.net.tls` 模块提供了基于 TLS/SSL 协议的加密网络连接功能。它在 TCP 传输层之上提供了安全的数据传输，支持服务器和客户端模式，并支持 ALPN 协议协商（如 HTTP/2）。

## 模块导入

```lua validate
local tls = require "silly.net.tls"
```

## 核心概念

### TLS/SSL 加密

TLS (Transport Layer Security) 是一种加密协议，用于在网络通信中提供安全性和数据完整性。`silly.net.tls` 基于 OpenSSL 实现，提供以下功能：

- **服务器模式**: 监听加密连接，需要配置证书和私钥
- **客户端模式**: 连接到 TLS 服务器，可选 SNI (Server Name Indication)
- **ALPN 支持**: 应用层协议协商，支持 HTTP/1.1、HTTP/2 等协议

### 证书配置

服务器端必须提供 PEM 格式的证书和私钥。证书可以是：
- 自签名证书（用于开发和测试）
- CA 签发的证书（用于生产环境）

### 异步操作

与 `silly.net.tcp` 类似，TLS 模块的读取操作是异步的，会在数据不可用时暂停协程，在数据到达后自动恢复。

---

## 使用示例

### 示例1：HTTPS 服务器

此示例演示了如何创建一个简单的 HTTPS 服务器，处理客户端连接并返回响应。

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()

    -- 服务器证书和私钥（PEM 格式）
    local cert_pem = [[-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUPc2faaWEjGh1RklF9XPAgYS5WSMwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI1MTAwOTA5NDc1M1oXDTM1MTAw
NzA5NDc1M1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEApmUl+7J8zeWdOH6aiNwRSOcFePTxuAyYsAEewVtBCAEv
LVGxQtrsVvd6UosEd0aO/Qz3hvV32wYzI0ZzjGGfy0lCCx9YB05SyYY+KpDwe/os
Mf4RtBS/jN1dVX7TiRQ3KsngMFSXp2aC6IpI5ngF0PS/o2qbwkU19FCELE6G5WnA
fniUaf7XEwrhAkMAczJovqOu4BAhBColr7cQK7CQK6VNEhQBzM/N/hGmIniPbC7k
TjqyohWoLGPT+xQAe8WB39zbIHl+xEDoGAYaaI8I7TlcQWwCOIxdm+w67CQmC/Fy
GTX5fPoK96drushzwvAKphQrpQwT5MxTDvoE9xgbhQIDAQABo1MwUTAdBgNVHQ4E
FgQUsjX1LC+0rS4Ls5lcE8yg5P85LqQwHwYDVR0jBBgwFoAUsjX1LC+0rS4Ls5lc
E8yg5P85LqQwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEADqDJ
HQxRjFPSxIk5EMrxkqxE30LoWKJeW9vqublQU/qHfMo7dVTwfsAvFpTJfL7Zhhqw
l20ijbQVxPtDwPB8alQ/ScP5VRqC2032KTi9CqUqTj+y58oDxgjnm06vr5d8Xkmm
nR2xhUecGkzFYlDoXo1w8XttMUefyHS6HWLXvu94V7Y/8YB4lBCEnwFnhgkYB9CG
RsleiOiZDsaHhnNQsnM+Xl1UJVxJlMStl+Av2rCTAj/LMHniXQ+9QKI/7pNDUeCL
qSdxZephYkeRF8C/i9R5G/gAL40kUFz0sgyXuv/kss3rrxsshKKTRbxnRm1k/J73
9ZiztVOeqpcxFxmf7Q==
-----END CERTIFICATE-----
]]

    local key_pem = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCmZSX7snzN5Z04
fpqI3BFI5wV49PG4DJiwAR7BW0EIAS8tUbFC2uxW93pSiwR3Ro79DPeG9XfbBjMj
RnOMYZ/LSUILH1gHTlLJhj4qkPB7+iwx/hG0FL+M3V1VftOJFDcqyeAwVJenZoLo
ikjmeAXQ9L+japvCRTX0UIQsToblacB+eJRp/tcTCuECQwBzMmi+o67gECEEKiWv
txArsJArpU0SFAHMz83+EaYieI9sLuROOrKiFagsY9P7FAB7xYHf3NsgeX7EQOgY
BhpojwjtOVxBbAI4jF2b7DrsJCYL8XIZNfl8+gr3p2u6yHPC8AqmFCulDBPkzFMO
+gT3GBuFAgMBAAECggEAD5uyVetWuKuetVNu5IKcHnYJNeDoIacQ1YWtYF7SeVE/
HyWoFojZnYjGUSLYLuYP+J20RFUXQpTQzDDKGvN3XUbIaqmshLbsnhm5EB4baM29
Qo0+FOHTW//RxvjIF/Ys/JcGMBJnTV0Yz35VO0Ur6n9i0I3qAW2jk4DP/SX6kl9T
4iJj2Y+69y0bHjesfO71nCUUH6Ym2CHJRd6A4tCeYQr3U/CXOWggpUuPTXFWptt7
uSJjbTQgwUF5H83ih1CUdto1G5LPBUXVD5x2XZshgwZsL1au9kH2l/83BAHKK8io
LQ8FekLN6FLD83mvEwFPyrVhfipbeUz3bKrgEzvOmwKBgQDUbrAgRYCLxxpmguiN
0aPV85xc+VPL+dh865QHhJ0pH/f3fah/U7van/ayfG45aIA+DI7qohGzf03xFnO4
O51RHcRhnjDbXWY5l0ZpOIpvHLLCm8gqIAkX9bt7UyE+PxRSNvUt3kVFT3ZYnYCx
Wb1kiV1oRAzTf1l0X0qamFPqdwKBgQDIhV8OWTBrsuC0U3hmvNB+DPEHnyPWBHvI
+HMflas5gJiZ+3KvrS3vBOXFB3qfTD1LQwUPqeqY0Q41Svvsq2IQAkKedJDdMuPU
RoKaV/Qln85nmibscNcwVGQNUKTeSCJQ43ktrWT01UinamsSEOYTceMqwW10LDaF
Ff1MbKNs4wKBgQDMEPiIR7vQipdF2oNjmPt1z+tpNOnWjE/20KcHAdGna9pcmQ2A
IwPWZMwrcXTBGS34bT/tDXtLnwNUkWjglgPtpFa+H6R3ViWZNUSiV3pEeqEOaW/D
Z7rUlW5gbd8FWLtAryKfyWFpz4e0YLj7pWVWas6cFqLrmO5p6BBWqfYSyQKBgHyp
rjcVa+0JAHobircUm+pB0XeTkIv1rZ98FtaEDjdpo3XXxa1CVVRMDy03QRzYISMx
P2xFjvwCvHqVa5nv0r9xKEmq3oUmpk3KqFecZsUdXQ074QcOADqjvLAqetVWsz7m
rOeg7SrpjonGt1o7904Pd9OU/Z9D/YEv8pIY2GFRAoGASEf3+igRFSECUxLh9LZC
scAxCHh9sz15swDD/rdtEqLKGcxlu74YKkBnyQ/yWA4d/enPnvdP98ThXdXnX0X4
v1HSCliKZXW8cusnBRD2IOyxuIUV/qiMfARylMvlLBccgJR8+olH9f/yF2EFWhoy
125zQzr/ESlTL+5IWeNf2sM=
-----END PRIVATE KEY-----
]]

    -- 启动 TLS 服务器
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {
            {
                cert = cert_pem,
                key = key_pem,
            }
        },
        disp = function(fd, addr)
            wg:fork(function()
                print("客户端已连接:", addr)

                -- 读取 HTTP 请求
                local request, err = tls.readline(fd)
                if not request then
                    print("读取错误:", err)
                    tls.close(fd)
                    return
                end

                print("收到请求:", request)

                -- 发送 HTTP 响应
                local body = "Hello from HTTPS server!"
                local response = string.format(
                    "HTTP/1.1 200 OK\r\n" ..
                    "Content-Type: text/plain\r\n" ..
                    "Content-Length: %d\r\n" ..
                    "\r\n%s",
                    #body, body
                )

                tls.write(fd, response)
                tls.close(fd)
                print("连接已关闭")
            end)
        end
    }

    if not listenfd then
        print("启动服务器失败")
        return
    end

    print("HTTPS 服务器正在监听 127.0.0.1:8443")

    -- 等待一段时间以处理请求
    wg:wait()
    tls.close(listenfd)
end)
```

### 示例2：HTTPS 客户端

此示例演示如何创建 TLS 客户端连接到 HTTPS 服务器。

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"

silly.fork(function()
    -- 解析域名
    local ip = dns.lookup("www.example.com", dns.A)
    if not ip then
        print("DNS 解析失败")
        return
    end

    -- 连接到 HTTPS 服务器 (端口 443)
    local fd, err = tls.connect(
        ip .. ":443",       -- 服务器地址
        nil,                -- 不绑定本地地址
        "www.example.com",  -- SNI hostname
        {"http/1.1"}        -- ALPN 协议
    )

    if not fd then
        print("连接失败:", err)
        return
    end

    print("已连接到服务器")

    -- 检查协商的 ALPN 协议
    local alpn = tls.alpnproto(fd)
    if alpn then
        print("ALPN 协议:", alpn)
    end

    -- 发送 HTTP 请求
    local request = "GET / HTTP/1.1\r\n" ..
                   "Host: www.example.com\r\n" ..
                   "User-Agent: silly-tls-client\r\n" ..
                   "Connection: close\r\n\r\n"

    local ok, write_err = tls.write(fd, request)
    if not ok then
        print("写入失败:", write_err)
        tls.close(fd)
        return
    end

    -- 读取响应头
    local line, read_err = tls.readline(fd)
    if not line then
        print("读取失败:", read_err)
        tls.close(fd)
        return
    end

    print("响应:", line)

    -- 关闭连接
    tls.close(fd)
    print("连接已关闭")
end)
```

### 示例3：证书热重载

此示例演示如何在运行时重载证书，实现零停机时间的证书更新。

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"
local signal = require "silly.signal"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()

    -- 初始证书
    local cert_v1 = [[-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUPc2faaWEjGh1RklF9XPAgYS5WSMwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI1MTAwOTA5NDc1M1oXDTM1MTAw
NzA5NDc1M1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEApmUl+7J8zeWdOH6aiNwRSOcFePTxuAyYsAEewVtBCAEv
LVGxQtrsVvd6UosEd0aO/Qz3hvV32wYzI0ZzjGGfy0lCCx9YB05SyYY+KpDwe/os
Mf4RtBS/jN1dVX7TiRQ3KsngMFSXp2aC6IpI5ngF0PS/o2qbwkU19FCELE6G5WnA
fniUaf7XEwrhAkMAczJovqOu4BAhBColr7cQK7CQK6VNEhQBzM/N/hGmIniPbC7k
TjqyohWoLGPT+xQAe8WB39zbIHl+xEDoGAYaaI8I7TlcQWwCOIxdm+w67CQmC/Fy
GTX5fPoK96drushzwvAKphQrpQwT5MxTDvoE9xgbhQIDAQABo1MwUTAdBgNVHQ4E
FgQUsjX1LC+0rS4Ls5lcE8yg5P85LqQwHwYDVR0jBBgwFoAUsjX1LC+0rS4Ls5lc
E8yg5P85LqQwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEADqDJ
HQxRjFPSxIk5EMrxkqxE30LoWKJeW9vqublQU/qHfMo7dVTwfsAvFpTJfL7Zhhqw
l20ijbQVxPtDwPB8alQ/ScP5VRqC2032KTi9CqUqTj+y58oDxgjnm06vr5d8Xkmm
nR2xhUecGkzFYlDoXo1w8XttMUefyHS6HWLXvu94V7Y/8YB4lBCEnwFnhgkYB9CG
RsleiOiZDsaHhnNQsnM+Xl1UJVxJlMStl+Av2rCTAj/LMHniXQ+9QKI/7pNDUeCL
qSdxZephYkeRF8C/i9R5G/gAL40kUFz0sgyXuv/kss3rrxsshKKTRbxnRm1k/J73
9ZiztVOeqpcxFxmf7Q==
-----END CERTIFICATE-----
]]

    local key_v1 = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCmZSX7snzN5Z04
fpqI3BFI5wV49PG4DJiwAR7BW0EIAS8tUbFC2uxW93pSiwR3Ro79DPeG9XfbBjMj
RnOMYZ/LSUILH1gHTlLJhj4qkPB7+iwx/hG0FL+M3V1VftOJFDcqyeAwVJenZoLo
ikjmeAXQ9L+japvCRTX0UIQsToblacB+eJRp/tcTCuECQwBzMmi+o67gECEEKiWv
txArsJArpU0SFAHMz83+EaYieI9sLuROOrKiFagsY9P7FAB7xYHf3NsgeX7EQOgY
BhpojwjtOVxBbAI4jF2b7DrsJCYL8XIZNfl8+gr3p2u6yHPC8AqmFCulDBPkzFMO
+gT3GBuFAgMBAAECggEAD5uyVetWuKuetVNu5IKcHnYJNeDoIacQ1YWtYF7SeVE/
HyWoFojZnYjGUSLYLuYP+J20RFUXQpTQzDDKGvN3XUbIaqmshLbsnhm5EB4baM29
Qo0+FOHTW//RxvjIF/Ys/JcGMBJnTV0Yz35VO0Ur6n9i0I3qAW2jk4DP/SX6kl9T
4iJj2Y+69y0bHjesfO71nCUUH6Ym2CHJRd6A4tCeYQr3U/CXOWggpUuPTXFWptt7
uSJjbTQgwUF5H83ih1CUdto1G5LPBUXVD5x2XZshgwZsL1au9kH2l/83BAHKK8io
LQ8FekLN6FLD83mvEwFPyrVhfipbeUz3bKrgEzvOmwKBgQDUbrAgRYCLxxpmguiN
0aPV85xc+VPL+dh865QHhJ0pH/f3fah/U7van/ayfG45aIA+DI7qohGzf03xFnO4
O51RHcRhnjDbXWY5l0ZpOIpvHLLCm8gqIAkX9bt7UyE+PxRSNvUt3kVFT3ZYnYCx
Wb1kiV1oRAzTf1l0X0qamFPqdwKBgQDIhV8OWTBrsuC0U3hmvNB+DPEHnyPWBHvI
+HMflas5gJiZ+3KvrS3vBOXFB3qfTD1LQwUPqeqY0Q41Svvsq2IQAkKedJDdMuPU
RoKaV/Qln85nmibscNcwVGQNUKTeSCJQ43ktrWT01UinamsSEOYTceMqwW10LDaF
Ff1MbKNs4wKBgQDMEPiIR7vQipdF2oNjmPt1z+tpNOnWjE/20KcHAdGna9pcmQ2A
IwPWZMwrcXTBGS34bT/tDXtLnwNUkWjglgPtpFa+H6R3ViWZNUSiV3pEeqEOaW/D
Z7rUlW5gbd8FWLtAryKfyWFpz4e0YLj7pWVWas6cFqLrmO5p6BBWqfYSyQKBgHyp
rjcVa+0JAHobircUm+pB0XeTkIv1rZ98FtaEDjdpo3XXxa1CVVRMDy03QRzYISMx
P2xFjvwCvHqVa5nv0r9xKEmq3oUmpk3KqFecZsUdXQ074QcOADqjvLAqetVWsz7m
rOeg7SrpjonGt1o7904Pd9OU/Z9D/YEv8pIY2GFRAoGASEf3+igRFSECUxLh9LZC
scAxCHh9sz15swDD/rdtEqLKGcxlu74YKkBnyQ/yWA4d/enPnvdP98ThXdXnX0X4
v1HSCliKZXW8cusnBRD2IOyxuIUV/qiMfARylMvlLBccgJR8+olH9f/yF2EFWhoy
125zQzr/ESlTL+5IWeNf2sM=
-----END PRIVATE KEY-----
]]

    -- 新版本证书（CN=localhost2）
    local cert_v2 = [[-----BEGIN CERTIFICATE-----
MIIDCzCCAfOgAwIBAgIUNM6HmOKmFaJkmLlF4P0l/xzct70wDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKbG9jYWxob3N0MjAeFw0yNTEwMDkwOTQ3NDNaFw0zNTEw
MDcwOTQ3NDNaMBUxEzARBgNVBAMMCmxvY2FsaG9zdDIwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDBrp7hSCfkAacYHDhLdhw5QJGNaYABM197uh2l9DDB
+3PBXCDlE3jt2fcu+sxcApYQrxNsl7xjf9+N1cEaYQdzxMb4k4Do7Q0b7nDbFZVy
qFSZ8qPdGFf+kzYWsjNnQp4FWjRWxFrgLOXIBjSH6LvLkDvBez7D+CvB3dpm3Y7+
7daofyq7kcjM6efuYg0OemHz1sh/6ruKtMPgO8v47vcNRQXliScJRFGOeuv02Rxg
LK6LoB+PZitVYuYjJwO9WDnQTPRUYEF9VTu7AWVqkGPKZ9404m+SIyfOZqpQlHPW
gxxV0v7Hf26bmTTwq08Y7AxJQ9GcHjOuAlj2envzlzHHAgMBAAGjUzBRMB0GA1Ud
DgQWBBRo5n9FzjMGPciEl4w59X43Rjp7yjAfBgNVHSMEGDAWgBRo5n9FzjMGPciE
l4w59X43Rjp7yjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCx
AZGPtv8dDUqBBtsg4lyZ4fW6LGQgPnPy22YyBEEbcDcl52fQryz1+KqLH125PePF
/CYhXZzRvzm3MpqD8Tcn3GKH8OKzpu0rursFEnK+vfbzLxK65u04rTZXRa1iODSK
Z+/nk64HbrQGq+9RnMNr8qW0QjLRGxajMTU1Z4/87oGmRYwuViHNE5vs6LE+U30w
h22oN5ZhgpZ0hOCKhVHMrYe8lCHkdN14BktdoVDbyZZczhlW6D0WRerRYJcDmAOc
ae/yNoyHweiGsnfX6sK5xWWPwMhI9DyOzKfLTZlXszrygyC5Krt9QJGZyGvwIUIw
dzJJDoKUFQzV+u/yU4OO
-----END CERTIFICATE-----
]]

    local key_v2 = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDBrp7hSCfkAacY
HDhLdhw5QJGNaYABM197uh2l9DDB+3PBXCDlE3jt2fcu+sxcApYQrxNsl7xjf9+N
1cEaYQdzxMb4k4Do7Q0b7nDbFZVyqFSZ8qPdGFf+kzYWsjNnQp4FWjRWxFrgLOXI
BjSH6LvLkDvBez7D+CvB3dpm3Y7+7daofyq7kcjM6efuYg0OemHz1sh/6ruKtMPg
O8v47vcNRQXliScJRFGOeuv02RxgLK6LoB+PZitVYuYjJwO9WDnQTPRUYEF9VTu7
AWVqkGPKZ9404m+SIyfOZqpQlHPWgxxV0v7Hf26bmTTwq08Y7AxJQ9GcHjOuAlj2
envzlzHHAgMBAAECggEAOw5SlaCZwTUbzQc1xxShcHeWqgbEKBmRALn0Nljp0Qwp
9Ihx40d3tRaj/ygrzdZgCYBIrPDrWW9xK99EfRWe3xbeEIdxZBR7zct7j+HZ6tcW
zMYmXtEAa7hZYrw9Xjv60Oj7UoWWrAokmkQCGnrFYEF/ZvR8Y+a0+Oz7nifqZSJ5
GLCIQX8jIQdl0P8As1KqbSJA1ZIsB/RVKvYN9sOj4Y2GeHZJ7SAyI5NV0an59S5X
IduHPx9kU496AEXyd1c4Ps0Ucytk5bfU2KDvVp9y3JSU8Te0z8+bQWBkcORDehmB
1f5CI/DU1QzZl2LhisO+Nw8bud4bNWOvmky6Ruk0mQKBgQD/57rDEl4g/9l7rpfn
QG8lRLQLEJN+lSbj62t/bTGMb2EANCMmcrplI96tsKr8UI9FsA7kgyQypwIig+my
0X2lbhe2Z4IgBNxqdmJx87p2Uu5ZHWNjoSBIAWqdpP36joSeek0bLNvEDbwBUJZ2
U5rh20ALcsvYG27MYGkmsFZ4GwKBgQDBwP1gKoxc5MU2TCeK/nBRdAE229lTMoD1
uyYlTvUSTw9jBTxpxd+ZbjD4/Cw77DOm1ZA3nnkXRjCGIgoTbOOd2cFJjepWsspj
1N/TZ3pmgOxmuEB3DzoMxGSZ+8mpTfoccy1Wp/aHq+9vp3RXDV/pTT2HP1iEzfGB
G5qr1JyfxQKBgCN8fumOIn9w+zerfmUTClagsFbYdZuYE0yH2OBSxAw1Zb4hfL5Y
KoDb+IUdepiCk1uWjnohtWNQxXsDz+R8KHBIVAF3WRQXmHkq8Xvb0H+YAHVbHe0y
6scRazdxKccU/E79prOeBNurC+cixbqi3Vd0j+0Gfj35j+PHes1ippsBAoGAYo4A
VEJQU5AqoIvsMU9rYoNXesgpq6As6NHhfWjEUCPW989aA5ObQThDwOLEvVZQj7Ri
P2hkv+n8FL6L0YW54jk5kGiXorIfMNi/YZFpOWqq1TUz1Vvxcz0SzyC8W1pGtuH/
VezqAej7ShgrnXw4JTwc6AbYx/TZu4qHCpCDeuECgYEArkANYWWzmuUUgJ6Ozdk5
yqCwaMU2D/FgwCojunc+AorOVe8mG935NbQsCsk1CVYJAoKgYsr3gJNGQVD84pXz
iiGTFMMf2FOAZkUSzsbWOVyD02zaO8nPHzFI5/EUHRiI5v0ucxG2uEUCYFWQqs21
2THXCcOrfT8C487VGOFIGYw=
-----END PRIVATE KEY-----
]]

    -- 启动服务器
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{cert = cert_v1, key = key_v1}},
        disp = function(fd, addr)
            wg:fork(function()
                tls.write(fd, "HTTP/1.1 200 OK\r\n\r\nHello!\n")
                tls.close(fd)
            end)
        end
    }

    print("服务器启动，使用证书 v1 (CN=localhost)")

    -- 注册 SIGUSR1 信号处理器，用于触发证书重载
    signal.register("SIGUSR1", function()
        print("收到 SIGUSR1 信号，重载证书...")
        local ok, err = tls.reload(listenfd, {
            certs = {{cert = cert_v2, key = key_v2}}
        })
        if ok then
            print("证书重载成功 (CN=localhost2)")
        else
            print("证书重载失败:", err)
        end
    end)

    print("发送 SIGUSR1 信号以触发证书重载")
    print("运行: kill -USR1", silly.getpid())

    wg:wait()
end)
```

---

## API 文档

### tls.listen(conf)

启动一个 TLS 服务器在给定地址上进行监听。

- **参数**:
  - `conf`: `table` - 服务器配置表
    - `addr`: `string` (必需) - 监听地址，例如 `"127.0.0.1:8443"` 或 `":8443"`
    - `certs`: `table[]` (必需) - 证书配置列表，每个元素包含：
      - `cert`: `string` - PEM 格式的证书内容
      - `key`: `string` - PEM 格式的私钥内容
    - `backlog`: `integer|nil` (可选) - 等待连接队列的最大长度
    - `disp`: `fun(fd: integer, addr: string)` (必需) - 连接处理器，为每个新连接调用
    - `ciphers`: `string|nil` (可选) - 允许的加密套件，使用 OpenSSL 格式
    - `alpnprotos`: `string[]|nil` (可选) - 支持的 ALPN 协议列表，例如 `{"http/1.1", "h2"}`
- **返回值**:
  - 成功: `integer` - 监听器文件描述符
  - 失败: `nil, string` - nil 和错误信息
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "0.0.0.0:8443",
        certs = {
            {
                cert = "-----BEGIN CERTIFICATE-----\n...",
                key = "-----BEGIN PRIVATE KEY-----\n...",
            }
        },
        alpnprotos = {"http/1.1", "h2"},
        disp = function(fd, addr)
            print("新连接:", addr)
            local alpn = tls.alpnproto(fd)
            print("协商的协议:", alpn or "none")
            tls.close(fd)
        end
    }

    if listenfd then
        print("服务器启动成功")
    end
end)
```

### tls.connect(address [, bind_address] [, hostname] [, alpnprotos])

建立到 TLS 服务器的加密连接（异步）。

- **参数**:
  - `address`: `string` - 服务器地址，例如 `"192.168.1.100:8443"`
  - `bind_address`: `string|nil` (可选) - 用于绑定客户端套接字的本地地址
  - `hostname`: `string|nil` (可选) - 用于 SNI 的主机名
  - `alpnprotos`: `string[]|nil` (可选) - 支持的 ALPN 协议列表
- **返回值**:
  - 成功: `integer` - 连接的文件描述符
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 此函数是异步的，会等待 TLS 握手完成
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local fd, err = tls.connect(
        "93.184.216.34:443",
        nil,
        "www.example.com",
        {"http/1.1", "h2"}
    )

    if not fd then
        print("连接失败:", err)
        return
    end

    print("连接成功, 协议:", tls.alpnproto(fd) or "未协商")
    tls.close(fd)
end)
```

### tls.read(fd, n)

从 TLS 连接精确读取 `n` 个字节（异步）。

- **参数**:
  - `fd`: `integer` - 文件描述符
  - `n`: `integer` - 要读取的字节数
- **返回值**:
  - 成功: `string` - 包含 `n` 字节的字符串
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 如果数据不足，会挂起协程直到数据到达
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        disp = function(fd, addr)
            local data, err = tls.read(fd, 100)
            if data then
                print("读取到 100 字节")
            else
                print("读取失败:", err)
            end
            tls.close(fd)
        end
    }
end)
```

### tls.readline(fd)

从 TLS 连接读取一行数据，直到遇到换行符 `\n`（异步）。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**:
  - 成功: `string` - 一行文本（包括 `\n`）
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 如果换行符未找到，会挂起协程直到收到完整的行
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        disp = function(fd, addr)
            local line, err = tls.readline(fd)
            if line then
                print("请求行:", line)
                tls.write(fd, "HTTP/1.1 200 OK\r\n\r\nOK\n")
            else
                print("读取失败:", err)
            end
            tls.close(fd)
        end
    }
end)
```

### tls.readall(fd)

读取 TLS 连接接收缓冲区中当前可用的所有数据。此函数**不是**异步的，会立即返回。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**:
  - 成功: `string` - 包含可用数据的字符串
  - 失败: `nil, string` - nil 和错误信息
- **非异步**: 立即返回，不会挂起协程
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        disp = function(fd, addr)
            local data, err = tls.readall(fd)
            if data then
                print("读取到:", #data, "字节")
            else
                print("无数据或错误:", err)
            end
            tls.close(fd)
        end
    }
end)
```

### tls.write(fd, data)

将数据写入 TLS 连接。数据会被加密后发送。

- **参数**:
  - `fd`: `integer` - 文件描述符
  - `data`: `string` - 要发送的数据
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        disp = function(fd, addr)
            local body = "Hello, TLS!"
            local response = string.format(
                "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s",
                #body, body
            )

            local ok, err = tls.write(fd, response)
            if not ok then
                print("写入失败:", err)
            end
            tls.close(fd)
        end
    }
end)
```

### tls.close(fd)

关闭一个 TLS 连接或监听器。

- **参数**:
  - `fd`: `integer` - 要关闭的套接字文件描述符
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        disp = function(fd, addr)
            tls.write(fd, "Goodbye!\n")
            local ok, err = tls.close(fd)
            if not ok then
                print("关闭失败:", err)
            end
        end
    }
end)
```

### tls.reload(fd [, conf])

热重载 TLS 服务器的证书配置，无需重启服务。

- **参数**:
  - `fd`: `integer` - 监听器文件描述符
  - `conf`: `table|nil` (可选) - 新的配置
    - `certs`: `table[]` - 新的证书配置
    - `ciphers`: `string` - 新的加密套件
    - `alpnprotos`: `string[]` - 新的 ALPN 协议列表
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        disp = function(fd, addr)
            tls.close(fd)
        end
    }

    -- 重新加载证书
    local ok, err = tls.reload(listenfd, {
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n... new ...",
            key = "-----BEGIN PRIVATE KEY-----\n... new ...",
        }}
    })

    if ok then
        print("证书重载成功")
    else
        print("证书重载失败:", err)
    end
end)
```

### tls.isalive(fd)

检查 TLS 连接是否仍然活动。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**: `boolean` - 连接活动返回 `true`，否则返回 `false`
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        disp = function(fd, addr)
            if tls.isalive(fd) then
                print("连接活动中")
                tls.write(fd, "Status: OK\n")
            else
                print("连接已断开")
            end
            tls.close(fd)
        end
    }
end)
```

### tls.alpnproto(fd)

获取通过 ALPN 协商的协议。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**: `string|nil` - 协商的协议（如 `"http/1.1"`, `"h2"`），未协商则返回 `nil`
- **示例**:

```lua validate
local silly = require "silly"
local tls = require "silly.net.tls"

silly.fork(function()
    local listenfd = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        alpnprotos = {"http/1.1", "h2"},
        disp = function(fd, addr)
            local proto = tls.alpnproto(fd)
            if proto == "h2" then
                print("使用 HTTP/2")
            elseif proto == "http/1.1" then
                print("使用 HTTP/1.1")
            else
                print("未协商 ALPN")
            end
            tls.close(fd)
        end
    }
end)
```

---

## 注意事项

### 证书管理

1. **证书格式**: 必须使用 PEM 格式的证书和私钥
2. **证书验证**: 客户端默认会验证服务器证书，自签名证书会导致验证失败
3. **SNI 支持**: 客户端连接时建议提供 hostname 参数以支持 SNI
4. **证书链**: 如果使用中间 CA，需要将完整证书链放入 cert 字段

### 性能考虑

1. **加密开销**: TLS 加密会增加 CPU 使用，性能约为普通 TCP 的 60-80%
2. **握手延迟**: TLS 握手需要额外的往返时间（RTT）
3. **连接复用**: 对于高频通信，应尽可能复用 TLS 连接
4. **协议选择**: HTTP/2 (h2) 使用多路复用，可以减少连接数

### 安全建议

1. **密钥保护**: 私钥文件应设置严格的访问权限（如 `chmod 600`）
2. **加密套件**: 生产环境建议配置 `ciphers` 参数，禁用不安全的加密算法
3. **证书更新**: 使用 `tls.reload()` 定期更新证书，避免证书过期
4. **ALPN 协商**: 使用 `alpnprotos` 明确支持的协议，避免协议降级攻击

### 常见错误

**错误**: "socket closed" 或 "handshake failed"
- **原因**: 证书配置错误、客户端不信任证书、加密套件不匹配
- **解决**: 检查证书格式、使用正确的 CA 证书、配置兼容的加密套件

**错误**: "certificate verify failed"
- **原因**: 客户端无法验证服务器证书
- **解决**: 使用受信任的 CA 证书，或在测试环境使用 `--insecure` 选项

### 编译要求

TLS 模块需要 OpenSSL 支持。编译时需要启用 OpenSSL：

```bash
make OPENSSL=ON
```

如果未启用 OpenSSL，`require "silly.net.tls"` 会失败。

## 参见

- [silly](../silly.md) - 核心调度器
- [silly.net.tcp](./tcp.md) - TCP 协议支持
- [silly.net.udp](./udp.md) - UDP 协议支持
- [silly.net.dns](./dns.md) - DNS 解析器
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
