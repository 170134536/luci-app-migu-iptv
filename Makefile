#
# Copyright (C) 2026
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-migu-iptv
PKG_VERSION:=1.1.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Migu IPTV Relay

LUCI_TITLE:=咪咕直播（Migu IPTV Relay）
LUCI_DESCRIPTION:=Fetch Migu Video live channels and relay them to a TV-BOX as a \
	standard M3U playlist. Provides /m3u and /txt playlists, on-demand stream \
	resolution (/ch/<pid>) with 302 redirect to the final HLS URL, and a \
	standalone admin web panel (/admin) for Migu userId/token, quality rate, \
	and channel testing. Guest mode up to 540p; a Migu account token unlocks \
	720p and VIP unlocks 1080p/original/4K. No Node.js or Docker required.
LUCI_DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uloop +ucode-mod-socket \
	+ucode-mod-uci +curl +openssl-util +rpcd +luci-base
LUCI_PKGARCH:=all

define Package/luci-app-migu-iptv/conffiles
/etc/config/migu
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-migu-iptv))
