---
title: 'Nginx $request_length 为什么会变成负数？一次流量统计异常的源码排查'
date: 2026-11-06
slug: nginx-request-length-negative
translationKey: nginx-request-length-negative
draft: false
description: '从线上入站流量异常出发，分析 Nginx 请求长度为什么会少计甚至变成负数，结合 HTTP/1.1 Pipelining、源码和 Python 脚本还原问题。'
summary: '一次入站流量异常，最终定位到 Nginx 丢弃请求体时漏记字节，叠加 HTTP/1.1 Pipelining 的预读字节扣减，使 $request_length 变成负数。'
tags: ['Nginx', 'OpenResty', 'HTTP', 'Source Analysis', 'Troubleshooting']
categories: ['Nginx']
---

线上有一次流量统计异常：某个域名的入站流量突然出现接近 `2^64` 的数字。

第一反应是流量统计模块算错了。但继续检查 Nginx 的访问日志后，我发现了更奇怪的现象：**部分 PUT 请求的 `$request_length` 居然是负数。**

一次 HTTP 请求实际占用的字节数不可能小于 0。沿着 Nginx 源码追查，最终定位到 **丢弃请求体时漏记字节** 的问题。而在 HTTP/1.1 Pipelining 场景下，另一处正常的减法操作又把这个错误进一步放大。

