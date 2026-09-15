TOP_DIR:=$(CURDIR)

SVN := svn
SRC_DIR := $(TOP_DIR)/dd-wrt
SRC_URL := svn://svn.dd-wrt.com/DD-WRT
REVISION := HEAD

BUILD_DIR := $(SRC_DIR)/src/router
LINUX_DIR := $(SRC_DIR)/src/linux/universal/linux-4.14
TOOLCHAIN_DIR := $(TOP_DIR)/toolchain-mipsel_24kc_gcc-13.1.0_musl
TOOLCHAIN_ARCHIVE := toolchain-mipsel_24kc_gcc-13.1.0_musl.tar.gz
TOOLCHAIN_URL := https://github.com/tsl0922/DD-WRT/releases/download/toolchain/$(TOOLCHAIN_ARCHIVE)
TOOLCHAIN_GCC := $(TOOLCHAIN_DIR)/bin/mipsel-linux-uclibc-gcc

define DefineProfile
  BOARD=$(1)
  DTS=$(2)
  CONFIG=$(3)
  KCONFIG=$(4)
endef

ifneq ($(wildcard .config),)
  include .config
endif

ifeq ($(PROFILE),k2p-mt76)
  $(eval $(call DefineProfile,k2p,K2P-mt76,mt76.config,mt76.config))
else ifeq ($(PROFILE),k2p)
  $(eval $(call DefineProfile,k2p,K2P,.config,.config))
else ifeq ($(PROFILE),k2p-mini)
  $(eval $(call DefineProfile,k2p,K2P,mini.config,.config))
else ifeq ($(PROFILE),dir-882-r1)
  $(eval $(call DefineProfile,dir-882,DIR-882-R1,.config,.config))
else ifeq ($(PROFILE),dir-882-a1)
  $(eval $(call DefineProfile,dir-882,DIR-882-A1,.config,.config))
else
  $(error "Unknown PROFILE=$(PROFILE)")
endif

MAKE_ROUTER := $(MAKE) -C $(BUILD_DIR) -f Makefile.mt7621 BOARD=$(BOARD) DTS=$(DTS) RPROFILE=$(PROFILE) KERNEL_HEADER_ARCH=mips
PATH := $(TOOLCHAIN_DIR)/bin:$(TOP_DIR)/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
KERNEL := universal/linux-4.14
CRDA_URL := https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git

export PATH SVN

