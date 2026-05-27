ARCHS = armv7
TARGET = iphone:clang:latest:6.0

# SpringBoard (UI) + BTServer (the iOS 6 BT daemon, force-loaded via the
# DYLD_INSERT_LIBRARIES plist patch since MobileSubstrate won't inject it).
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AirPodsReconnectFix
AirPodsReconnectFix_FILES = ../../Tweak.x
AirPodsReconnectFix_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
