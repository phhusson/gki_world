// SPDX-License-Identifier: GPL-2.0-only
/*
 * gki_world out-of-tree build smoke test.
 *
 * This module exists so the top-level build can prove, on any target, that a
 * gki_world module compiles and links against a mainline kernel tree. It has no
 * hardware dependency and is never loaded on a device.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>

static int __init gkiw_test_init(void)
{
	pr_info("gkiw_test: gki_world build is alive\n");
	return 0;
}

static void __exit gkiw_test_exit(void)
{
	pr_info("gkiw_test: unloaded\n");
}

module_init(gkiw_test_init);
module_exit(gkiw_test_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("gki_world out-of-tree build smoke test");
MODULE_AUTHOR("gki_world contributors");
