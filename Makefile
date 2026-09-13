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

MAKE_ROUTER := $(MAKE) -C $(BUILD_DIR) -f Makefile.mt7621 BOARD=$(BOARD) DTS=$(DTS) RPROFILE=$(PROFILE)
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

define VerifyRebasedPatches
	@grep -Fq '#if defined(HAVE_MICRO) || !defined(HAVE_PPTPD)' "$(BUILD_DIR)/httpd/visuals/menu.c" || { echo "httpd menu patch was not applied" >&2; exit 1; }
	@grep -Fq '#if defined(HAVE_SANSFIL) || !defined(HAVE_HOTSPOT)' "$(BUILD_DIR)/httpd/visuals/menu.c" || { echo "httpd hotspot menu patch was not applied" >&2; exit 1; }
	@grep -Fq '# SHOBJS += $$(TOP)/register/register_check.o' "$(BUILD_DIR)/libutils/Makefile" || { echo "libutils Madwifi object patch was not applied" >&2; exit 1; }
	@grep -Fq 'char *hostapd_eap_get_types(void)' "$(BUILD_DIR)/libutils/libshutils/shutils.c" || { echo "libutils compatibility stubs were not applied" >&2; exit 1; }
	@grep -Fq '#if defined(HAVE_RT2880) && !defined(HAVE_MT76)' "$(BUILD_DIR)/shared/wlutils.h" || { echo "shared Short-GI capability patch was not applied" >&2; exit 1; }
	@grep -Fq 'fakespace=errnos_' "$(BUILD_DIR)/vpnc/libgpg-error/src/Makefile.am" || { echo "libgpg-error awk compatibility is missing upstream" >&2; exit 1; }
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
	$(call VerifyRebasedPatches)
	$(call VerifyLibpcapFixes)
	$(call VerifyWolfsslArchiveFix)
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
endif
	cp $(TOP_DIR)/configs/$(BOARD)/dts/$(DTS).dts $(LINUX_DIR)/dts/$(DTS).dts
	cp $(TOP_DIR)/configs/$(BOARD)/kernel/$(KCONFIG) $(LINUX_DIR)/.config
	cp $(TOP_DIR)/configs/$(BOARD)/$(CONFIG) $(BUILD_DIR)/.config
	ln -sf ../../opt $(BUILD_DIR)/opt
	cp $(LINUX_DIR)/drivers/net/wireless/Kconfig.dir882 $(LINUX_DIR)/drivers/net/wireless/Kconfig

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
