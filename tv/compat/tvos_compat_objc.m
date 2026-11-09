/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * atv-macos: Objective-C half of tv/compat. Compiled WITH the compat header
 * (for the category declaration). The app must link the engine with -ObjC so
 * this category is loaded from the static library.
 */
#import <QuartzCore/CAMetalLayer.h>

#if TARGET_OS_TV
@implementation CAMetalLayer (ATVCompat)
- (BOOL)atv_wantsEDR { return NO; }
@end
#endif
