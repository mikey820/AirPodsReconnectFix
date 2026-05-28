ARCHS = armv7
TARGET = iphone:clang:latest:6.0

# SpringBoard only — the fix is audio-route bouncing via MediaPlayer's
# MPAVRoutingController, all reachable here. (We abandoned BTServer injection:
# dyld strips DYLD_INSERT on that restricted daemon.)
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AirPodsReconnectFix
AirPodsReconnectFix_FILES = ../../Tweak.x
AirPodsReconnectFix_CFLAGS = -fobjc-arc
# MPAVRoutingController lives in MediaPlayer; link it so the class is present.
AirPodsReconnectFix_FRAMEWORKS = MediaPlayer

include $(THEOS_MAKE_PATH)/tweak.mk
