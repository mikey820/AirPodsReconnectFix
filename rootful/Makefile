# iOS 6 / 32-bit. iPhone 4S is armv7; iPhone 5/5c are armv7s. Build both.
ARCHS = armv7 armv7s
# SDK is whatever the CI dropped into $THEOS/sdks (an old armv7-capable SDK);
# deployment target is iOS 6.0.
TARGET = iphone:clang:latest:6.0

# bluetoothd is the BT daemon; SpringBoard is the UI process. Inject into both.
INSTALL_TARGET_PROCESSES = SpringBoard bluetoothd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AirPodsReconnectFix

AirPodsReconnectFix_FILES = ../Tweak.x
AirPodsReconnectFix_CFLAGS = -fobjc-arc
# No -segalign needed for armv7; keep flags minimal for the old toolchain.

include $(THEOS_MAKE_PATH)/tweak.mk
