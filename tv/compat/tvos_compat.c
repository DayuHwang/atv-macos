/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * atv-macos: implementations behind tv/compat/tvos_compat.h.
 * Built WITHOUT the force-included header, so nothing here is renamed.
 */
#include <TargetConditionals.h>
#if TARGET_OS_TV
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/syscall.h>

#ifndef SYS_sigaltstack
#define SYS_sigaltstack 53
#endif

/* Darwin arm64 system call: number in x16, `svc #0x80`, carry set on failure
   with the errno value in x0. Issued directly because the SDK marks the libc
   wrapper unavailable on tvOS. */
int atv_sigaltstack(const stack_t *ss, stack_t *oss) {
    register long x0 __asm__("x0") = (long)ss;
    register long x1 __asm__("x1") = (long)oss;
    register long x16 __asm__("x16") = SYS_sigaltstack;
    long failed;
    __asm__ volatile("svc #0x80\n\tcset %1, cs"
                     : "+r"(x0), "=r"(failed)
                     : "r"(x1), "r"(x16)
                     : "memory", "cc");
    if (failed) {
        errno = (int)x0;
        /* Logged so a refusal shows up in the app log rather than as a
           mysterious crash on the first guest memory fault. */
        fprintf(stderr, "atv-macos: sigaltstack refused by the kernel (errno %d)\n", (int)x0);
        return -1;
    }
    return 0;
}
#endif
