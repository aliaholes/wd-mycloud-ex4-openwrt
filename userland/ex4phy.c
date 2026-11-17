// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * ex4phy.c : a READ-ONLY look at the Ethernet PHY behind each interface named on the command line. Runs inside
 * the trial system (Linux 6.12); the self-test calls it as `ex4phy eth0 eth1`.
 *
 * Why it exists (run 8): the device tree gives the EX4's two PHYs an id no driver claims, so that the kernel runs
 * them with its generic PHY driver (docs/HARDWARE.md, "The link flap"). With that override the kernel no longer
 * reads the chip's own id, and sysfs shows the override. This program asks the chip itself: the id registers
 * (2 and 3), and register 22, the Marvell page register, which must read 0 (the copper page) for the MAC's own
 * hardware polling of the PHY to see the copper link.
 *
 * What it does, all of it: SIOCGMIIPHY (which address) and SIOCGMIIREG (read one register) on an ordinary
 * datagram socket. This file has no call that writes a PHY register. One line per interface:
 *   eth1 phy addr 1 chip_id 0141.0dd1 page 0 bmcr 1140 bmsr 796d status17 ac08
 * (bmsr is read twice and the second value printed: its link bit latches low.) A register the PHY or the driver
 * will not read is printed as question marks. An interface whose driver has no MII ioctl gets:
 *   eth0 phy none (SIOCGMIIPHY: <error>)
 * Exit status: 0 if every interface answered every read, 1 otherwise.   Born Nov 17 2026 (EX4 run 8 prep).
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <linux/mii.h>
#include <linux/sockios.h>

static int rd(int fd, struct ifreq *ifr, int phy, int reg)
{
	struct mii_ioctl_data *m = (struct mii_ioctl_data *)&ifr->ifr_data;

	m->phy_id = phy;
	m->reg_num = reg;
	m->val_in = 0;
	m->val_out = 0;
	if (ioctl(fd, SIOCGMIIREG, ifr) < 0)
		return -1;
	return m->val_out;
}

int main(int argc, char **argv)
{
	static const int regs[] = { 2, 3, 22, 0, 1, 1, 17 };
	int fd, i, bad = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: ex4phy <interface> [...]   (reads PHY registers 0 1 2 3 17 22; writes nothing)\n");
		return 64;
	}
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		printf("ex4phy: socket: %s\n", strerror(errno));
		return 1;
	}
	for (i = 1; i < argc; i++) {
		struct ifreq ifr;
		struct mii_ioctl_data *m = (struct mii_ioctl_data *)&ifr.ifr_data;
		int v[sizeof(regs) / sizeof(regs[0])], phy, k;
		char id[16], page[16], bmcr[16], bmsr[16], st[16];

		memset(&ifr, 0, sizeof(ifr));
		strncpy(ifr.ifr_name, argv[i], IFNAMSIZ - 1);
		if (ioctl(fd, SIOCGMIIPHY, &ifr) < 0) {
			printf("%s phy none (SIOCGMIIPHY: %s)\n", argv[i], strerror(errno));
			bad = 1;
			continue;
		}
		phy = m->phy_id;
		for (k = 0; k < (int)(sizeof(regs) / sizeof(regs[0])); k++) {
			v[k] = rd(fd, &ifr, phy, regs[k]);
			if (v[k] < 0)
				bad = 1;
		}
		if (v[0] < 0 || v[1] < 0)
			snprintf(id, sizeof(id), "????.????");
		else
			snprintf(id, sizeof(id), "%04x.%04x", v[0] & 0xffff, v[1] & 0xffff);
		if (v[2] < 0)
			snprintf(page, sizeof(page), "?");
		else
			snprintf(page, sizeof(page), "%d", v[2] & 0xff);
		if (v[3] < 0)
			snprintf(bmcr, sizeof(bmcr), "????");
		else
			snprintf(bmcr, sizeof(bmcr), "%04x", v[3] & 0xffff);
		if (v[5] < 0)
			snprintf(bmsr, sizeof(bmsr), "????");
		else
			snprintf(bmsr, sizeof(bmsr), "%04x", v[5] & 0xffff);
		if (v[6] < 0)
			snprintf(st, sizeof(st), "????");
		else
			snprintf(st, sizeof(st), "%04x", v[6] & 0xffff);
		printf("%s phy addr %d chip_id %s page %s bmcr %s bmsr %s status17 %s\n", argv[i], phy, id, page, bmcr, bmsr, st);
	}
	close(fd);
	return bad;
}
