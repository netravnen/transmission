#!/usr/bin/env python3
"""Fetch a torrent's info dictionary from one peer over BEP 9 and check it.

Used by the transmission/transmission#9151 reproduction. Standard library only.

  bep9_fetch.py hash <file.torrent>       print the v1 infohash of a .torrent
  bep9_fetch.py fetch <host> <port> <infohash>

fetch prints one JSON line and exits 0 when the SHA-1 of the received
metadata equals the infohash, 3 when it does not, and 2 when the exchange
could not complete. On a mismatch, "shift" is how many bytes too early the
received window starts, found from the position of "4:info" in it.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import socket
import struct
import sys

PIECE = 16 * 1024


def bdecode(data: bytes, i: int = 0):
    c = data[i:i + 1]
    if c == b'i':
        end = data.index(b'e', i)
        return int(data[i + 1:end]), end + 1
    if c == b'l':
        i += 1
        out = []
        while data[i:i + 1] != b'e':
            v, i = bdecode(data, i)
            out.append(v)
        return out, i + 1
    if c == b'd':
        i += 1
        out = {}
        while data[i:i + 1] != b'e':
            k, i = bdecode(data, i)
            v, i = bdecode(data, i)
            out[k] = v
        return out, i + 1
    colon = data.index(b':', i)
    n = int(data[i:colon])
    return data[colon + 1:colon + 1 + n], colon + 1 + n


def bencode(x) -> bytes:
    if isinstance(x, int):
        return b'i%de' % x
    if isinstance(x, bytes):
        return b'%d:%s' % (len(x), x)
    if isinstance(x, dict):
        return b'd' + b''.join(bencode(k) + bencode(x[k]) for k in sorted(x)) + b'e'
    raise TypeError(type(x))


def info_hash_of(path: str) -> str:
    raw = open(path, 'rb').read()
    i = raw.index(b'4:info') + 6
    _, end = bdecode(raw, i)
    return hashlib.sha1(raw[i:end]).hexdigest()


def recv_exact(s: socket.socket, n: int) -> bytes:
    buf = b''
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError('peer closed the connection')
        buf += chunk
    return buf


def read_msg(s: socket.socket) -> bytes:
    while True:
        (length,) = struct.unpack('>I', recv_exact(s, 4))
        if length:
            return recv_exact(s, length)


def send_ext(s: socket.socket, ext_id: int, payload: bytes) -> None:
    s.sendall(struct.pack('>IBB', len(payload) + 2, 20, ext_id) + payload)


def fetch(host: str, port: int, ih_hex: str) -> int:
    ih = bytes.fromhex(ih_hex)
    result = {'host': host, 'port': port, 'info_hash': ih_hex}
    try:
        s = socket.create_connection((host, port), timeout=20)
        reserved = bytearray(8)
        reserved[5] |= 0x10
        s.sendall(bytes([19]) + b'BitTorrent protocol' + bytes(reserved) + ih + b'-RP9151-' + os.urandom(12))
        hs = recv_exact(s, 68)
        if hs[28:48] != ih or not hs[25] & 0x10:
            raise ConnectionError('bad handshake or no extension protocol')
        send_ext(s, 0, bencode({b'm': {b'ut_metadata': 1}}))
        their_id = size = None
        while their_id is None:
            m = read_msg(s)
            if m[0] == 20 and m[1] == 0:
                d, _ = bdecode(m, 2)
                their_id = d[b'm'][b'ut_metadata']
                size = d[b'metadata_size']
        data = b''
        for p in range(math.ceil(size / PIECE)):
            send_ext(s, their_id, bencode({b'msg_type': 0, b'piece': p}))
            while True:
                m = read_msg(s)
                if m[0] == 20 and m[1] == 1:
                    d, end = bdecode(m, 2)
                    if d.get(b'msg_type') == 2:
                        raise ConnectionError(f'peer rejected metadata piece {p}')
                    if d.get(b'msg_type') == 1 and d.get(b'piece') == p:
                        data += m[end:]
                        break
        s.close()
    except (OSError, ConnectionError, ValueError, KeyError) as exc:
        result.update(status='error', error=f'{type(exc).__name__}: {exc}')
        print(json.dumps(result))
        return 2
    ok = hashlib.sha1(data).digest() == ih
    marker = data.find(b'4:infod')
    result.update(status='ok' if ok else 'mismatch', metadata_size=size, pieces=math.ceil(size / PIECE),
                  received=len(data), shift=None if ok or marker < 0 else marker + 6)
    print(json.dumps(result))
    return 0 if ok else 3


def main() -> int:
    if sys.argv[1] == 'hash':
        print(info_hash_of(sys.argv[2]))
        return 0
    return fetch(sys.argv[2], int(sys.argv[3]), sys.argv[4])


if __name__ == '__main__':
    raise SystemExit(main())
