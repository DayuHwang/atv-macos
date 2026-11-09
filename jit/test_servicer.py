"""Runs JitServicer against a fake debugserver that plays Henge's startup:
probe -> prepare 1 GiB region -> detach. Checks every answer the app would see."""
import socket
import sys
import threading
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from jit.gdbremote import GdbRemote, _checksum  # noqa: E402
from jit.servicer import JitServicer, PROBE_REPLY, PAGE  # noqa: E402

BRK = lambda imm: (0xD4200000 | (imm << 5)).to_bytes(4, "little")  # noqa: E731
CODE = 0x100004000
TID = 0x1A2B


class FakeDebugserver(threading.Thread):
    def __init__(self, sock, region_size):
        super().__init__(daemon=True)
        self.s, self.ack = sock, True
        self.regs = {i: 0 for i in range(34)}
        self.mem = {}
        self.region_size = region_size
        self.alloc_at = 0x280000000
        self.page_writes = set()
        self.results = {}
        self.detached = False
        # (label, brk imm, registers) the app will hit in order
        self.script = [
            ("probe", 0x69, {}),
            ("prepare", 0xF00D, {16: 1, 0: 0, 1: region_size}),
            ("detach", 0xF00D, {16: 0}),
        ]
        self.step = -1
        self.buf = b""

    def _getc(self):
        if not self.buf:
            self.buf = self.s.recv(4096)
            if not self.buf:
                raise EOFError
        c, self.buf = self.buf[:1], self.buf[1:]
        return c

    def recv_packet(self):
        while self._getc() != b"$":
            pass
        body = b""
        while (c := self._getc()) != b"#":
            body += c
        self._getc(); self._getc()
        if self.ack:
            self.s.send(b"+")
        return body.decode()

    def send_packet(self, payload: str):
        p = payload.encode()
        self.s.send(b"$" + p + b"#" + _checksum(p))
        if self.ack:
            assert self._getc() == b"+"

    def stop_at_next(self):
        # record what the app got back from the previous brk
        if self.step >= 0:
            label = self.script[self.step][0]
            expected_pc = CODE + self.step * 8 + 4
            assert self.regs[32] == expected_pc, f"{label}: pc not stepped over"
            self.results[label] = self.regs[0]
        self.step += 1
        if self.step >= len(self.script):
            return "W00"
        label, imm, regs = self.script[self.step]
        pc = CODE + self.step * 8
        for k, v in regs.items():
            self.regs[k] = v
        self.regs[32] = pc
        for i, b in enumerate(BRK(imm)):
            self.mem[pc + i] = b
        return f"T05thread:{TID:x};reason:exception;"

    def run(self):
        try:
            while True:
                pkt = self.recv_packet()
                if pkt == "QStartNoAckMode":
                    self.send_packet("OK"); self.ack = False
                elif pkt in ("QThreadSuffixSupported", "QSetDetachOnError:1"):
                    self.send_packet("OK")
                elif pkt.startswith("vAttach;"):
                    self.send_packet(f"T11thread:{TID:x};reason:signal;")
                elif pkt in ("c",) or pkt.startswith("C"):
                    self.send_packet(self.stop_at_next())
                elif pkt.startswith("p"):
                    reg = int(pkt[1:].split(";")[0], 16)
                    assert f"thread:{TID:x}" in pkt
                    self.send_packet(self.regs[reg].to_bytes(8, "little").hex())
                elif pkt.startswith("P"):
                    reg, val = pkt[1:].split(";")[0].split("=")
                    self.regs[int(reg, 16)] = int.from_bytes(bytes.fromhex(val), "little")
                    self.send_packet("OK")
                elif pkt.startswith("m"):
                    a, n = (int(x, 16) for x in pkt[1:].split(","))
                    self.send_packet(bytes(self.mem.get(a + i, 0) for i in range(n)).hex())
                elif pkt.startswith("_M"):
                    size, perms = pkt[2:].split(",")
                    assert perms == "rx" and int(size, 16) == self.region_size
                    self.send_packet(f"{self.alloc_at:x}")
                elif pkt.startswith("M"):
                    head, data = pkt[1:].split(":")
                    a, n = (int(x, 16) for x in head.split(","))
                    assert n == 1 and data == "69"
                    assert (a - self.alloc_at) % PAGE == 0
                    self.page_writes.add(a)
                    self.send_packet("OK")
                elif pkt == "D":
                    # the detach brk must have been stepped over before detaching
                    self.results["detach"] = self.regs[32] == CODE + 2 * 8 + 4
                    self.detached = True
                    self.send_packet("OK")
                    return
                else:
                    self.send_packet("")
        except EOFError:
            return


class SockTransport:
    def __init__(self, s): self.s = s
    def send(self, b): self.s.sendall(b)
    def recv(self, n): return self.s.recv(n)


def main():
    size = 1 << 30
    a, b = socket.socketpair()
    fake = FakeDebugserver(b, size)
    fake.start()
    logs = []
    gdb = GdbRemote(SockTransport(a), log=logs.append)
    gdb.handshake()
    assert not gdb.ack and gdb.thread_suffix
    first = gdb.attach(0x4D2)
    ok = JitServicer(gdb, log=logs.append).run(first)
    fake.join(2)

    assert ok, "no region handed out"
    assert fake.results["probe"] == PROBE_REPLY, hex(fake.results["probe"])
    assert fake.results["prepare"] == fake.alloc_at, hex(fake.results["prepare"])
    assert len(fake.page_writes) == size // PAGE, len(fake.page_writes)
    assert fake.detached and fake.results["detach"] is True
    print("PASS")
    for line in logs:
        print("  ", line)
    print(f"   pages touched: {len(fake.page_writes)} (1 GiB / 16 KiB)")


if __name__ == "__main__":
    main()
