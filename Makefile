# Entry points; the real work is in scripts/. IPA defaults to the first file in ipa/.
IPA ?= $(firstword $(wildcard ipa/*.ipa))

# Include the Safari link opener unless SAFARI=0 is requested.
SAFARI ?= 1
SAFARI_ARG := $(if $(filter 0,$(SAFARI)),--no-safari,)

# What goes on the phone is the mod alone. FLEX is the inspector `make trees` reads the screens
# through, so it rides along only when it is asked for: make install FLEX=1. (A make target cannot
# take --flex; make would read that as an option of its own.)
FLEX ?= 0
FLEX_ARG := $(if $(filter 0,$(FLEX)),--no-flex,)

# A local install is renamed and re-iconed so it is told apart from the released app on the home
# screen.
DEV_NAME ?= Taurus.dev
DEV_ICON ?= docs/icon.png

.PHONY: build release install trees session log flags tweak
build:    ## FLEX + glass IPA into out/
	bash ./scripts/pipeline.sh $(IPA) $(SAFARI_ARG)
release:  ## glass only, no FLEX
	bash ./scripts/pipeline.sh $(IPA) $(SAFARI_ARG) --no-flex
tweak:    ## build spotifyglass.dylib and .deb only into out/ (no IPA)
	@mkdir -p out
	@if [ ! -f tweak/Sources/Shared/Flags/SGFlagList.m ]; then \
		mkdir -p tweak/Sources/Shared/Flags; \
		printf '// Stub\n#import "Flags.h"\n\nconst SGFlagDef SGFlagTable[] = {};\nconst NSUInteger SGFlagCount = 0;\n' > tweak/Sources/Shared/Flags/SGFlagList.m; \
	fi
	env -u MAKELEVEL gmake -C tweak clean package
	@cp "$$(find tweak/.theos -name 'spotifyglass.dylib' | head -1)" out/spotifyglass.dylib
	@install_name_tool -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate @rpath/CydiaSubstrate.framework/CydiaSubstrate out/spotifyglass.dylib 2>/dev/null || true
	@install_name_tool -change /usr/lib/libsubstrate.dylib @rpath/CydiaSubstrate.framework/CydiaSubstrate out/spotifyglass.dylib 2>/dev/null || true
	@install_name_tool -add_rpath @executable_path/Frameworks out/spotifyglass.dylib 2>/dev/null || true
	@install_name_tool -add_rpath @loader_path/Frameworks out/spotifyglass.dylib 2>/dev/null || true
	@install_name_tool -add_rpath @loader_path out/spotifyglass.dylib 2>/dev/null || true
	@command -v ldid >/dev/null 2>&1 && ldid -S out/spotifyglass.dylib 2>/dev/null || true
	@[ -f tweak/spotifyglass.plist ] && cp tweak/spotifyglass.plist out/spotifyglass.plist || true
	@cp tweak/packages/*.deb out/ 2>/dev/null || true
	@echo "==> tweak built into out/spotifyglass.dylib (patched for LiveContainer/sideloading)"
install:  ## build, sign with your certificate, push to the phone on USB (FLEX=1 to take FLEX too)
	bash ./scripts/pipeline.sh $(IPA) $(SAFARI_ARG) --install $(FLEX_ARG) --name "$(DEV_NAME)" --icon "$(DEV_ICON)" -o out/Taurus.dev.ipa
trees:    ## record per-screen view trees into trees/ (needs a FLEX build on the phone)
	./scripts/record-trees.py
session:  ## record clean trees screen by screen into trees/clean/, Enter per snapshot, n for the next screen (SCREENS="playlist artist" for some)
	./scripts/record-session.py $(SCREENS)
log:     ## stream the tweak's log lines from the phone
	./scripts/dump-log.sh
flags:    ## regenerate tweak/Sources/Shared/Flags/SGFlagList.m, Spotify's remote-config flags, from the IPA
	./scripts/extract-flags.py $(IPA)

.PHONY: test-safari
test-safari:  ## link routing, lifecycle and extension packaging regression checks
	node --test tests/open-spotify/*.test.cjs
	python3 -m unittest discover -s tests/open-spotify -p 'test_*.py'
