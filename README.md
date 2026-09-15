# DD-WRT

dd-wrt build scripts and patches for MT7621, with ethernet/wireless drivers from [padavan](https://github.com/tsl0922/padavan) and Hardware NAT over `WAN<->LAN/WLAN`.

**Supported devices:**

- [PHICOMM K2P](https://openwrt.org/toh/phicomm/k2p_ke2p)
- [D-Link DIR-882 A1/R1](https://openwrt.org/toh/d-link/dir-882_a1)

## Prerequisites

Ubuntu 22.04 LTS (the dependency list is also compatible with Ubuntu 24.04 LTS).

```bash
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    autoconf-archive automake autopoint bc bison build-essential bzip2 ca-certificates \
    ccache cmake cpio curl fakeroot file flex gawk gengetopt gettext git gperf gzip \
    gtk-doc-tools help2man kmod libc-dev-bin libgmp-dev libltdl-dev libmpc-dev \
    libmpfr-dev libncurses-dev libtool-bin meson nano ninja-build patch perl pkg-config \
    python-is-python3 python3 python3-docutils rsync subversion tar texinfo unzip wget xxd \
    xz-utils zip zlib1g-dev

# Use Node.js 24 LTS, then install the pinned frontend minifiers without sudo.
NPM_TOOL_PREFIX="$PWD/.npm-tools"
npm install --prefix "$NPM_TOOL_PREFIX" --no-save --package-lock=false --no-audit --no-fund \
    --ignore-scripts uglify-js@3.19.3 uglifycss@0.0.29
ln -sfn "$NPM_TOOL_PREFIX/node_modules/.bin/uglifyjs" tools/uglifyjs
ln -sfn "$NPM_TOOL_PREFIX/node_modules/.bin/uglifycss" tools/uglifycss
ln -sfn "$(command -v node)" tools/node
```

The generated `tools/` links deliberately keep the selected Node.js runtime and the
two minifiers on the PATH that the top-level Makefile exports to DD-WRT.

## Build Instructions

```
echo PROFILE=k2p > .config
make checkout
make prepare
make configure
make all
```

supported profiles are: `k2p k2p-mini k2p-mt76 dir-882-a1 dir-882-r1`.

`make prepare` downloads the pinned `toolchain-mipsel_24kc_gcc-13.1.0_musl.tar.gz`
only when it is missing, extracts it, and verifies the expected cross compiler. The
archive is hosted at the [toolchain release](https://github.com/tsl0922/DD-WRT/releases/download/toolchain/toolchain-mipsel_24kc_gcc-13.1.0_musl.tar.gz).

## K2P profile and delivery contract

- `k2p` and `k2p-mini` use the existing Padavan-derived closed MT7615 driver
  and HW NAT path. `k2p-mt76` remains the separate open `mt76` path.
- PPPoE and IPv6 are enabled in all three router profiles. Their kernels retain
  SFE, Netfilter Flow Offload and hardware Flow Offload support; closed profiles
  additionally retain the original HW NAT settings. The prepare-time contract
  verifies these settings rather than adding a competing runtime firewall rule.
- Closed K2P profiles retain their existing WDS, AP-client, MAC-repeater,
  802.11k and 802.11r feature selections. This is a build capability check, not
  a substitute for configuring and testing a particular wireless topology.
- The K2P DTS and image recipe intentionally keep the public `0x50000` Breed
  layout. When flashing through Breed, select that same public layout; do not
  use this image with a different flash-layout selection.

`k2p-lede-blob` is a separate, manual-only GitHub Actions workflow. It fetches
a caller-supplied immutable `coolsnowwolf/lede` commit and a SHA-256-pinned K2P
configuration in `$RUNNER_TEMP`, then verifies the MT7615 package plus AP-client,
MAC-repeater, 802.11k and 802.11r selections. Its default source preflight does
not use this DD-WRT tree or publish an artifact. Setting `build_image` explicitly
builds only a separate `images-k2p-lede-blob` artifact; it is never consumed by
the DD-WRT release job. Hardware validation of that pinned configuration remains
required before treating the LEDE image as deployable.
