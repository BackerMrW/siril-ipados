// SPDX-License-Identifier: GPL-3.0-or-later
/* Device-target link verification, not an on-device execution test. */
#include "SirilCore.h"
#include <stdio.h>
int main(void) {
    puts(siril_core_version());
    return 0;
}
