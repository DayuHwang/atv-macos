/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * atv-macos: force-included (clang -include) into every engine file built for
 * tvOS. It lets the unmodified Henge sources use the few POSIX calls the tvOS
 * SDK marks unavailable, by routing them to tv/compat/tvos_compat.c.
 *
 * signal.h is included first so its (prohibited) declarations are parsed under
 * their real names; the macros below only rename later call sites.
 */
#ifndef ATV_TVOS_COMPAT_H
#define ATV_TVOS_COMPAT_H

#include <TargetConditionals.h>
#if TARGET_OS_TV
#include <signal.h>

/* The engine runs guest code with the guest's SP in the host SP register, so a
   fault handler must run on an alternate stack. tvOS's SDK forbids sigaltstack;
   the kernel call underneath is the same XNU code as on iOS. */
int atv_sigaltstack(const stack_t *ss, stack_t *oss);
#define sigaltstack atv_sigaltstack

#endif
#endif
