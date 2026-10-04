ARCHS := arm64e
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME := roothide
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = carplayenableprefs

carplayenableprefs_FILES = $(wildcard *.m) ../src/CRPreferences.mm
carplayenableprefs_INSTALL_PATH = /Library/PreferenceBundles
carplayenableprefs_FRAMEWORKS = UIKit
carplayenableprefs_PRIVATE_FRAMEWORKS = Preferences
carplayenableprefs_CFLAGS = -fobjc-arc -Wno-unused-variable

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/carplayenableprefs.plist$(ECHO_END)
