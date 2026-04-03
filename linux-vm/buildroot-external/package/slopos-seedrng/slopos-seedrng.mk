################################################################################
#
# slopos-seedrng
#
################################################################################

SLOPOS_SEEDRNG_VERSION = 1
SLOPOS_SEEDRNG_SITE = $(SLOPOS_SEEDRNG_PKGDIR)
SLOPOS_SEEDRNG_SITE_METHOD = local
SLOPOS_SEEDRNG_LICENSE = GPL-2.0 OR Apache-2.0 OR MIT OR BSD-1-Clause OR CC0-1.0

define SLOPOS_SEEDRNG_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)"
endef

define SLOPOS_SEEDRNG_INSTALL_TARGET_CMDS
	rm -f $(TARGET_DIR)/usr/sbin/seedrng
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		DESTDIR="$(TARGET_DIR)" \
		PREFIX=/usr \
		SBINDIR=/usr/sbin \
		install
endef

define SLOPOS_SEEDRNG_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(SLOPOS_SEEDRNG_PKGDIR)/S01seedrng \
		$(TARGET_DIR)/etc/init.d/S01seedrng
endef

$(eval $(generic-package))
