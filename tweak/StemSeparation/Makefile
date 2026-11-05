TARGET := iphone:clang:latest:16.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := StemSeparation

StemSeparation_FILES := $(wildcard ../Sources/Shared/Stems/*.cpp) \
                        $(wildcard ../Sources/Shared/Stems/*.mm) \
                        $(wildcard ../Sources/Shared/Stems/*.m) \
                        $(wildcard ../Sources/Shared/Stems/*.swift) \
                        $(wildcard ../Sources/Shared/Stems/miniz/*.c) \
                        ../Sources/Redesigned/Player/SGStemsViewController.m

StemSeparation_CFLAGS := -fobjc-arc -I../Sources -I../Sources/Shared/Stems
StemSeparation_FRAMEWORKS := UIKit QuartzCore UniformTypeIdentifiers AudioToolbox Accelerate CoreML Metal
StemSeparation_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
