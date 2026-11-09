"""Minimal GDB remote-serial-protocol client for Apple's debugserver.

Only what the Henge JIT handshake needs: attach, continue, read/write registers
and memory, allocate memory (`_M`), detach. Transport is any object with
`send(bytes)` and `recv(n) -> bytes` (blocking), so the same code runs over a
pymobiledevice3 service connection on Windows or a plain socket in tests.
"""
from __future__ import annotations

import re
import struct

# arm64 register numbers as debugserver numbers them
REG_X0, REG_X1, REG_X16, REG_PC = 0, 1, 16, 32


class GdbError(RuntimeError):
    pass


def _checksum(payload: bytes) -> bytes:
    return b"%02x" % (sum(payload) & 0xFF)


def _escape(payload: bytes) -> bytes:
    out = bytearray()
    for b in payload:
        if b in b"#$}*":
            out += bytes([0x7D, b ^ 0x20])
        else:
            out.append(b)
    return bytes(out)


def _unescape(payload: bytes) -> bytes:
    out, i = bytearray(), 0
    while i < len(payload):
        b = payload[i]
        if b == 0x7D:
            i += 1
            out.append(payload[i] ^ 0x20)
        elif b == 0x2A and out:  # run-length: previous char repeated (n - 29) more times
            i += 1
            out += bytes([out[-1]]) * (payload[i] - 29)
        else:
            out.append(b)
        i += 1
    return bytes(out)


