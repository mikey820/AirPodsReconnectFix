TARGET = iphone:clang:latest:14.0
# bluetoothd is a daemon; SpringBoard is the UI process. We inject into both.
INSTALL_TARGET_PROCESSES = SpringBoard bluetoothd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AirPodsReconnectFix

AirPodsReconnectFix_FILES = ../Tweak.x
AirPodsReconnectFix_CFLAGS = -fobjc-arc
AirPodsReconnectFix_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk
