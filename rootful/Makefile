# iOS 6 / 32-bit aggregate: the tweak dylib + the aprfctl plist patcher, in one
# package. armv7 covers every iOS 6 device (armv7s iPhone 5/5c run armv7 fine).
ARCHS = armv7
TARGET = iphone:clang:latest:6.0

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = tweak patcher

include $(THEOS)/makefiles/aggregate.mk
