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
#include <sys/types.h>
#include <spawn.h>

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

/* csops(pid, ops, useraddr, usersize) as a direct system call. */
int atv_syscall_169(int pid, unsigned int ops, void *useraddr, size_t usersize) {
    register long x0 __asm__("x0") = pid;
    register long x1 __asm__("x1") = ops;
    register long x2 __asm__("x2") = (long)useraddr;
    register long x3 __asm__("x3") = (long)usersize;
    register long x16 __asm__("x16") = 169;
    long failed;
    __asm__ volatile("svc #0x80\n\tcset %1, cs"
                     : "+r"(x0), "=r"(failed)
                     : "r"(x1), "r"(x2), "r"(x3), "r"(x16)
                     : "memory", "cc");
    if (failed) { errno = (int)x0; return -1; }
    return (int)x0;
}

pid_t atv_fork(void) {
    errno = ENOSYS;
    return -1;
}

/* No child processes on tvOS: the file actions are accepted and ignored, and
   the spawn itself reports ENOSYS (posix_spawn returns the error number). */
int atv_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                    const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    (void)pid; (void)fa; (void)attr; (void)argv; (void)envp;
    fprintf(stderr, "atv-macos: not spawning %s (no child processes on tvOS)\n", path ? path : "?");
    return ENOSYS;
}
int atv_posix_spawn_file_actions_init(posix_spawn_file_actions_t *fa) { if (fa) *fa = NULL; return 0; }
int atv_posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *fa, int fd, const char *path,
                                         int oflag, mode_t mode) {
    (void)fa; (void)fd; (void)path; (void)oflag; (void)mode;
    return 0;
}
int atv_posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *fa) { (void)fa; return 0; }
#endif
