"""Services Henge's BreakpointJIT requests from a debugger session.

Protocol (as documented in Henge's ios/Henge/Native/henge-brk.S and
henge-ios-jit.h):

  brk #0x69                 probe: answer x0 = 0xE0000069
  brk #0xf00d, x16 = 1      prepare an executable region: x0 = address hint
                            (0 = allocate a fresh one), x1 = length. Allocate
                            with `_M<len>,rx`, touch one byte in every 16 KiB
                            page through the debugger, return the address in x0
  brk #0xf00d, x16 = 0      detach: the app is done asking

In every case the debugger steps the pc past the brk before resuming.
Any other stop is passed back to the app with its original signal.
"""
from __future__ import annotations

from .gdbremote import REG_PC, REG_X0, REG_X1, REG_X16, GdbRemote, Stop, brk_immediate

PAGE = 0x4000
PROBE_REPLY = 0xE0000069
SIGTRAP = 5


class JitServicer:
    def __init__(self, gdb: GdbRemote, log=print):
        self.gdb, self.log = gdb, log
        self.regions: list[tuple[int, int]] = []

    def _step_over(self, pc: int, tid) -> None:
        self.gdb.write_reg(REG_PC, pc + 4, tid)

    def _prepare(self, hint: int, length: int) -> int:
        length = (length + PAGE - 1) & ~(PAGE - 1)
        addr = hint if hint else self.gdb.alloc(length, "rx")
        self.gdb.write_mem_many([(addr + off, b"\x69") for off in range(0, length, PAGE)])
        self.regions.append((addr, length))
        self.log(f"JIT region ready: {addr:#x} +{length // (1 << 20)} MiB")
        return addr

    def handle(self, stop: Stop) -> tuple[str, int]:
        """Deal with one stop. Returns ("continue", signal) or ("detach", 0)."""
        if stop.signal != SIGTRAP:
            return "continue", stop.signal
        tid = stop.tid
        pc = self.gdb.read_reg(REG_PC, tid)
        insn = int.from_bytes(self.gdb.read_mem(pc, 4), "little")
        imm = brk_immediate(insn)
        if imm == 0x69:
            self.gdb.write_reg(REG_X0, PROBE_REPLY, tid)
            self._step_over(pc, tid)
            self.log("probe answered")
            return "continue", 0
        if imm == 0xF00D:
            cmd = self.gdb.read_reg(REG_X16, tid)
            if cmd == 1:
                hint = self.gdb.read_reg(REG_X0, tid)
                length = self.gdb.read_reg(REG_X1, tid)
                try:
                    addr = self._prepare(hint, length)
                except Exception as e:  # report failure as a NULL return, never kill the app
                    self.log(f"prepare failed: {e}")
                    addr = 0
                self.gdb.write_reg(REG_X0, addr, tid)
                self._step_over(pc, tid)
                return "continue", 0
            if cmd == 0:
                self._step_over(pc, tid)
                self.log("app asked to detach")
                return "detach", 0
            self.log(f"unknown brk #0xf00d command x16={cmd}; stepping over")
            self._step_over(pc, tid)
            return "continue", 0
        # a breakpoint that is not ours (e.g. an assert): give it back to the app
        return "continue", SIGTRAP

    def run(self, first_stop: Stop, timeout_stops: int = 100000) -> bool:
        """Drive the session from the attach stop until the app detaches us.
        Returns True if a region was handed out."""
        stop, sig = first_stop, 0
        # The attach itself stops with SIGSTOP (17 on Darwin): just resume.
        if stop.signal not in (SIGTRAP,):
            stop = self.gdb.cont(0)
        for _ in range(timeout_stops):
            if stop.exited:
                self.log(f"app exited ({stop!r})")
                return bool(self.regions)
            action, sig = self.handle(stop)
            if action == "detach":
                self.gdb.detach()
                return bool(self.regions)
            stop = self.gdb.cont(sig)
        self.gdb.detach()
        return bool(self.regions)
