ARCHS = armv7
TARGET = iphone:clang:latest:6.0

# SpringBoard: the disconnect fix (pre-emptive re-assert). Music: the route-heal
# (re-pick the AirPods output) — must run in the audio-owning process because
# SpringBoard's MPAudioDeviceController is blind (nRoutes=1, confirmed on-device).
INSTALL_TARGET_PROCESSES = SpringBoard Music

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AirPodsReconnectFix
AirPodsReconnectFix_FILES = ../../Tweak.x
AirPodsReconnectFix_CFLAGS = -fobjc-arc
# MediaPlayer: MPAudioDeviceController (route enum/pick) + MPVolumeView (route
# discovery). UIKit: the hidden offscreen UIWindow that hosts the MPVolumeView.
AirPodsReconnectFix_FRAMEWORKS = MediaPlayer UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
