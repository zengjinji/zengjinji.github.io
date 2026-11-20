---
title: 'Why Did Nginx $request_length Become Negative? A Source-Level Investigation into a Traffic Accounting Anomaly'
date: 2026-11-06
slug: nginx-request-length-negative
translationKey: nginx-request-length-negative
draft: false
description: 'Tracing an inbound traffic accounting anomaly to undercounted and negative Nginx request lengths, with HTTP/1.1 pipelining, source code, and a Python reproduction.'
summary: 'Missing byte accounting in the request body discard path, combined with the subtraction of preread HTTP/1.1 pipelined data, caused Nginx $request_length to become negative.'
tags: ['Nginx', 'OpenResty', 'HTTP', 'Source Analysis', 'Troubleshooting']
categories: ['Nginx']
---

During a production incident, the inbound traffic counter for one domain suddenly jumped to a value close to `2^64`.

My first reaction was that the traffic accounting module had made a calculation error. After checking the Nginx access logs, however, I found something even stranger: **some PUT requests had a negative `$request_length`.**

The actual number of bytes in an HTTP request cannot be less than zero. Following the Nginx source code eventually led me to **missing byte accounting when discarding request bodies**. Under HTTP/1.1 pipelining, an otherwise valid subtraction elsewhere in the code made the error worse.

