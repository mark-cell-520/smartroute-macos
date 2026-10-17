#!/usr/bin/env python3
"""smartroute 测试用的 HTTP 替身服务。

为什么需要它：tests/mock_fetch.sh 此前全是 grep 源码字符串断言，
没有一次真实 HTTP 交互。结果两个真 bug（重定向响应码、-n 缺值死循环）
都是在"所有断言全绿"的情况下成立的。行为测试必须真打 HTTP。

支持的路径：
  /file/<n>        正常文件，完整支持 Range（206/416）
  /redir/<n>       302 跳转到 /file/<n>（测重定向链）
  /norange/<n>     返回 200 但不认 Range（测退化路径）
  /missing         404
  /empty           0 字节
  /lying           探测时报一个大小、实际返回另一个（测字节校验）

用法: python3 tests/httpstub.py <端口>
"""
import sys
import http.server
import socketserver

BODY = b'A' * 5000


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _send(self, code, headers, body=b''):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD' and body:
            self.wfile.write(body)

    def _range(self):
        r = self.headers.get('Range')
        if not r:
            return None
        try:
            a, b = r.split('=')[1].split('-')
            a = int(a)
            b = int(b) if b else None
        except Exception:
            return None
        return a, b

    def do_GET(self):
        self.do_HEAD()

    def do_HEAD(self):
        p = self.path.split('?')[0]
        if p.startswith('/redir/'):
            # 302 跳到真实文件：测"重定向链上取错状态行"这个 bug
            self.send_response(302)
            self.send_header('Location', '/file/' + p.split('/')[-1])
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if p == '/missing':
            self._send(404, [('Content-Type', 'text/plain')], b'not found')
            return
        if p == '/lying':
            # 探测时（Range 越界）报 1234，实际 GET 返回 5000
            if self._range() is not None:
                self._send(416, [('Content-Range', 'bytes */1234')])
            else:
                self._send(200, [('Content-Type', 'application/octet-stream')], BODY)
            return
        body = BODY
        if p.startswith('/norange'):
            # 不认 Range：不管有没有 Range 头都返回全量 200
            self._send(200, [('Content-Type', 'application/octet-stream')], body)
            return
        if p.startswith('/empty'):
            self._send(200, [('Content-Type', 'application/octet-stream')], b'')
            return
        # /file/<n>：完整支持 Range
        rng = self._range()
        if rng is None:
            self._send(200, [('Content-Type', 'application/octet-stream'),
                             ('Accept-Ranges', 'bytes')], body)
            return
        a, b = rng
        if b is None:
            b = len(body) - 1
        if a >= len(body) or a > b:
            self._send(416, [('Content-Range', 'bytes */%d' % len(body))])
            return
        b = min(b, len(body) - 1)
        chunk = body[a:b + 1]
        self.send_response(206)
        self.send_header('Content-Range', 'bytes %d-%d/%d' % (a, b, len(body)))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(len(chunk)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(chunk)


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8733
    socketserver.TCPServer.allow_reuse_address = True
    socketserver.TCPServer(('127.0.0.1', port), Handler).serve_forever()
