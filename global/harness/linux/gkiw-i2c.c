// SPDX-License-Identifier: GPL-2.0-only
/*
 * Tiny I2C probe for the gki_world bringup initramfs.
 *
 *   gkiw-i2c <bus> <addr> <reg> [len]
 *   gkiw-i2c <bus> <addr> w <reg> <value>
 *
 * Prints the bytes read (or the write result) in hex.
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	unsigned char buf[64];
	char path[32];
	int bus, addr, reg, len, fd, i, n;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <bus> <addr> <reg> [len]\n", argv[0]);
		fprintf(stderr, "       %s <bus> <addr> w <reg> <value>\n", argv[0]);
		return 1;
	}

	bus = atoi(argv[1]);
	addr = strtol(argv[2], NULL, 0);

	snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
	fd = open(path, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return 1;
	}
	if (!strcmp(argv[3], "w")) {
		struct i2c_msg msg = { .addr = addr, .flags = 0, .len = 2 };

		reg = strtol(argv[4], NULL, 0);
		buf[0] = reg;
		buf[1] = strtol(argv[5], NULL, 0);
		msg.buf = buf;
		n = ioctl(fd, I2C_RDWR, &(struct i2c_rdwr_ioctl_data){
			.msgs = &msg, .nmsgs = 1 });
		printf("write %#x=%#x: %d (%s)\n", reg, buf[1], n,
		       n < 0 ? strerror(errno) : "ok");
		return n < 0 ? 1 : 0;
	}

	reg = strtol(argv[3], NULL, 0);
	len = argc > 4 ? atoi(argv[4]) : 1;
	if (len < 1 || len > (int)sizeof(buf)) {
		fprintf(stderr, "bad length %d\n", len);
		return 1;
	}

	{
		struct i2c_msg msgs[2] = {
			{ .addr = addr, .flags = 0, .len = 1, .buf = buf },
			{ .addr = addr, .flags = I2C_M_RD, .len = len, .buf = buf },
		};

		buf[0] = reg;
		n = ioctl(fd, I2C_RDWR, &(struct i2c_rdwr_ioctl_data){
			.msgs = msgs, .nmsgs = 2 });
		if (n < 0) {
			fprintf(stderr, "read %#x: %s\n", reg, strerror(errno));
			return 1;
		}
	}

	printf("%#04x:", reg);
	for (i = 0; i < n; i++)
		printf(" %02x", buf[i]);
	printf("\n");

	return 0;
}