I submitted a reproduction script and a local fix to [Nginx issue #1546](https://github.com/nginx/nginx/issues/1546), where a maintainer also confirmed that the problem was locally reproducible.

This article starts with the symptoms and walks through the relevant HTTP concepts and Nginx source code. You do not need prior experience reading Nginx source code to follow the investigation.

## 1. The production symptom: an astronomical inbound traffic count

Our monitoring first detected an anomaly in inbound traffic. During the incident, sampled values changed as follows:

| Time | Sampled value (bytes) |
| --- | ---: |
| 2026-07-02 00:41:47 | `5480` |
| 2026-07-02 00:42:47 | `1900` |
| 2026-07-02 00:43:47 | `1.84467E+19` |

`1.84467E+19` is a spreadsheet's scientific notation for approximately **18.4 quintillion bytes**. This was clearly inconsistent with normal traffic.

I bypassed the monitoring presentation layer and queried the underlying traffic statistics interface directly. It returned the following values, with only the relevant fields shown:

```json
{
  "a.com": {
    "inBytes": 18446744073709550309,
    "sslInBytes": 18446744073709550309
  }
}
```

Here, `inBytes` and `sslInBytes` are the inbound byte counter and the HTTPS inbound byte counter, respectively. The key observation was that **the abnormal number was already present in the underlying statistics; it was not a spreadsheet display error.**

### Why was this particular number significant?

Consider the arithmetic:

```text
2^64                 = 18446744073709551616
Actual inBytes       = 18446744073709550309
Difference           =                1307

In other words: 18446744073709550309 = 2^64 - 1307
```

This shifted my attention to **conversions between signed and unsigned integers**.

Two definitions are useful here:

- **Signed integers** can represent both positive and negative numbers, such as `100` and `-8`.
- **Unsigned integers** represent only nonnegative numbers. A 64-bit unsigned integer ranges from `0` to `2^64 - 1`.

When a negative integer is converted to a 64-bit unsigned integer, the result is reduced modulo `2^64`. For example:

```text
-8 represented as a uint64_t value
= 2^64 - 8
= 18446744073709551608
```

A small negative number can therefore appear as a huge positive number close to `2^64` in an unsigned counter.

**The server had not actually received that much traffic. The value feeding the traffic counter was already wrong.**

## 2. Following the statistics back to Nginx request_length

The next question was where the traffic accounting module obtained the inbound byte count for each request.

Tracing the counter update code led to this Nginx request field:

```c
r->request_length
```

`r` is the `ngx_http_request_t` object for the current HTTP request. Its `request_length` field holds the request length recorded by Nginx.

Nginx also exposes a built-in variable that can be written directly to access logs:

```nginx
$request_length
```

The [official Nginx documentation](https://nginx.org/en/docs/http/ngx_http_log_module.html) defines this as **the total request length, including the request line, headers, and request body**.

For example, suppose a client sends:

```http
PUT /upload HTTP/1.1
Host: example.com
Content-Length: 5

hello
```

The body, `hello`, is five bytes long. `$request_length` includes those five bytes as well as the preceding request line, headers, and protocol line endings.

The core code that formats this log variable is:

```c
/* src/http/ngx_http_variables.c */
v->len = ngx_sprintf(p, "%O", r->request_length) - p;
```

In other words, **the `$request_length` written to the access log comes directly from `r->request_length`.**

The next step was to inspect `$request_length` in the access logs and check the actual value of this source field.

## 3. The access logs confirmed negative request lengths

Filtering PUT requests during the incident revealed the following values, showing only the `$request_length` field:

```text
request_length: 477
request_length: -1934
request_length: 510
request_length: -1770
request_length: -8
request_length: -8
request_length: -7
```

This established two things:

1. **Negative values were already present in Nginx's built-in `$request_length` variable.**
2. **The traffic accounting module did not generate those negative values; it consumed an already incorrect request length.**

The investigation had moved from a vague traffic accounting error to a specific source-code question:

> Where does Nginx modify `r->request_length`, and how could it subtract enough to make the value negative?

## 4. Investigating the source: a subtraction statement

### 4.1 Start with every place that updates the field

From the Nginx source root, I searched for:

```bash
grep -RnF 'r->request_length +=' src/http
grep -RnF 'r->request_length -=' src/http
```

Nginx increases this field when reading request headers and bodies. One subtraction was especially interesting. It was in:

```text
src/http/ngx_http_request_body.c
```

The function was:

```c
ngx_http_copy_pipelined_header()
```

Its key operations were as follows, with buffer checks and error handling omitted:

```c
n = buf->last - buf->pos;

/* Save data already read for the next HTTP request. */
ngx_memcpy(b->last, buf->pos, n);
b->last += n;

/* Exclude those bytes from the current request length. */
r->request_length -= n;
```

This subtraction initially looked suspicious. Once we consider HTTP/1.1 pipelining, however, **the subtraction itself makes sense**.

### 4.2 What is HTTP/1.1 pipelining?

First consider ordinary HTTP/1.1 keep-alive. A client reuses a TCP connection for multiple requests, commonly sending A, waiting for its response, and then sending B:

```text
Client                          Nginx
   | ---- Request A -----------> |
   | <--- Response A ----------- |
   | ---- Request B -----------> |
   | <--- Response B ----------- |
```

With pipelining, **the client sends B without waiting for A's response**:

```text
Client                          Nginx
   | ---- Request A -----------> |
   | ---- Request B -----------> |
   | <--- Response A ----------- |
   | <--- Response B ----------- |
```

As a result, a single read from the TCP connection can contain data from two HTTP requests:

```text
TCP data returned by one read:

[Remaining body of A][Request headers of B][Body of B ...]
```

While handling request A, Nginx must preserve the bytes belonging to B for the next request.

That is what `ngx_http_copy_pipelined_header()` does:

1. Save the data already read for the next request.
2. Subtract those bytes from request A's `request_length`, because they do not belong to A.

We therefore **cannot simply remove** `r->request_length -= n`. The real question is whether all the bytes read for the body have been added to `request_length` before this subtraction occurs.

## 5. The root cause: missing byte accounting when discarding a request body

### 5.1 What does discarding a request body mean?

Not every HTTP request body is forwarded to a backend.

For example, a gateway might immediately return `200` for a PUT request:

```nginx
location / {
    return 200 ok;
}
```

Even if the client sends a body, Nginx does not need to forward it. To find the start of the next HTTP request correctly on a persistent connection, however, Nginx needs to process and skip the unconsumed body of the current request.

This is the **discard request body** path.

Discarding does not mean that the client never sent those bytes. It means Nginx receives, identifies, and skips them without passing them to the application.

### 5.2 Normal body reads increase request_length

When reading a request body normally, Nginx adds the bytes read to the total request length. For example:

```c
/* Key statement in src/http/ngx_http_request_body.c. */
r->request_length += n;
```

Here, `n` is the number of bytes returned by that read. Each read adds its bytes to the counter.

### 5.3 The discard path was missing that addition

Following the body discard path gives this call flow:

```text
ngx_http_discard_request_body()
    |
    +-- ngx_http_discard_request_body_filter()
    |      Process body data that has already been preread.
    |
    +-- ngx_http_read_discarded_request_body()
           |
           +-- recv() reads more data.
           +-- ngx_http_discard_request_body_filter()
           +-- ngx_http_copy_pipelined_header()
                  |
                  +-- r->request_length -= n
```

In the source version involved in this incident, `ngx_http_read_discarded_request_body()` processed newly received data without the corresponding `r->request_length += n` found in the normal read path.

The key code was:

```c
/* Request body discard path, with unrelated branches omitted. */
b.pos = buffer;
b.last = buffer + n;

rc = ngx_http_discard_request_body_filter(r, &b);

if (ngx_http_copy_pipelined_header(r, &b) != NGX_OK) {
    return NGX_HTTP_INTERNAL_SERVER_ERROR;
}
```

The byte accounting was therefore unbalanced:

```text
Normal request body reads:
Read body -> request_length increases.

Body discard path in the affected version:
Read and discard body -> no corresponding increase in request_length.

With pipelining:
Find data for the next request -> subtract from request_length.
```

A simplified numerical example makes the problem clear:

```text
Request headers already accounted for                  510 bytes
Read and discard some body data, but omit the addition   +0 bytes
Subtract preread data belonging to the next request    -600 bytes
---------------------------------------------------------------
Final request_length                                   -90 bytes
```

This explains the two observed symptoms:

- **A single request:** discarded body bytes are not fully counted, so the recorded request length is too small.
- **Pipelined requests:** subtracting preread data for the next request on top of the earlier undercount can make the recorded length negative.

## 6. A minimal reproduction without application modules

To confirm that the problem was in Nginx itself, I used a plain Nginx configuration and Python sockets to construct the requests.

The reproduction requires only **Nginx and Python 3**. It does not depend on the traffic accounting module or any application Lua code.

I first observed the problem on `nginx 1.19.3` and later reproduced it on `nginx 1.31.3`. These details are recorded in the official issue.

### 6.1 Nginx configuration

Create a separate test configuration named `nginx.conf`:

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

This configuration does two things:

1. Return `200` immediately so that Nginx takes the body discard path.
2. Include `$request_length` in the access log for comparison.

### 6.2 Construct two consecutive PUT requests in Python

Save the following as `repro.py`:

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


# Scenario 1: HTTP/1.1 pipelining.
first = put_header(1, "keep-alive")
second = put_header(2, "close")

# Send A's terminator, B's headers, and B's body consecutively.
send_request([
    first,
    chunked_body() + second + chunked_body(BODY)
], pause=True)

# Scenario 2: a single PUT request.
third = put_header(3, "close")
send_request([third + chunked_body(BODY)])
```

Two details are useful to understand:

- `Transfer-Encoding: chunked` means the body uses chunked transfer coding. The `0\r\n\r\n` terminator indicates that the current request body is complete.
- The script sends requests A and B consecutively on the same TCP connection, **without waiting for A's response**. That is pipelining.

Run the script and inspect the Nginx access log:

```bash
python3 repro.py
tail -n 10 logs/access.log
```

### 6.3 Reproduction results

When I submitted the official Nginx issue, I recorded these actual log entries:

```text
"PUT / HTTP/1.1" "request_length:-2933"
"PUT / HTTP/1.1" "request_length:1153"
"PUT / HTTP/1.1" "request_length:1153"
```

The first entry shows a negative value in the pipelining case. The other requests also fail to account for the full body that was sent.

These numbers are **measurements from the original test script in the issue**. The teaching version above uses port `8080` and simplifies the request headers.

At this point, the production incident had been reduced to Nginx's own request body handling logic.

## 7. The fix: account for the missing bytes in the body discard path

The fix is to maintain `request_length` correctly in both the **normal request body read path** and the **body discard path**.

There is no need to remove the subtraction in `ngx_http_copy_pipelined_header()`: bytes belonging to the next request should be excluded from the current request.

In [issue #1546](https://github.com/nginx/nginx/issues/1546), I submitted a local patch with two changes.

### 7.1 Count preread body bytes that are subsequently discarded

Update `ngx_http_discard_request_body()`:

```c
/* Before filtering: record the bytes originally in the buffer. */
preread = r->header_in->last - r->header_in->pos;

rc = ngx_http_discard_request_body_filter(r, r->header_in);
if (rc != NGX_OK) {
    return rc;
}

/* After filtering: add the bytes actually consumed by this request. */
r->request_length += preread
                   - (r->header_in->last - r->header_in->pos);
```

`preread` is the number of bytes remaining before filtering. Subtracting the bytes left afterward gives the number actually consumed by the current request.

### 7.2 Count body bytes newly read from the socket

Update `ngx_http_read_discarded_request_body()`:

```c
/* recv() has successfully returned n bytes. */
b.pos = buffer;
b.last = buffer + n;

r->request_length += n;

rc = ngx_http_discard_request_body_filter(r, &b);
```

The resulting flow is:

```text
Read n bytes from the socket.
       |
       v
request_length += n
       |
       v
Process the current request body.
       |
       v
If data for the next request was also read:
       |
       v
request_length -= preread bytes belonging to the next request
```

**First count the bytes read, then subtract the portion that does not belong to the current request. This balances the accounting.**

These are the key excerpts. The full patch context is available in the [Proposed Fix section of the official issue](https://github.com/nginx/nginx/issues/1546). My local tests showed that, after adding the missing accounting, request body lengths were counted correctly and negative values disappeared from the pipelining reproduction.

## 8. Conclusion: the missing addition was the root cause

The investigation can be summarized in a plain-text flowchart:

```text
Production inbound traffic count is close to 2^64.
                 |
                 v
Investigate signed/unsigned integer conversions.
                 |
                 v
Trace the counter input to r->request_length.
                 |
                 v
Confirm negative $request_length values in access logs.
                 |
                 v
Find missing byte accounting in the body discard path.
                 |
                 +--> Single request: length is undercounted.
                 |
                 +--> Pipelining: subtract preread data for the next request.
                                   |
                                   v
                           Length becomes negative.
                                   |
                                   v
                     Unsigned traffic counter shows a huge value.
```

**The bug was not the conspicuous `r->request_length -= n` statement. It was the missing corresponding addition in the request body discard path.**
