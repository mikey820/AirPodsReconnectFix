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
# MediaPlayer: MPAudioDeviceController (legacy manual-bounce path, dormant).
# AVFoundation: AVAudioSession/AVAudioPlayer for the silent A2DP keep-warm stream.
AirPodsReconnectFix_FRAMEWORKS = MediaPlayer AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