class GdbRemote:
    def __init__(self, transport, log=print):
        self.t = transport
        self.log = log
        self.ack = True
        self._buf = b""
        self.thread_suffix = False

    # ------------------------------------------------------------ framing
    def _read(self, n=4096) -> bytes:
        data = self.t.recv(n)
        if not data:
            raise GdbError("debugserver closed the connection")
        return data

    def _send_packet(self, payload: bytes) -> None:
        body = _escape(payload)
        frame = b"$" + body + b"#" + _checksum(body)
        while True:
            self.t.send(frame)
            if not self.ack:
                return
            c = self._getc()
            if c == b"+":
                return
            if c != b"-":
                raise GdbError(f"expected ack, got {c!r}")

    def _getc(self) -> bytes:
        if not self._buf:
            self._buf = self._read()
        c, self._buf = self._buf[:1], self._buf[1:]
        return c

    def _recv_packet(self) -> bytes:
        while True:
            c = self._getc()
            if c == b"$":
                break
            # stray acks / notification chars are skipped
        body = bytearray()
        while True:
            c = self._getc()
            if c == b"#":
                break
            body += c
        csum = self._getc() + self._getc()
        if self.ack:
            if _checksum(bytes(body)) != csum:
                self.t.send(b"-")
                return self._recv_packet()
            self.t.send(b"+")
        return _unescape(bytes(body))

    def request(self, payload: str | bytes) -> bytes:
        if isinstance(payload, str):
            payload = payload.encode()
        self._send_packet(payload)
        reply = self._recv_packet()
        # debugserver may send console output ("O...") before the real reply
        while reply.startswith(b"O") and reply != b"OK":
            self.log("[target] " + bytes.fromhex(reply[1:].decode()).decode(errors="replace").rstrip())
            reply = self._recv_packet()
        return reply

    def ok(self, payload: str) -> None:
        r = self.request(payload)
        if r != b"OK":
            raise GdbError(f"{payload!r} -> {r!r}")

    # ------------------------------------------------------------ session
    def handshake(self) -> None:
        if self.request("QStartNoAckMode") == b"OK":
            self.ack = False
        self.thread_suffix = self.request("QThreadSuffixSupported") == b"OK"
        self.request("QSetDetachOnError:1")

    def attach(self, pid: int) -> "Stop":
        return Stop.parse(self.request("vAttach;%x" % pid))

    def cont(self, signal: int = 0) -> "Stop":
        payload = "C%02x" % signal if signal else "c"
        self._send_packet(payload.encode())
        reply = self._recv_packet()
        while reply.startswith(b"O") and reply != b"OK":
            self.log("[target] " + bytes.fromhex(reply[1:].decode()).decode(errors="replace").rstrip())
            reply = self._recv_packet()
        return Stop.parse(reply)

    def detach(self) -> None:
        try:
            self.request("D")
        except GdbError:
            pass

    # ------------------------------------------------------------ state
    def _suffix(self, tid: int | None) -> str:
        return f";thread:{tid:x};" if (self.thread_suffix and tid is not None) else ""

    def read_reg(self, reg: int, tid: int | None = None) -> int:
        r = self.request(f"p{reg:x}{self._suffix(tid)}")
        if r.startswith(b"E"):
            raise GdbError(f"read reg {reg}: {r!r}")
        return int.from_bytes(bytes.fromhex(r.decode()), "little")

    def write_reg(self, reg: int, value: int, tid: int | None = None) -> None:
        self.ok(f"P{reg:x}={(value & (2**64 - 1)).to_bytes(8, 'little').hex()}{self._suffix(tid)}")

    def read_mem(self, addr: int, size: int) -> bytes:
        r = self.request(f"m{addr:x},{size:x}")
        if r.startswith(b"E") or not r:
            raise GdbError(f"read mem {addr:#x}: {r!r}")
        return bytes.fromhex(r.decode())

    def write_mem(self, addr: int, data: bytes) -> None:
        self.ok(f"M{addr:x},{len(data):x}:{data.hex()}")

    def write_mem_many(self, writes: list[tuple[int, bytes]], window: int = 512) -> None:
        """Pipelined `M` packets: in no-ack mode, send up to `window` writes before
        reading their replies, so a 65536-page region costs ~128 round trips over
        Wi-Fi instead of 65536."""
        if self.ack:
            for addr, data in writes:
                self.write_mem(addr, data)
            return
        for i in range(0, len(writes), window):
            chunk = writes[i:i + window]
            frames = b"".join(
                b"$" + _escape(p) + b"#" + _checksum(_escape(p))
                for p in (f"M{a:x},{len(d):x}:{d.hex()}".encode() for a, d in chunk)
            )
            self.t.send(frames)
            for addr, _ in chunk:
                r = self._recv_packet()
                if r != b"OK":
                    raise GdbError(f"write {addr:#x} -> {r!r}")

    def alloc(self, size: int, perms: str = "rx") -> int:
        r = self.request(f"_M{size:x},{perms}")
        if not r or r.startswith(b"E"):
            raise GdbError(f"_M{size:x},{perms} -> {r!r}")
        return int(r.decode(), 16)


class Stop:
    """A stop reply: T<sig>key:value;... / S<sig> / W<code> (exited) / X<sig> (killed)."""

    def __init__(self, kind: str, signal: int, fields: dict[str, str]):
        self.kind, self.signal, self.fields = kind, signal, fields

    @property
    def tid(self) -> int | None:
        t = self.fields.get("thread")
        return int(t, 16) if t else None

    @property
    def exited(self) -> bool:
        return self.kind in ("W", "X")

    @classmethod
    def parse(cls, reply: bytes) -> "Stop":
        s = reply.decode(errors="replace")
        if not s or s[0] not in "TSWX":
            raise GdbError(f"unexpected stop reply {s!r}")
        kind, sig = s[0], int(s[1:3], 16)
        fields = {}
        for part in s[3:].split(";"):
            if ":" in part:
                k, v = part.split(":", 1)
                fields.setdefault(k, v)
        return cls(kind, sig, fields)

    def __repr__(self):
        return f"Stop({self.kind}{self.signal:02x} {self.fields.get('reason', '')} tid={self.tid})"


BRK_MASK, BRK_BASE = 0xFFE0001F, 0xD4200000


def brk_immediate(insn: int) -> int | None:
    """Return the 16-bit immediate if `insn` is BRK #imm, else None."""
    if insn & BRK_MASK == BRK_BASE:
        return (insn >> 5) & 0xFFFF
    return None
