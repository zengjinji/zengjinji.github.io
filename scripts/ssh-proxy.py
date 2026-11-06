# HTTP CONNECT transport for the SSH push configured in this local checkout.
import os, select, socket, sys
from urllib.parse import urlsplit
host,port=sys.argv[1],int(sys.argv[2])
proxy=os.environ.get('BLOG_PROXY','http://172.20.10.1:1082')
if proxy:
 parsed=urlsplit(proxy)
 if parsed.scheme != 'http' or not parsed.hostname:
  raise SystemExit('BLOG_PROXY must be an HTTP proxy URL')
 sock=socket.create_connection((parsed.hostname,parsed.port or 80),timeout=15)
else:
 sock=socket.create_connection((host,port),timeout=15)
if proxy:
 sock.sendall(('CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n'%(host,port,host,port)).encode('ascii'))
 header=b''
 while not header.endswith(b'\r\n\r\n'):
  chunk=sock.recv(1)
  if not chunk or len(header)>8192: raise SystemExit('Proxy CONNECT failed')
  header+=chunk
 if header.split(b' ',2)[1] != b'200': raise SystemExit('Proxy refused SSH connection')
sock.settimeout(None)
while True:
 ready,_,_=select.select([sock,0],[],[])
 if sock in ready:
  data=sock.recv(65536)
  if not data: break
  view=memoryview(data)
  while view:
   n=os.write(1,view); view=view[n:]
 if 0 in ready:
  data=os.read(0,65536)
  if not data: break
  sock.sendall(data)
