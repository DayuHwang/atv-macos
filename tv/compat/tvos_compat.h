/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * atv-macos: force-included (clang -include) into every engine and installer
 * file built for tvOS. It lets the unmodified Henge sources (and the libraries
 * Henge vendors) use the few APIs the tvOS SDK marks unavailable, by routing
 * them to tv/compat/tvos_compat.{c,m}.
 *
 * Each SDK header is included first so its (prohibited) declarations are parsed
 * under their real names; the macros below only rename later call sites.
 */
#ifndef ATV_TVOS_COMPAT_H
#define ATV_TVOS_COMPAT_H

#include <TargetConditionals.h>
#if TARGET_OS_TV
#include <signal.h>
#include <unistd.h>

/* The engine runs guest code with the guest's SP in the host SP register, so a
   fault handler must run on an alternate stack. tvOS's SDK forbids sigaltstack;
   the kernel call underneath is the same XNU code as on iOS. */
int atv_sigaltstack(const stack_t *ss, stack_t *oss);
#define sigaltstack atv_sigaltstack

/* usbmuxd only forks to become a daemon; Henge runs it in the foreground, so
   this path is never taken. It fails cleanly instead of failing the build. */
pid_t atv_fork(void);
#define fork atv_fork

#ifdef __OBJC__
#import <QuartzCore/CAMetalLayer.h>
/* Read only by a diagnostic log line (pvg_colorprobe.h); tvOS layers have no
   EDR switch, so it reads as NO. */
@interface CAMetalLayer (ATVCompat)
@property (nonatomic, readonly) BOOL atv_wantsEDR;
@end
#define wantsExtendedDynamicRangeContent atv_wantsEDR
#endif

#endif
#endif
