/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * atv-macos: network backend placeholder for the first tvOS builds.
 *
 * Henge's user-mode NAT (host/net_slirp.c) needs libslirp and glib built for
 * the target. Until those are cross-built for appletvos, the virtual Mac boots
 * without a network card backend: vm.c already treats a failed attach as
 * "no network" and carries on. The remote display does not depend on guest
 * networking, because our VNC server lives in the tvOS app, outside the guest.
 */
#include <stdint.h>
#include "net_slirp.h"

uint64_t hv_net_tx_frames, hv_net_rx_frames;

void hv_net_set_share_socket(const char *path) { (void)path; }

int hv_net_attach(HvMachine *m, HvVirtioNet *n) {
    (void)m; (void)n;
    return -1; /* no backend yet */
}

void hv_net_poll(void) {}
