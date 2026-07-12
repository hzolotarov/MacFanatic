# Single source of truth for the version — everything else is injected
# from here at build time (Info.plist, CLI binary, README badge, DMG).
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0)

CC      ?= cc
CFLAGS  ?= -O2 -Wall
SWIFTC  ?= swiftc

all: smcfan SMCFanGUI

smcfan: smcfan.c VERSION
	$(CC) $(CFLAGS) -DSMCFAN_VERSION='"$(VERSION)"' -o $@ $< -framework IOKit -framework CoreFoundation

SMCFanGUI: SMCFanGUI.swift
	$(SWIFTC) -O -parse-as-library $< -o $@

# Build MacFanatic.app (double-click, Dock, the works)
# IMPORTANT: inside the bundle the helper is named smcfan-cli, not smcfan —
# APFS is case-insensitive by default and "smcfan" could collide with the GUI name.
app: all
	rm -rf MacFanatic.app
	mkdir -p MacFanatic.app/Contents/MacOS
	mkdir -p MacFanatic.app/Contents/Resources/en.lproj
	cp SMCFanGUI MacFanatic.app/Contents/MacOS/MacFanatic
	cp smcfan   MacFanatic.app/Contents/MacOS/smcfan-cli
	sed "s/__VERSION__/$(VERSION)/g" Info.plist > MacFanatic.app/Contents/Info.plist
	@for d in *.lproj; do \
		if [ -d "$$d" ]; then \
			mkdir -p "MacFanatic.app/Contents/Resources/$$d"; \
			cp "$$d"/*.strings "MacFanatic.app/Contents/Resources/$$d/" 2>/dev/null; \
			echo "  localization: $$d"; \
		fi; \
	done
	@if [ ! -f AppIcon.icns ] && [ -f icon.png ]; then \
		$(MAKE) icon; \
	fi
	@if [ -f AppIcon.icns ]; then \
		cp AppIcon.icns MacFanatic.app/Contents/Resources/; \
		echo "  icon: AppIcon.icns"; \
	fi
	@$(MAKE) -s readme-version
	@echo "Done: MacFanatic.app $(VERSION)  (don't forget: make helper)"

# Build AppIcon.icns from a square PNG. Default source: icon.png
#   make icon              (uses icon.png)
#   make icon SRC=other.png
SRC ?= icon.png
icon:
	@test -f "$(SRC)" || { echo "no $(SRC) found; usage: make icon SRC=path/to/icon.png"; exit 1; }
	rm -rf AppIcon.iconset && mkdir AppIcon.iconset
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s "$(SRC)" --out AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		d=$$((s*2)); \
		sips -z $$d $$d "$(SRC)" --out AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns AppIcon.iconset -o AppIcon.icns
	rm -rf AppIcon.iconset
	@echo "AppIcon.icns ready — 'make app' will pick it up"

# One-time: setuid so the GUI can write to SMC without sudo.
# The "Grant helper privileges" button in the app does the same thing.
helper:
	@if [ -f MacFanatic.app/Contents/MacOS/smcfan-cli ]; then \
		sudo chown root:wheel MacFanatic.app/Contents/MacOS/smcfan-cli; \
		sudo chmod 4755 MacFanatic.app/Contents/MacOS/smcfan-cli; \
		echo "setuid granted to smcfan-cli inside MacFanatic.app"; \
	else \
		sudo chown root:wheel smcfan; \
		sudo chmod 4755 smcfan; \
		echo "setuid granted to ./smcfan"; \
	fi

clean:
	rm -rf smcfan SMCFanGUI MacFanatic.app MacFanatic.dmg dmg-staging

# Distributable disk image: MacFanatic.app + an /Applications symlink —
# the classic "drag to install" layout.
dmg:
	@test -d MacFanatic.app || { echo "run 'make app' first"; exit 1; }
	rm -rf dmg-staging MacFanatic.dmg
	mkdir dmg-staging
	cp -R MacFanatic.app dmg-staging/
	ln -s /Applications dmg-staging/Applications
	hdiutil create -volname "Mac Fanatic $(VERSION)" \
		-srcfolder dmg-staging \
		-format UDZO -imagekey zlib-level=9 \
		MacFanatic.dmg
	rm -rf dmg-staging
	@echo "MacFanatic.dmg ready"

# Keep the README version badge in sync (invoked automatically by `make app`)
readme-version:
	@sed -E -i '' 's|version-[0-9]+\.[0-9]+\.[0-9]+-|version-$(VERSION)-|' README.md 2>/dev/null || true

# Bump the version everywhere:  make bump V=1.0.1
bump:
	@test -n "$(V)" || { echo "usage: make bump V=x.y.z"; exit 1; }
	@echo "$(V)" > VERSION
	@$(MAKE) -s readme-version VERSION=$(V)
	@echo "version bumped to $(V) — rebuild with 'make app'"
