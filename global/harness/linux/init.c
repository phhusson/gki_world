// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal gki_world Linux init: expose a USB ACM serial gadget and hand the
 * console to a shell. No network, no sshd, no auth. Development images only.
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define GADGET "/sys/kernel/config/usb_gadget/g1"
#define TTY "/dev/ttyGS0"

/*
 * Boot-progress marker for the 2ndstage.  The page is reserved (but mapped)
 * in the Linux DT; /dev/mem writes it uncached so it survives a watchdog
 * reset and can be read with `fastboot oem pstore:...` from U-Boot.
 */
#define GKIW_MARKER_ADDR 0x9c000000
static volatile unsigned int *gkiw_marker;

static void gkiw_mark(unsigned int value)
{
	if (!gkiw_marker) {
		void *p;
		int fd = open("/dev/mem", O_RDWR | O_SYNC);

		if (fd < 0)
			return;
		p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED,
			 fd, GKIW_MARKER_ADDR);
		close(fd);
		if (p == MAP_FAILED)
			return;
		gkiw_marker = p;
	}
	*gkiw_marker = value;
}

static void logmsg(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static int write_file(const char *path, const char *fmt, ...)
{
	char buf[256];
	va_list ap;
	int fd;
	int len;

	va_start(ap, fmt);
	len = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (len < 0 || len >= (int)sizeof(buf))
		return -1;

	fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	if (write(fd, buf, len) != len) {
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

static void make_dir(const char *path)
{
	if (mkdir(path, 0755) && errno != EEXIST)
		logmsg("gkiw: mkdir %s: %s\n", path, strerror(errno));
}

static int first_udc(char *name, size_t size)
{
	struct dirent *de;
	DIR *dir;

	dir = opendir("/sys/class/udc");
	if (!dir)
		return -1;
	while ((de = readdir(dir))) {
		if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
			continue;
		snprintf(name, size, "%s", de->d_name);
		closedir(dir);
		return 0;
	}
	closedir(dir);
	return -1;
}

static void setup_gadget(void)
{
	char udc[64];

	make_dir("/sys/kernel/config");
	mount("configfs", "/sys/kernel/config", "configfs", 0, NULL);

	make_dir(GADGET);
	make_dir(GADGET "/functions");
	make_dir(GADGET "/configs");
	make_dir(GADGET "/strings");
	write_file(GADGET "/idVendor", "0x1b8e");
	write_file(GADGET "/idProduct", "0xfada");
	write_file(GADGET "/bcdUSB", "0x0200");
	write_file(GADGET "/bcdDevice", "0x0100");

	make_dir(GADGET "/strings/0x409");
	write_file(GADGET "/strings/0x409/manufacturer", "gki_world");
	write_file(GADGET "/strings/0x409/product", "gkiw ACM");
	write_file(GADGET "/strings/0x409/serialnumber", "gkiw");

	make_dir(GADGET "/configs/c.1");
	make_dir(GADGET "/configs/c.1/strings/0x409");
	write_file(GADGET "/configs/c.1/strings/0x409/configuration", "ACM");
	write_file(GADGET "/configs/c.1/MaxPower", "250");

	make_dir(GADGET "/functions/acm.gs0");

	/*
	 * configfs resolves the symlink target relative to the caller's cwd.
	 * Stand in the gadget root, as the usual shell setup does.
	 */
	if (chdir(GADGET)) {
		logmsg("gkiw: chdir %s: %s\n", GADGET, strerror(errno));
	} else if (symlink("functions/acm.gs0", "configs/c.1/acm.gs0") &&
		   errno != EEXIST) {
		logmsg("gkiw: symlink acm: %s\n", strerror(errno));
	}

	if (first_udc(udc, sizeof(udc))) {
		logmsg("gkiw: no UDC found\n");
		return;
	}
	if (write_file(GADGET "/UDC", "%s", udc))
		logmsg("gkiw: cannot bind %s\n", udc);
	else
		logmsg("gkiw: ACM gadget bound to %s\n", udc);
}

static void install_applets(void)
{
	pid_t pid = fork();

	if (pid == 0) {
		execl("/bin/busybox", "busybox", "--install", "-s", "/bin", NULL);
		_exit(127);
	}
	if (pid > 0)
		waitpid(pid, NULL, 0);
}

int main(void)
{
	int fd = -1;
	int i;

	make_dir("/dev");
	make_dir("/proc");
	make_dir("/sys");
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	gkiw_mark(0x474b0002);

	setup_gadget();
	gkiw_mark(0x474b0003);

	for (i = 0; i < 200; i++) {
		fd = open(TTY, O_RDWR);
		if (fd >= 0)
			break;
		usleep(50000);
	}
	if (fd < 0) {
		logmsg("gkiw: %s did not appear: %s\n", TTY, strerror(errno));
		for (;;)
			sleep(3600);
	}

	setsid();
	ioctl(fd, TIOCSCTTY, 1);
	dup2(fd, 0);
	dup2(fd, 1);
	dup2(fd, 2);

	install_applets();
	gkiw_mark(0x474b0004);
	setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin", 1);
	setenv("HOME", "/", 1);
	setenv("TERM", "linux", 1);

	{
		struct termios tio;

		if (!tcgetattr(fd, &tio)) {
			cfmakeraw(&tio);
			tio.c_oflag |= OPOST | ONLCR;
			tcsetattr(fd, TCSANOW, &tio);
		}
	}

	chdir("/");

	logmsg("\n\ngkiw: USB ACM shell ready on /dev/ttyGS0\n");
	logmsg("gkiw: host: socat - /dev/ttyACM0,raw,echo=0\n\n");

	execl("/bin/busybox", "busybox", "sh", "-i", NULL);
	logmsg("gkiw: exec busybox failed: %s\n", strerror(errno));
	for (;;)
		sleep(3600);
}
