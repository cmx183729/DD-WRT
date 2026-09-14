/*
 * sysinit-rt2880.c
 *
 * Copyright (C) 2008 Sebastian Gottschall <s.gottschall@dd-wrt.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 *
 * $Id:
 */
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <syslog.h>
#include <signal.h>
#include <string.h>
#include <termios.h>
#include <sys/klog.h>
#include <sys/types.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <linux/if_ether.h>
#include <linux/mii.h>
#include <linux/sockios.h>
#include <net/if.h>

#include <arpa/inet.h>
#include <sys/socket.h>
#include <linux/sockios.h>
#include <linux/mii.h>

#include <ddnvram.h>
#include <shutils.h>
#include <utils.h>
#include <services.h>

#define sys_reboot() eval("sync"); eval("/bin/umount","-a","-r"); eval("event","3","1","15")

void start_sysinit(void)
{
	time_t tm = 0;

	mknod("/dev/mmc", S_IFBLK | 0660, makedev(126, 0));
	mknod("/dev/mmc0", S_IFBLK | 0660, makedev(126, 1));
	mknod("/dev/mmc1", S_IFBLK | 0660, makedev(126, 2));
	mknod("/dev/mmc2", S_IFBLK | 0660, makedev(126, 3));
	mknod("/dev/mmc3", S_IFBLK | 0660, makedev(126, 4));
	mknod("/dev/gpio", S_IFCHR | 0644, makedev(252, 0));

	/*
	 * Setup console 
	 */

	printf("sysinit() klogctl\n");
	klogctl(8, NULL, nvram_geti("console_loglevel"));
	printf("sysinit() get router\n");

	/*
	 * Set a sane date 
	 */
	stime(&tm);
	nvram_set("wl0_ifname", "ra0");

	insmod("thermal_sys");
	insmod("hwmon");

	eval("ifconfig", "eth2", "up");
	eval("ifconfig", "eth3", "up");

	/*
	 * cmd 64 packs VLAN member ports in bits 0..15 and untagged
	 * egress ports in bits 16..31.  Keep CPU-LAN P6 tagged for
	 * eth2.1, but emit untagged VLAN 1 frames on the LAN PHYs.
	 */
	eval("mtk_esw", "64", "0x1e401e", "0x10001");
	eval("mtk_esw", "64", "0x18001", "0x20002");

	eval("vconfig", "set_name_type", "VLAN_PLUS_VID_NO_PAD");
	eval("vconfig", "add", "eth2", "1");	//LAN
	eval("vconfig", "add", "eth3", "2");	//WAN

	insmod("hw_nat");

	nvram_unset("sw_cpuport");

	char eabuf[32];
	if (get_hwaddr("eth2", eabuf)) {
		nvram_set("et0macaddr_safe", eabuf);
	}
}

int check_cfe_nv(void)
{
	nvram_seti("portprio_support", 0);
	return 0;
}

int check_pmon_nv(void)
{
	return 0;
}

/*
 * Newer common services code calls this architecture hook unconditionally.
 * Upstream's RT2880 implementation intentionally has no MT7621 action here.
 */
void sys_overclocking(void)
{
}

char *enable_dtag_vlan(int enable)
{
	return "eth2";
}

char *set_wan_state(int state)
{
	return NULL;
}

/*
 * network.c now configures br0 through this helper even when VLAN tagging is
 * disabled.  Upstream provides it from vlantagging.c only with
 * HAVE_VLANTAGGING; K2P deliberately disables that feature.  Keep the
 * upstream STP/MSTP behavior available in the closed-driver configuration.
 */
#ifndef HAVE_VLANTAGGING
void set_stp_state(char *bridge, char *stp)
{
	br_set_stp_state(bridge, strcmp(stp, "Off") ? 1 : 0);
#ifdef HAVE_MSTP
	if (!strcmp(stp, "MSTP") && nvram_nmatch("1", "%s_vlan", bridge))
		eval("ip", "link", "set", "dev", bridge, "type", "bridge", "mst_enable", "1");
	else
		eval("ip", "link", "set", "dev", bridge, "type", "bridge", "mst_enable", "0");
	if (strcmp(stp, "Off"))
		eval("mstpctl", "addbridge", bridge);
	else
		eval("mstpctl", "delbridge", bridge);

	if (!strcmp(stp, "STP"))
		eval("mstpctl", "setforcevers", bridge, "stp");
	if (!strcmp(stp, "MSTP"))
		eval("mstpctl", "setforcevers", bridge, "mstp");
	if (!strcmp(stp, "RSTP"))
		eval("mstpctl", "setforcevers", bridge, "rstp");
#endif
}
#endif

/*
 * The upstream RT2880 code only has post-network actions for unrelated
 * boards.  K2P requires this no-op architecture hook to satisfy the current
 * common services ABI without altering its Padavan driver startup path.
 */
void start_postnetwork(void)
{
}

void start_devinit_arch(void)
{
}

/* No RT2880/K2P-specific defaults are required by the common restore path. */
void start_arch_defaults(void)
{
}
