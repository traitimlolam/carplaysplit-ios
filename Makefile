ARCHS := arm64e
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME := roothide
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = carplaysplit
carplaysplit_FILES = src/hooks/SpringBoard.xm src/hooks/CarPlay.xm $(wildcard src/*.mm) $(wildcard src/crash_reporting/*.mm)
carplaysplit_CFLAGS = -Wno-unused-variable -Wno-unused-function -fno-objc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-carplaysplit-stage::
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN/
	cp postinst_postrm $(THEOS_STAGING_DIR)/DEBIAN/postinst
	cp postinst_postrm $(THEOS_STAGING_DIR)/DEBIAN/postrm
	chmod +x $(THEOS_STAGING_DIR)/DEBIAN/post*

SUBPROJECTS += carplayenableprefs

include $(THEOS_MAKE_PATH)/aggregate.mk
