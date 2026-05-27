ARCHS = armv7
TARGET = iphone:clang:latest:6.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = aprfctl
aprfctl_FILES = patcher.m
aprfctl_CFLAGS = -fobjc-arc
aprfctl_FRAMEWORKS = Foundation
aprfctl_INSTALL_PATH = /usr/libexec/airpodsreconnectfix

include $(THEOS_MAKE_PATH)/tool.mk