define PatchDir
	@if [ -d $(1) ] && [ "$$(ls $(1) | wc -l)" -gt 0 ]; then \
		for p in $(1)/*.patch; do \
			echo "== Applying $$p..."; \
			for f in $$(grep '^Index: ' $$p | awk '{print $$2}'); do \
				svn revert $(SRC_DIR)/$$f; \
			done; \
			patch -t -d $(SRC_DIR) -p0 < $$p || exit 1; \
		done \
	fi
endef

define VerifyLibpcapFixes
	@grep -Fq 'rm -f libpcap/scanner.c libpcap/scanner.h' "$(BUILD_DIR)/rules/libpcap.mk" || { echo "libpcap scanner regeneration patch was not applied" >&2; exit 1; }
	@grep -Fq -- '-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration' "$(BUILD_DIR)/rules/libpcap.mk" || { echo "libpcap legacy GCC compatibility flags were not applied" >&2; exit 1; }
	@grep -Fq '#ifndef _GNU_SOURCE' "$(BUILD_DIR)/libpcap/pcap-linux.c" || { echo "libpcap pcap-linux _GNU_SOURCE guard was not applied" >&2; exit 1; }
	@grep -Fq '  #ifndef _GNU_SOURCE' "$(BUILD_DIR)/libpcap/ftmacros.h" || { echo "libpcap ftmacros _GNU_SOURCE guard was not applied" >&2; exit 1; }
endef

define VerifyWolfsslArchiveFix
	@grep -Fq 'WOLFSSL_AR_FLAGS := cru' "$(BUILD_DIR)/rules/wolfssl.mk" || { echo "wolfSSL archive flags patch was not applied" >&2; exit 1; }
	@grep -Fq 'AR="$$(WOLFSSL_AR)"' "$(BUILD_DIR)/rules/wolfssl.mk" || { echo "wolfSSL LTO-aware archiver patch was not applied" >&2; exit 1; }
endef

define VerifyUpnpNetconfLinkFix
	@! grep -Fq -- '-lnetconf' "$(BUILD_DIR)/upnp/src/linux/Makefile" || { echo "UPnP still links the obsolete libnetconf dependency" >&2; exit 1; }
endef

define VerifyExportedKernelHeaders
	@set -eu; \
		kernel_release="$$(cat "$(LINUX_DIR)/include/config/kernel.release")"; \
		headers="$(BUILD_DIR)/kernel_headers/$$kernel_release/include"; \
		test -f "$$headers/linux/filter.h" || { echo "missing exported Linux filter header: $$headers/linux/filter.h" >&2; exit 1; }; \
		! grep -Fq '<linux/linkage.h>' "$$headers/linux/filter.h" || { echo "kernel-internal filter header leaked into exported headers" >&2; exit 1; }
endef

define VerifyKernelHeaderInjection
	@set -eu; \
		rules="$(BUILD_DIR)/rules"; \
		! grep -R -Fq -- '-I$$(LINUXDIR)/arch/mips/include/uapi -I$$(LINUXDIR)/include/uapi -I$$(LINUXDIR)/include' "$$rules" || { echo "raw kernel source headers remain in router rules" >&2; exit 1; }; \
		grep -R -Fq -- '-I$$(TOP)/kernel_headers/$$(KERNELRELEASE)/include' "$$rules" || { echo "exported kernel headers were not injected into router rules" >&2; exit 1; }
endef

define InjectPppdStatsFix
	@set -eu; \
		source="$(BUILD_DIR)/pppd/pppd/sys-linux.c"; \
		test -f "$$source" || { echo "missing pppd source: $$source" >&2; exit 1; }; \
		sed -i \
			-e 's@#[[:space:]]*include[[:space:]]*<linux/ppp_defs[.]h>@#include <linux/ppp-ioctl.h>@g' \
			-e 's@^[[:space:]]*#[[:space:]]*include[[:space:]]*<linux/if_ppp[.]h>.*$$@@' \
			-e 's@^[[:space:]]*struct[[:space:]][[:space:]]*ifpppstatsreq[[:space:]][[:space:]]*req;[[:space:]]*$$@    struct ifreq req; struct ppp_stats data;@' \
			-e 's@^[[:space:]]*req[.]stats_ptr[[:space:]]*=[[:space:]]*(caddr_t)[[:space:]]*&req[.]stats;[[:space:]]*$$@    req.ifr_data = (caddr_t) \&data;@' \
			-e 's@^[[:space:]]*strlcpy(req[.]ifr__name,[[:space:]]*ifname,[[:space:]]*sizeof(req[.]ifr__name));[[:space:]]*$$@    strlcpy(req.ifr_name, ifname, sizeof(req.ifr_name));@' \
			-e 's@req\.stats\.p\.ppp_ibytes@data.p.ppp_ibytes@g' \
			-e 's@req\.stats\.p\.ppp_obytes@data.p.ppp_obytes@g' \
			-e 's@req\.stats\.p\.ppp_ipackets@data.p.ppp_ipackets@g' \
			-e 's@req\.stats\.p\.ppp_opackets@data.p.ppp_opackets@g' \
			-- "$$source"; \
		grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]*<linux/ppp-ioctl[.]h>' "$$source" || { echo "pppd ioctl header injection failed" >&2; exit 1; }; \
		! grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]*<linux/if_ppp[.]h>' "$$source" || { echo "legacy pppd if_ppp header remains" >&2; exit 1; }
endef

define VerifyPppdStatsFix
	@set -eu; \
		source="$(BUILD_DIR)/pppd/pppd/sys-linux.c"; \
		grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]*<linux/ppp-ioctl[.]h>' "$$source" || { echo "pppd ioctl header was not selected" >&2; exit 1; }; \
		grep -Fq 'struct ifreq req;' "$$source" || { echo "pppd modern PPP statistics request fix was not applied" >&2; exit 1; }; \
		grep -Fq 'struct ppp_stats data;' "$$source" || { echo "pppd statistics payload fix was not applied" >&2; exit 1; }; \
		grep -Fq 'req.ifr_data = (caddr_t) &data;' "$$source" || { echo "pppd statistics data pointer fix was not applied" >&2; exit 1; }; \
		! grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]*<linux/ppp_defs[.]h>' "$$source" || { echo "legacy pppd definitions header remains" >&2; exit 1; }; \
		! grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]*<linux/if_ppp[.]h>' "$$source" || { echo "legacy pppd ioctl header remains" >&2; exit 1; }; \
		! grep -Fq 'struct ifpppstatsreq req;' "$$source" || { echo "pppd still depends on legacy ifpppstatsreq" >&2; exit 1; }; \
		! grep -Fq 'req.stats_ptr' "$$source" || { echo "pppd still uses legacy statistics pointer" >&2; exit 1; }; \
		! grep -Fq 'req.ifr__name' "$$source" || { echo "pppd still uses legacy interface-name field" >&2; exit 1; }; \
		! grep -Fq 'req.stats.p.' "$$source" || { echo "pppd still reads legacy statistics payload" >&2; exit 1; }
endef

define VerifyClosedDriverNVRAMHeaders
	@test -f "$(BUILD_DIR)/shared/ddnvram.h" || { echo "missing DD-WRT NVRAM API header: $(BUILD_DIR)/shared/ddnvram.h" >&2; exit 1; }
	@for source in "$(BUILD_DIR)/services/sysinit/sysinit-rt2880.c" "$(BUILD_DIR)/services/networking/wifi/rt2880.c" "$(BUILD_DIR)/httpd/visuals/wireless_ralink.c"; do test -f "$$source" && grep -Fq '#include <ddnvram.h>' "$$source" || { echo "closed-driver source did not receive the ddnvram.h compatibility update: $$source" >&2; exit 1; }; done

endef

define VerifyClosedDriverServicesHooks
	@for hook in 'void sys_overclocking(void)' 'void set_stp_state(char *bridge, char *stp)' 'void start_postnetwork(void)' 'void start_arch_defaults(void)'; do grep -Fq "$$hook" "$(BUILD_DIR)/services/sysinit/sysinit-rt2880.c" || { echo "closed-driver RT2880 services hook was not staged: $$hook" >&2; exit 1; }; done
endef

define VerifyRebasedPatches
	@grep -Fq '#if defined(HAVE_MICRO) || !defined(HAVE_PPTPD)' "$(BUILD_DIR)/httpd/visuals/menu.c" || { echo "httpd menu patch was not applied" >&2; exit 1; }
	@grep -Fq '#if defined(HAVE_SANSFIL) || !defined(HAVE_HOTSPOT)' "$(BUILD_DIR)/httpd/visuals/menu.c" || { echo "httpd hotspot menu patch was not applied" >&2; exit 1; }
	@grep -Fq '# SHOBJS += $$(TOP)/register/register_check.o' "$(BUILD_DIR)/libutils/Makefile" || { echo "libutils Madwifi object patch was not applied" >&2; exit 1; }
	@grep -Fq 'char *hostapd_eap_get_types(void)' "$(BUILD_DIR)/libutils/libshutils/shutils.c" || { echo "libutils compatibility stubs were not applied" >&2; exit 1; }
	@grep -Fq '#if defined(HAVE_RT2880) && !defined(HAVE_MT76)' "$(BUILD_DIR)/shared/wlutils.h" || { echo "shared Short-GI capability patch was not applied" >&2; exit 1; }
	@grep -Fq 'fakespace=errnos_' "$(BUILD_DIR)/vpnc/libgpg-error/src/Makefile.am" || { echo "libgpg-error awk compatibility is missing upstream" >&2; exit 1; }
endef

# Shared by every prepare profile.  Keep every sed program below as one quoted -e argument.
define InjectCMakeDependencyPaths
	@set -eu; \
		rules="$(BUILD_DIR)/rules"; \
		find "$$rules" -maxdepth 1 -type f -name '*.mk' -exec sed -i -e 's@-I$$(LINUXDIR)/arch/mips/include/uapi -I$$(LINUXDIR)/include/uapi -I$$(LINUXDIR)/include@-I$$(TOP)/kernel_headers/$$(KERNELRELEASE)/include@g' {} +; \
		inject_cmake_paths() { \
			rule="$$1"; target="$$2"; option_var="$$3"; path="$$rules/$$rule"; \
			[ -f "$$path" ] || return 0; \
			grep -Fq "$$target:" "$$path" || return 0; \
			grep -Fq '$$(call CMakeConfigure' "$$path" || return 0; \
			if grep -Fq 'DDWRT_LIBUBOX_CMAKE_PATHS' "$$path"; then return 0; fi; \
			sed -i -e "/^$$target:/i $$option_var += -Dubox_include_dir=\$$(TOP) -Dblobmsg_json_include_dir=\$$(TOP) -Djson_include_dir=\$$(TOP)/_staging/usr/include -DCMAKE_PREFIX_PATH=\$$(TOP)/_staging/usr -DCMAKE_INCLUDE_PATH=\$$(TOP) -DCMAKE_LIBRARY_PATH=\$$(TOP)/libubox # DDWRT_LIBUBOX_CMAKE_PATHS" -- "$$path"; \
			grep -Fq 'DDWRT_LIBUBOX_CMAKE_PATHS' "$$path" || { echo "CMake dependency path injection failed: $$rule:$$target" >&2; exit 1; }; \
		}; \
		inject_cmake_paths libubox.mk libubox-configure UBOX_CMAKE_OPTIONS; \
		inject_cmake_paths ubus.mk ubus-configure UBUS_CMAKE_OPTIONS; \
		inject_cmake_paths uqmi.mk uqmi-configure UQMI_CMAKE_OPTIONS; \
		inject_cmake_paths usteer.mk usteer-configure USTEER_CMAKE_OPTIONS; \
		inject_cmake_paths dawn.mk dawn-configure DAWN_CMAKE_OPTIONS; \
		inject_cmake_paths uci.mk uci-configure UCI_CMAKE_OPTIONS; \
		inject_cmake_paths rpcd.mk rpcd-configure RPCD_CMAKE_OPTIONS; \
		inject_cmake_paths uhttpd.mk uhttpd-configure UHTTPD_CMAKE_OPTIONS; \
		inject_cmake_paths ustream-ssl.mk ustream-ssl-configure USTREAM_SSL_CMAKE_OPTIONS; \
		inject_cmake_paths ustream.mk ustream-configure USTREAM_CMAKE_OPTIONS; \
		inject_cmake_paths procd.mk procd-configure PROCD_CMAKE_OPTIONS; \
		inject_cmake_paths fstools.mk fstools-configure FSTOOLS_CMAKE_OPTIONS; \
		inject_cmake_paths netifd.mk netifd-configure NETIFD_CMAKE_OPTIONS; \
		inject_cmake_paths odhcpd.mk odhcpd-configure ODHCPD_CMAKE_OPTIONS; \
		inject_cmake_paths jshn.mk jshn-configure JSHN_CMAKE_OPTIONS; \
		ubox="$$rules/libubox.mk"; \
		if [ -f "$$ubox" ] && grep -Fq 'libubox-configure:' "$$ubox" && ! grep -Fq 'DDWRT_LIBUBOX_CONFIG_DEPS' "$$ubox"; then \
			sed -i -e '/^libubox-configure:/i libubox-configure: json-c # DDWRT_LIBUBOX_CONFIG_DEPS' -- "$$ubox"; \
		fi; \
		ubus="$$rules/ubus.mk"; \
		if [ -f "$$ubus" ] && grep -Fq 'ubus-configure:' "$$ubus" && ! grep -Fq 'DDWRT_UBUS_CONFIG_DEPS' "$$ubus"; then \
			sed -i -e '/^ubus-configure:/i ubus-configure: json-c libubox-configure libubox # DDWRT_UBUS_CONFIG_DEPS' -- "$$ubus"; \
		fi; \
		inject_libnltiny_dependency() { \
			rule="$$1"; target="$$2"; path="$$rules/$$rule"; marker="DDWRT_LIBNLTINY_DEPS_$$target"; \
			[ -f "$$path" ] || return 0; \
			grep -Fq 'libnl-tiny' "$$path" || return 0; \
			grep -Fq "$$target:" "$$path" || return 0; \
			if grep -Fq "$$marker" "$$path" || grep -Fq "$$target: libnltiny" "$$path"; then return 0; fi; \
			sed -i -e "/^$$target:/i $$target: libnltiny # $$marker" -- "$$path"; \
		}; \
		inject_libnltiny_dependency usteer.mk usteer-configure; \
		inject_libnltiny_dependency usteer.mk usteer; \
		inject_libnltiny_dependency cfm.mk cfm-configure; \
		inject_libnltiny_dependency cfm.mk cfm; \
		inject_libnltiny_dependency batman-adv.mk batman-adv; \
		htop="$$rules/htop.mk"; \
		if [ -f "$$htop" ] && grep -Fq 'htop-configure:' "$$htop"; then \
			if ! sed -n '/^[[:space:]]*CFLAGS="/p' "$$htop" | grep -Fq -- '-I$$(TOP)/libnl/include'; then \
				sed -i -e '/^[[:space:]]*CFLAGS="/ s@CFLAGS="@CFLAGS="-I$$(TOP)/libnl/include @' -- "$$htop"; \
			fi; \
			if ! grep -Fq 'DDWRT_HTOP_LIBNL_HEADERS' "$$htop"; then \
				sed -i -e '/^htop-configure:/i # DDWRT_HTOP_LIBNL_HEADERS' -- "$$htop"; \
			fi; \
			if ! sed -n '/^[[:space:]]*CFLAGS="/p' "$$htop" | grep -Fq -- '-I$$(TOP)/libnl/include'; then \
				echo "htop libnl header injection failed" >&2; exit 1; \
			fi; \
		fi; \
		comgt="$$rules/comgt.mk"; \
		if [ -f "$$comgt" ] && grep -Fq '$$(MAKE) -C usb_modeswitch configure' "$$comgt" && ! grep -Fq 'DDWRT_COMGT_KERNEL_HEADERS' "$$comgt"; then \
			sed -i -e '/^comgt-configure:/i comgt-configure comgt: export COPTS += -I$$(TOP)/kernel_headers/$$(KERNELRELEASE)/include # DDWRT_COMGT_KERNEL_HEADERS' -- "$$comgt"; \
			grep -Fq 'DDWRT_COMGT_KERNEL_HEADERS' "$$comgt" || { echo "comgt kernel UAPI header injection failed" >&2; exit 1; }; \
		fi; \
		inject_kernel_uapi_headers() { \
			rule="$$1"; target="$$2"; path="$$rules/$$rule"; marker="DDWRT_KERNEL_UAPI_CPPFLAGS_$$target"; \
			[ -f "$$path" ] || return 0; \
			grep -Fq "$$target:" "$$path" || return 0; \
			if grep -Fq "$$marker" "$$path"; then return 0; fi; \
			sed -i -e "/^$$target:/i $$target: export CPPFLAGS += -I\$$(TOP)/kernel_headers/\$$(KERNELRELEASE)/include # $$marker" -- "$$path"; \
			grep -Fq "$$marker" "$$path" || { echo "kernel UAPI header injection failed: $$rule:$$target" >&2; exit 1; }; \
		}; \
		nft="$$rules/nftables.mk"; \
		if [ -f "$$nft" ] && grep -Fq 'libnftnl-configure:' "$$nft" && ! grep -Fq 'DDWRT_LIBNFTNL_DEPS' "$$nft"; then \
			sed -i -e '/^libnftnl-configure:/i libnftnl-configure: libmnl # DDWRT_LIBNFTNL_DEPS' -- "$$nft"; \
			sed -i -e '/^libnftnl:/i libnftnl: libmnl # DDWRT_LIBNFTNL_DEPS' -- "$$nft"; \
		fi; \
		if [ -f "$$nft" ] && grep -Fq 'libnftnl-configure:' "$$nft" && grep -Fq 'LIBMNL_CPPFLAGS' "$$nft"; then \
			sed -i -e 's@LIBMNL_CPPFLAGS=@LIBMNL_CFLAGS=@g' -- "$$nft"; \
		fi; \
		inject_kernel_uapi_headers libmnl.mk libmnl-configure; \
		inject_kernel_uapi_headers libnl.mk libnl-configure; \
		inject_kernel_uapi_headers libnltiny.mk libnltiny; \
		inject_kernel_uapi_headers libnfnetlink.mk libnfnetlink-configure; \
		inject_kernel_uapi_headers libnetfilter_log.mk libnetfilter_log-configure; \
		inject_kernel_uapi_headers libnetfilter_queue.mk libnetfilter_queue-configure; \
		inject_kernel_uapi_headers nftables.mk libnftnl-configure; \
		inject_kernel_uapi_headers nftables.mk nftables-configure; \
		inject_kernel_uapi_headers iptables-new.mk iptables-new-configure; \
		inject_kernel_uapi_headers ipsec-tools.mk ipsec-tools-configure; \
		inject_kernel_uapi_headers bird.mk bird-configure; \
		inject_kernel_uapi_headers quagga.mk quagga-configure; \
		inject_kernel_uapi_headers frr.mk frr-configure; \
		inject_kernel_uapi_headers strongswan.mk strongswan-configure; \
		inject_kernel_uapi_headers openvpn.mk openvpn-configure; \
		inject_kernel_uapi_headers pptpd.mk pptpd-configure; \
		inject_kernel_uapi_headers radvd.mk radvd-configure; \
		inject_kernel_uapi_headers wireguard.mk wireguard-configure; \
		inject_make_copts_headers() { \
			rule="$$1"; target="$$2"; path="$$rules/$$rule"; marker="DDWRT_KERNEL_UAPI_COPTS_$$target"; \
			[ -f "$$path" ] || return 0; \
			grep -Fq "$$target:" "$$path" || return 0; \
			grep -Fq ' -C ' "$$path" || return 0; \
			if grep -Fq "$$marker" "$$path"; then return 0; fi; \
			sed -i -e "/^$$target:/i $$target: export COPTS += -I\$$(TOP)/kernel_headers/\$$(KERNELRELEASE)/include # $$marker" -- "$$path"; \
			grep -Fq "$$marker" "$$path" || { echo "kernel UAPI COPTS injection failed: $$rule:$$target" >&2; exit 1; }; \
		}; \
		inject_make_copts_headers iproute2.mk iproute2; \
		inject_make_copts_headers iptables.mk iptables; \
		inject_make_copts_headers ppp.mk ppp; \
		inject_make_copts_headers pppd.mk pppd; \
		inject_make_copts_headers xl2tpd.mk xl2tpd-configure; \
		inject_make_copts_headers batman-adv.mk batman-adv; \
		inject_make_copts_headers l2tpv3tun.mk l2tpv3tun-configure; \
		inject_make_copts_headers pptp-client.mk pptp-client; \
		minidlna_rule="$$rules/minidlna.mk"; \
		if [ -f "$$minidlna_rule" ] && grep -Fq 'minidlna-configure:' "$$minidlna_rule"; then \
			if ! grep -Fq 'DDWRT_MINIDLNA_OGG_CFLAGS' "$$minidlna_rule"; then \
				sed -i -e '/^minidlna-configure:/i minidlna-configure minidlna: export OGG_CFLAGS += -I$$(TOP)/minidlna/libogg-1.3.5/include # DDWRT_MINIDLNA_OGG_CFLAGS' -- "$$minidlna_rule"; \
			fi; \
			if ! grep -Fq 'DDWRT_MINIDLNA_OGG_LIBS' "$$minidlna_rule"; then \
				sed -i -e '/^minidlna-configure:/i minidlna-configure minidlna: export OGG_LIBS += -L$$(TOP)/minidlna/libogg-1.3.5/src/.libs -logg # DDWRT_MINIDLNA_OGG_LIBS' -- "$$minidlna_rule"; \
			fi; \
			grep -Fq 'DDWRT_MINIDLNA_OGG_CFLAGS' "$$minidlna_rule" && grep -Fq 'DDWRT_MINIDLNA_OGG_LIBS' "$$minidlna_rule" || { echo "MiniDLNA Ogg flags injection failed" >&2; exit 1; }; \
		fi; \
		minidlna_makefile="$(BUILD_DIR)/minidlna/Makefile"; \
		if [ -f "$$minidlna_makefile" ]; then \
			if grep -Fq 'libvorbis:' "$$minidlna_makefile"; then \
				if ! grep -Fq -- '--with-ogg-includes=' "$$minidlna_makefile" || ! grep -Fq -- '--with-ogg-libraries=' "$$minidlna_makefile"; then \
					sed -i -e '/^[[:space:]]*cd libvorbis-1[.]3[.]7/ s@--disable-shared@--disable-shared --with-ogg-includes=$$(MINI_DLNA_PATH)/libogg-1.3.5/include --with-ogg-libraries=$$(MINI_DLNA_PATH)/libogg-1.3.5/src/.libs@' -e '/^libvorbis:/i # DDWRT_MINIDLNA_OGG_PATHS' -- "$$minidlna_makefile"; \
				fi; \
				grep -Fq -- '--with-ogg-includes=' "$$minidlna_makefile" && grep -Fq -- '--with-ogg-libraries=' "$$minidlna_makefile" || { echo "MiniDLNA libvorbis Ogg path injection failed" >&2; exit 1; }; \
			fi; \
			if grep -Fq 'LTOPLUGIN' "$$minidlna_makefile"; then \
				sed -i -e 's@AR_FLAGS="\\\"cru \$$(LTOPLUGIN)\\\""@AR_FLAGS=cru@g' -e 's@RANLIB="\$$(ARCH)-linux-ranlib \$$(LTOPLUGIN)"@RANLIB="$$(CROSS_COMPILE)gcc-ranlib"@g' -- "$$minidlna_makefile"; \
			fi; \
			if ! grep -Fq 'DDWRT_MINIDLNA_AR_FLAGS' "$$minidlna_makefile"; then \
				sed -i -e '/^libvorbis:/i # DDWRT_MINIDLNA_AR_FLAGS' -- "$$minidlna_makefile"; \
			fi; \
			if grep -E '(^|[[:space:]])(AR_FLAGS|RANLIB)=' "$$minidlna_makefile" | grep -Fq 'LTOPLUGIN'; then \
				echo "MiniDLNA archiver still embeds LTO plugin in AR_FLAGS or RANLIB" >&2; exit 1; \
			fi; \
			grep -Fq 'AR_FLAGS=cru' "$$minidlna_makefile" || { echo "MiniDLNA archiver flags injection failed" >&2; exit 1; }; \
			grep -Fq 'RANLIB="$$(CROSS_COMPILE)gcc-ranlib"' "$$minidlna_makefile" || { echo "MiniDLNA ranlib injection failed" >&2; exit 1; }; \
		fi
endef

all:
	$(MAKE_ROUTER) kernel
	$(MAKE_ROUTER) all
	$(MAKE_ROUTER) install
	$(MAKE_ROUTER) image

	mkdir -p images && cp $(BUILD_DIR)/mipsel-uclibc/dd-wrt-v3.0-*.bin images

checkout:
	-[ -d "$(SRC_DIR)" ] && svn cleanup $(SRC_DIR)
	$(SVN) co $(SRC_URL) -r $(REVISION) $(SRC_DIR) --depth immediates --quiet
	@for d1 in $$($(SVN) ls $(SRC_DIR) | grep '/$$'); do \
		[ "$$d1" = "ar5315_microredboot/" -o "$$d1" = "redboot/" ] && continue; \
		echo "== Updating $$d1"; \
		$(SVN) up -r $(REVISION) $(SRC_DIR)/$$d1 --set-depth immediates --quiet; \
		for d2 in $$($(SVN) ls $(SRC_DIR)/$$d1 | grep '/$$'); do \
			echo "== Updating $$d1$$d2"; \
			if [ "$$d1$$d2" = "src/linux/" ]; then \
				$(SVN) up -r $(REVISION) $(SRC_DIR)/$$d1$$d2 --set-depth immediates --quiet; \
			else \
				$(SVN) up -r $(REVISION) $(SRC_DIR)/$$d1$$d2 --set-depth infinity --quiet; \
			fi; \
		done; \
	done

	$(SVN) up -r $(REVISION) $(SRC_DIR)/src/linux/$(KERNEL) --set-depth infinity --quiet

	cp $(TOP_DIR)/files/router/Makefile.mt7621 $(BUILD_DIR)/Makefile.mt7621
	cp $(TOP_DIR)/configs/$(BOARD)/$(subst mini,,$(CONFIG)) $(BUILD_DIR)/.config

toolchain:
	@if [ ! -x "$(TOOLCHAIN_GCC)" ]; then \
		tmp=$$(mktemp "$(TOP_DIR)/.$(TOOLCHAIN_ARCHIVE).XXXXXX") || exit 1; \
		if ! curl --fail --location --proto '=https' --retry 4 --retry-all-errors \
			--connect-timeout 30 --output "$$tmp" "$(TOOLCHAIN_URL)"; then \
			rm -f "$$tmp"; \
			exit 1; \
		fi; \
		if ! tar --extract --gzip --file "$$tmp" --directory "$(TOP_DIR)"; then \
			rm -f "$$tmp"; \
			exit 1; \
		fi; \
		rm -f "$$tmp"; \
	fi
	@test -x "$(TOOLCHAIN_GCC)" || { echo "missing expected toolchain compiler: $(TOOLCHAIN_GCC)" >&2; exit 1; }
	@"$(TOOLCHAIN_GCC)" --version >/dev/null

prepare: toolchain
	$(call PatchDir,$(TOP_DIR)/patches)
	$(call InjectPppdStatsFix)
	$(call VerifyPppdStatsFix)
	$(call VerifyRebasedPatches)
	$(call VerifyLibpcapFixes)
	$(call VerifyWolfsslArchiveFix)
	$(call VerifyUpnpNetconfLinkFix)
	$(call PatchDir,$(TOP_DIR)/patches/$(BOARD))
ifneq (,$(findstring mt76,$(PROFILE)))
	$(call PatchDir,$(TOP_DIR)/patches/mt76)
	[ -d $(BUILD_DIR)/crda ] || git clone $(CRDA_URL) $(BUILD_DIR)/crda
	echo "#!/bin/sh\n\necho crda called" > $(BUILD_DIR)/crda/crda.sh
	chmod +x $(BUILD_DIR)/crda/crda.sh
	ln -sf mac80211 $(BUILD_DIR)/compat-wireless
else
	$(call PatchDir,$(TOP_DIR)/patches/drv)
	rm -rf $(LINUX_DIR)/drivers/net/ethernet/raeth
	rm -rf $(LINUX_DIR)/net/nat/foe_hook
	cp -r $(TOP_DIR)/files/linux/drivers $(LINUX_DIR)/
	cp -r $(TOP_DIR)/files/linux/include $(LINUX_DIR)/
	cp -r $(TOP_DIR)/files/linux/net $(LINUX_DIR)/
	cp -r $(TOP_DIR)/files/router/* $(BUILD_DIR)/
	$(call VerifyClosedDriverNVRAMHeaders)
	$(call VerifyClosedDriverServicesHooks)
endif
	cp $(TOP_DIR)/configs/$(BOARD)/dts/$(DTS).dts $(LINUX_DIR)/dts/$(DTS).dts
	cp $(TOP_DIR)/configs/$(BOARD)/kernel/$(KCONFIG) $(LINUX_DIR)/.config
	cp $(TOP_DIR)/configs/$(BOARD)/$(CONFIG) $(BUILD_DIR)/.config
	ln -sf ../../opt $(BUILD_DIR)/opt
	cp $(LINUX_DIR)/drivers/net/wireless/Kconfig.dir882 $(LINUX_DIR)/drivers/net/wireless/Kconfig

	$(MAKE) -C "$(LINUX_DIR)" ARCH=mips CROSS_COMPILE=mipsel-linux-uclibc- olddefconfig prepare
	$(MAKE_ROUTER) install_headers
	$(call VerifyExportedKernelHeaders)
	$(call InjectCMakeDependencyPaths)
	$(call VerifyKernelHeaderInjection)
	python3 "$(TOP_DIR)/tools/fix-ar-flags.py" "$(BUILD_DIR)/rules" "$(BUILD_DIR)/Makefile.mt7621"
	$(MAKE_ROUTER) gen_revision

configure:
	$(MAKE_ROUTER) ncurses-configure ncurses
	$(MAKE_ROUTER) zlib-configure zlib
	$(MAKE_ROUTER) libffi-configure libffi
	$(MAKE_ROUTER) libnl-configure libnl
	$(MAKE_ROUTER) libpcap-configure libpcap
	$(MAKE_ROUTER) libucontext-configure libucontext
	$(MAKE_ROUTER) openssl-configure openssl
	$(MAKE_ROUTER) libevent-configure libevent
	$(MAKE_ROUTER) curl-configure curl
	$(MAKE_ROUTER) gmp-configure gmp
	$(MAKE_ROUTER) wolfssl-configure wolfssl
	$(MAKE_ROUTER) pcre-configure pcre
	$(MAKE_ROUTER) nettle-configure nettle
	$(MAKE_ROUTER) configure

httpd:
	$(MAKE_ROUTER) libutils-clean libutils
	$(MAKE_ROUTER) rc-clean rc
	$(MAKE_ROUTER) services-clean services
	$(MAKE_ROUTER) language routerstyle
	$(MAKE_ROUTER) httpd-clean httpd

gen_patches:
	@(cd $(SRC_DIR); \
		svn diff src/router/services/sysinit/defaults.c \
				src/router/services/sysinit/sysinit.c > $(TOP_DIR)/patches/k2p/defaults.patch; \
		svn diff src/router/libutils/libutils/detect.c \
				src/router/libutils/libutils/gpio.c \
				src/router/libutils/libutils/ledconfig.c \
				src/router/rc/resetbutton.c > $(TOP_DIR)/patches/k2p/k2p.patch; \
		svn diff src/router/kromo/dd-wrt/Makefile > $(TOP_DIR)/patches/k2p/kromo.patch; \
		svn diff src/router/services/sysinit/devinit.c > $(TOP_DIR)/patches/devinit.patch; \
		svn diff src/router/glib20/libglib/gio/meson.build \
				src/router/glib20/libglib/meson.build  > $(TOP_DIR)/patches/glib20.patch; \
		svn diff src/router/httpd/visuals/menu.c \
				src/router/httpd/visuals/dd-wrt.c > $(TOP_DIR)/patches/httpd.patch; \
		svn diff src/router/libpcap/pcap-linux.c \
				src/router/libpcap/ftmacros.h > $(TOP_DIR)/patches/libpcap.patch; \
		svn diff src/router/libutils/Makefile \
				src/router/libutils/libshutils/shutils.c > $(TOP_DIR)/patches/libutils.patch; \
		svn diff src/router/mactelnet/Makefile > $(TOP_DIR)/patches/mactelnet.patch; \
		svn diff src/router/ntfs3/Makefile > $(TOP_DIR)/patches/ntfs3.patch; \
		svn diff src/router/olsrd/src/cfgparser/local.mk > $(TOP_DIR)/patches/olsrd.patch; \
		svn diff src/router/rules > $(TOP_DIR)/patches/rules.patch; \
		svn diff src/router/shared > $(TOP_DIR)/patches/shared.patch; \
		svn diff src/router/mac80211/drivers/net/wireless/Kconfig \
				src/router/mac80211/drivers/net/wireless/mediatek/mt76/Kconfig > $(TOP_DIR)/patches/mt76/mac80211.patch; \
		svn diff src/router/mac80211/drivers/net/wireless/mediatek/mt76 > $(TOP_DIR)/patches/mt76/mt76.patch; \
		svn diff src/linux/universal/linux-4.14/drivers/net/wireless/Kconfig.dir882 \
				src/linux/universal/linux-4.14/drivers/net/wireless/Makefile > $(TOP_DIR)/patches/drv/mt7615.patch; \
		svn diff src/router/others/Makefile > $(TOP_DIR)/patches/drv/others.patch; \
		svn diff src/router/rc/rc.c src/router/rc/Makefile > $(TOP_DIR)/patches/drv/mtk_esw.patch; \
		svn diff src/linux/universal/linux-4.14/net/wireless/wext-core.c > $(TOP_DIR)/patches/drv/wext-core.patch; \
		svn diff src/linux/universal/linux-4.14/dts/mt7621.dtsi \
				src/linux/universal/linux-4.14/net/Kconfig \
				src/linux/universal/linux-4.14/net/Makefile \
				src/linux/universal/linux-4.14/drivers/net/ethernet/Kconfig > $(TOP_DIR)/patches/drv/hw_nat.patch; \
		svn diff src/linux/universal/linux-4.14/net/ipv4/Kconfig \
				src/linux/universal/linux-4.14/net/ipv4/Makefile > $(TOP_DIR)/patches/drv/inet_lro.patch; \
		svn diff src/linux/universal/linux-4.14/include/linux/serial_core.h > $(TOP_DIR)/patches/serial.patch; \
		svn diff src/router/libutils/libwireless/wl.c > $(TOP_DIR)/patches/drv/libwireless.patch; \
		svn diff src/router/services/Makefile > $(TOP_DIR)/patches/drv/services.patch; \
	)

%:
	$(MAKE_ROUTER) $*

.PHONY: all checkout toolchain prepare configure httpd gen_patches
