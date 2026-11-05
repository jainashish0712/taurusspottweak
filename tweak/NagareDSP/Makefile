TARGET := iphone:clang:latest:16.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := NagareDSP

NagareDSP_FILES := $(wildcard ../Sources/Shared/NagareDSP/*.cpp) \
                   $(wildcard ../Sources/Shared/NagareDSP/*.mm) \
                   ../Sources/Redesigned/Player/SGNagareDSPViewController.m

NagareDSP_CFLAGS := -fobjc-arc -std=c++17 -I../Sources -I../Sources/Shared/NagareDSP
NagareDSP_FRAMEWORKS := UIKit QuartzCore AudioToolbox Accelerate
NagareDSP_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