我把复现脚本和本地修复方案提交到了 [Nginx 官方 Issue #1546](https://github.com/nginx/nginx/issues/1546)，维护人员也确认了本地复现。

这篇文章从现象开始，逐步解释涉及的 HTTP 概念和 Nginx 源码。即使没有读过 Nginx 源码，也能理解整个定位过程。

## 1. 线上现象：入站流量突然变成一个天文数字

业务监控最早发现的是入站流量异常。在故障时间段，采样数据出现了如下变化：

| 时间 | 采样值（字节） |
| --- | ---: |
| 2026-07-02 00:41:47 | `5480` |
| 2026-07-02 00:42:47 | `1900` |
| 2026-07-02 00:43:47 | `1.84467E+19` |

`1.84467E+19` 是电子表格的科学计数法，约等于 **1844 亿亿字节**。这个值明显不符合正常业务流量。

于是我绕过监控展示层，直接查看底层流量统计接口，得到下面的值（只保留与本文有关的字段）：

```json
{
  "a.com": {
    "inBytes": 18446744073709550309,
    "sslInBytes": 18446744073709550309
  }
}
```

这里的 `inBytes` 和 `sslInBytes` 分别是入站字节计数及 HTTPS 入站字节计数。重要的是：**异常数字已经存在于底层统计结果中，不是电子表格显示错误。**

### 为什么这个数字值得注意？

计算一下：

```text
2^64                 = 18446744073709551616
实际 inBytes         = 18446744073709550309
差值                 =                1307

即：18446744073709550309 = 2^64 - 1307
```

这让我把排查方向转向了**有符号整数与无符号整数的转换**。

先解释两个概念：

- **有符号整数（signed）**：能表示正数和负数，例如 `100`、`-8`。
- **无符号整数（unsigned）**：只表示非负整数。一个 64 位无符号整数的取值范围是 `0` 到 `2^64 - 1`。

当负数参与 64 位无符号运算时，会按 `2^64` 取模。例如：

```text
-8 以 uint64_t 的值表示
= 2^64 - 8
= 18446744073709551608
```

因此，一个本来很小的负数，就能在无符号计数中表现为接近 `2^64` 的大正数。

**这里的关键结论不是服务器真的收到了这么多流量，而是流量计数的数据来源已经出现了错误。**

## 2. 顺着统计数据，找到 Nginx 的 `request_length`

接下来要回答一个问题：流量统计模块从哪里获取请求的入站字节数？

追踪统计更新代码后，我找到它使用的 Nginx 请求字段：

```c
r->request_length
```

`r` 是当前 HTTP 请求对应的 `ngx_http_request_t` 对象。`request_length` 保存 Nginx 记录的请求长度。

Nginx 还提供了一个可直接写入访问日志的内置变量：

```nginx
$request_length
```

它的含义在 [Nginx 官方文档](https://nginx.org/en/docs/http/ngx_http_log_module.html) 中有明确说明：**HTTP 请求行、请求头、请求体的总字节数。**

例如，客户端发送一个请求：

```http
PUT /upload HTTP/1.1
Host: example.com
Content-Length: 5

hello
```

这里 `hello` 是 5 字节请求体。`$request_length` 记录的不只是这 5 字节，还包括前面的请求行、请求头以及协议中的换行字节。

Nginx 输出这个日志变量时，核心代码是：

```c
/* src/http/ngx_http_variables.c */
v->len = ngx_sprintf(p, "%O", r->request_length) - p;
```

也就是说：**访问日志里的 `$request_length`，直接来自 `r->request_length`。**

因此，下一步直接检查访问日志中的 `$request_length`，确认这个源字段的真实取值。

## 3. 访问日志：`$request_length` 确实出现负数

筛选故障时间段的 PUT 请求，发现了以下记录（仅摘取 `$request_length` 字段）：

```text
request_length: 477
request_length: -1934
request_length: 510
request_length: -1770
request_length: -8
request_length: -8
request_length: -7
```

这里可以确定两点：

1. **负数已经出现在 Nginx 自带的 `$request_length` 中。**
2. **流量统计模块不是负数的产生位置，它只是使用了这个异常的请求长度。**

问题已经从“流量模块算错了多少字节”，变成了一个更具体的源码问题：

> Nginx 在什么地方修改 `r->request_length`，又为什么会把它减成负数？

## 4. 源码排查：找到一条减法语句

### 4.1 从所有写入位置开始搜索

先在 Nginx 源码根目录执行：


```bash
grep -RnF 'r->request_length +=' src/http
grep -RnF 'r->request_length -=' src/http
```

Nginx 在读取请求头、请求体时会增加这个字段。其中最引起我注意的是一条减法，位于：

```text
src/http/ngx_http_request_body.c
```

函数名是：

```c
ngx_http_copy_pipelined_header()
```

其中的关键代码如下（省略了缓冲区检查和错误处理）：

```c
n = buf->last - buf->pos;

/* 保存已经读到的下一条 HTTP 请求数据 */
ngx_memcpy(b->last, buf->pos, n);
b->last += n;

/* 从当前请求长度中扣除这些字节 */
r->request_length -= n;
```

这条减法看起来很可疑。但结合 HTTP/1.1 Pipelining 的处理逻辑，就能发现：**这条减法本身是合理的。**

### 4.2 什么是 HTTP/1.1 Pipelining？

先看普通 HTTP/1.1 Keep-Alive。客户端在同一条 TCP 连接上复用多个请求，通常是先发 A、等到 A 的响应，再发 B：

```text
客户端                         Nginx
   | ---- 请求 A ------------> |
   | <--- 响应 A ------------- |
   | ---- 请求 B ------------> |
   | <--- 响应 B ------------- |
```

Pipelining 的区别在于：**客户端不用等待 A 的响应，就继续发送 B。**

```text
客户端                         Nginx
   | ---- 请求 A ------------> |
   | ---- 请求 B ------------> |
   | <--- 响应 A ------------- |
   | <--- 响应 B ------------- |
```

因此，同一次从 TCP 连接读取的数据里，可以同时包含两个 HTTP 请求的内容：

```text
一次读取到的 TCP 数据：

[请求 A 的剩余 body][请求 B 的请求头][请求 B 的 body ...]
```

Nginx 处理请求 A 时，必须把属于请求 B 的字节留给下一个请求。

这就是 `ngx_http_copy_pipelined_header()` 的作用：

1. 把已经预读到的下一条请求数据保存起来。
2. 从当前请求 A 的 `request_length` 中扣除这些不属于 A 的字节。

所以 `r->request_length -= n` **不能简单删除**。真正的问题，是它执行之前，请求体字节有没有被完整加进 `request_length`。

## 5. 真正的原因：丢弃请求体时少记了字节

### 5.1 什么是“丢弃请求体”？

并不是所有 HTTP 请求都会把 body 交给后端。

例如，网关收到 PUT 请求后，直接返回 `200`：

```nginx
location / {
    return 200 ok;
}
```

即使客户端发送了请求体，Nginx 也不需要把它传给后端。不过，为了在保持连接时正确找到下一条 HTTP 请求的起点，Nginx 需要处理并跳过当前请求尚未消费的 body。

这条处理路径叫 **discard request body（丢弃请求体）**。

“丢弃”不表示客户端没有发送这些字节，而表示 Nginx 接收、识别并跳过它们，不把它们交给业务处理。

### 5.2 正常读取 body 会增加 `request_length`

在正常读取请求体时，源码会把读到的字节加进总长度。

例如：

```c
/* src/http/ngx_http_request_body.c：关键语句 */
r->request_length += n;
```

这里的 `n` 是此次读取的字节数。每读取一段，就把相应字节记录下来。

### 5.3 丢弃 body 的路径却漏掉了加法

沿着丢弃请求体的代码继续看：

```text
ngx_http_discard_request_body()
    |
    +-- ngx_http_discard_request_body_filter()
    |      处理已经预读的请求体数据
    |
    +-- ngx_http_read_discarded_request_body()
           |
           +-- recv() 读取更多数据
           +-- ngx_http_discard_request_body_filter()
           +-- ngx_http_copy_pipelined_header()
                  |
                  +-- r->request_length -= n
```

在本次问题所对应的源码版本中，`ngx_http_read_discarded_request_body()` 处理新读入的数据时，没有执行与正常读取路径相对应的 `r->request_length += n`。

关键处理代码是：

```c
/* 丢弃请求体路径：省略无关分支 */
b.pos = buffer;
b.last = buffer + n;

rc = ngx_http_discard_request_body_filter(r, &b);

if (ngx_http_copy_pipelined_header(r, &b) != NGX_OK) {
    return NGX_HTTP_INTERNAL_SERVER_ERROR;
}
```

这就出现了不平衡的字节记账：

```text
正常读取请求体：
读取 body -> request_length 增加

丢弃请求体（问题版本）：
读取并丢弃 body -> request_length 没有相应增加

遇到 Pipelining：
发现下一条请求的数据 -> request_length 继续扣减
```

用一个简化的数字例子就能看懂：

```text
已经记录的请求头长度                 510 字节
读入并丢弃一部分 body，但漏记             +0 字节
扣除预读到的下一条请求数据             -600 字节
------------------------------------------------
最终 request_length                   -90 字节
```


这也解释了为什么问题有两种表现：

- **单个请求**：丢弃的 body 没有完整计入，请求长度偏小。
- **Pipelining 请求**：在前面漏计的基础上，又扣减下一请求的预读字节，请求长度进一步变成负数。

## 6. 最小复现：不依赖业务模块

为了确认问题发生在 Nginx 本身，我使用原生 Nginx 配置和 Python socket 构造请求。

这套复现只依赖 **Nginx + Python 3**，不需要流量统计模块，也不需要业务 Lua 代码。

我最早在 `nginx 1.19.3` 观察到问题，随后使用 `nginx 1.31.3` 再次复现，相关信息已记录在官方 Issue 中。

### 6.1 Nginx 配置

创建一个独立的测试配置 `nginx.conf`：

```nginx
worker_processes 1;

events {
    worker_connections 1024;
}

http {
    default_type text/plain;

    log_format main '$remote_addr [$time_local] "$request" '
                    'request_length:$request_length';
    access_log logs/access.log main;

    server {
        listen 8080;
        server_name localhost;

        location / {
            return 200 ok;
        }
    }
}
```

这里只做两件事：

1. 对请求直接返回 `200`，让 Nginx 处理丢弃请求体的路径。
2. 在访问日志里记录 `$request_length`，方便对比。

### 6.2 Python 构造两个连续的 PUT 请求

将下面的代码保存为 `repro.py`：

```python
#!/usr/bin/env python3
import socket
import time

HOST = "127.0.0.1"
PORT = 8080
HEADER_PAD = "x" * 1024
BODY = b"y" * 8192


def put_header(seq, connection):
    return (
        "PUT / HTTP/1.1\r\n"
        "Host: localhost\r\n"
        f"Connection: {connection}\r\n"
        "Transfer-Encoding: chunked\r\n"
        f"X-Seq: {seq}\r\n"
        f"X-Pad: {HEADER_PAD}\r\n"
        "\r\n"
    ).encode("ascii")


def chunked_body(data=b""):
    if not data:
        return b"0\r\n\r\n"
    return (f"{len(data):x}\r\n".encode("ascii")
            + data + b"\r\n0\r\n\r\n")


def send_request(parts, pause=False):
    with socket.create_connection((HOST, PORT), timeout=3) as sock:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.sendall(parts[0])

        if pause:
            time.sleep(0.05)

        for part in parts[1:]:
            sock.sendall(part)

        sock.settimeout(2)
        while True:
            try:
                if not sock.recv(4096):
                    break
            except socket.timeout:
                break


# 场景一：HTTP/1.1 Pipelining
first = put_header(1, "keep-alive")
second = put_header(2, "close")

# A 的结束标记、B 的请求头、B 的请求体连续发送
send_request([
    first,
    chunked_body() + second + chunked_body(BODY)
], pause=True)

# 场景二：单个 PUT 请求
third = put_header(3, "close")
send_request([third + chunked_body(BODY)])
```

这里有两个小知识点：

- `Transfer-Encoding: chunked` 表示请求体采用分块传输。`0\r\n\r\n` 是结束标记，表示当前请求体已经发送完毕。
- 脚本在同一条 TCP 连接上连续发送请求 A 和请求 B，**不等待 A 的响应**，这就是 Pipelining。

执行脚本后，查看 Nginx 访问日志：

```bash
python3 repro.py
tail -n 10 logs/access.log
```

### 6.3 复现结果

我在提交 Nginx 官方 Issue 时，记录到的实际日志如下：

```text
"PUT / HTTP/1.1" "request_length:-2933"
"PUT / HTTP/1.1" "request_length:1153"
"PUT / HTTP/1.1" "request_length:1153"
```

第一条是 Pipelining 场景下的负数；其余请求也没有完整计入已经发送的请求体字节。

这些数字来自 **Issue 中原始测试脚本的实测记录**。上面的教学版脚本改用了 `8080` 端口，并简化了请求头。

这一步已经把故障从生产环境缩小到了 Nginx 自身的请求体处理逻辑。

## 7. 修复思路：补上丢弃请求体时漏记的字节

修复的重点是让**正常读取请求体**和**丢弃请求体**两条路径都正确维护 `request_length`。

不需要删除 `ngx_http_copy_pipelined_header()` 中的扣减，因为下一条请求的字节本来就不属于当前请求。

在 [Issue #1546](https://github.com/nginx/nginx/issues/1546) 中，我提交了两处本地补丁修改。

### 7.1 统计已经预读、随后被丢弃的 body 字节

修改 `ngx_http_discard_request_body()`：

```c
/* 过滤前：记录缓冲区里原有的字节数 */
preread = r->header_in->last - r->header_in->pos;

rc = ngx_http_discard_request_body_filter(r, r->header_in);
if (rc != NGX_OK) {
    return rc;
}

/* 过滤后：把本次实际消费的字节加入请求长度 */
r->request_length += preread
                   - (r->header_in->last - r->header_in->pos);
```

`preread` 是过滤前的剩余字节数；过滤前后相减，得到真正被当前请求消耗的字节数。

### 7.2 统计从 socket 新读取的 body 字节

修改 `ngx_http_read_discarded_request_body()`：

```c
/* recv() 已成功返回 n 字节 */
b.pos = buffer;
b.last = buffer + n;

r->request_length += n;

rc = ngx_http_discard_request_body_filter(r, &b);
```

现在的逻辑就是：

```text
从 socket 读取 n 字节
       |
       v
request_length += n
       |
       v
处理当前请求的 body
       |
       v
如果读到了下一条请求的数据
       |
       v
request_length -= 下一条请求的预读字节数
```

**先记录读入的字节，再扣除不属于当前请求的部分，计数就完整了。**

以上展示的是关键代码片段。完整补丁上下文可在 [官方 Issue 的 Proposed Fix 部分](https://github.com/nginx/nginx/issues/1546) 查看。我的本地测试表明，补齐这些计数后，请求体长度能够正确统计，Pipelining 复现中的负数也随之消失。


## 8. 总结：根因不是减错了，而是之前漏加了

整个问题可以用一张纯文本流程图概括：

```text
生产环境入站流量数值异常，接近 2^64
                 |
                 v
排查有符号 / 无符号整数转换
                 |
                 v
发现统计数据来自 r->request_length
                 |
                 v
访问日志确认 $request_length 出现负数
                 |
                 v
源码发现：丢弃请求体时漏记 body 字节
                 |
                 +--> 单个请求：长度少计
                 |
                 +--> Pipelining：再扣减下一请求的预读字节
                                   |
                                   v
                           长度变成负数
                                   |
                                   v
                     无符号流量计数出现极大值
```



**真正的 Bug 并不是显眼的 `r->request_length -= n`，而是与它配套的字节增加操作，在丢弃请求体的路径中缺失了。**
