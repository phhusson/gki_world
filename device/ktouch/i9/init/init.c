// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal gki_world userspace for the first MT6739 boot.  It mounts the
 * pseudo filesystems and writes markers to /dev/kmsg, which the pstore
 * console captures for the next 2ndstage boot.
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

static void kmsg(const char *s)
{
	int fd = open("/dev/kmsg", O_WRONLY);

	if (fd >= 0) {
		write(fd, s, strlen(s));
		close(fd);
	}
}

int main(void)
{
	mkdir("/dev", 0755);
	mkdir("/proc", 0755);
	mkdir("/sys", 0755);

	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);

	kmsg("gkiw: userspace init reached on MT6739\n");
	kmsg("gkiw: waiting for the 2ndstage watchdog\n");

	for (;;)
		sleep(3600);
}
