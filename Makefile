APP_NAME := er-boss-checklist
VERSION  := 2.0.0
ARCH     := amd64

DEB_DIR := $(APP_NAME)_$(VERSION)_$(ARCH)
WIN_DIR := $(APP_NAME)_$(VERSION)_windows
TAR_DIR := $(APP_NAME)_$(VERSION)_linux
OPT_DIR := /opt/$(APP_NAME)

# Skald lives at vendor/skald and is imported as `gui:skald`.
ODIN_FLAGS := -collection:gui=vendor/skald

# Runtime files that have to sit next to the binary. Settings are NOT in
# here — those live in the user's config directory now, which is what
# makes them survive a restart from a read-only install.
DATA_FILES := bosses.json hardlock.json eventflag_bst.txt

.PHONY: all build run debug clean install uninstall deb tar windows zip-win sdl3

all: build

# -o:speed, and no -static: Skald links SDL3 and the Vulkan loader, and
# neither can be statically linked into a working binary. The Linux
# release bundles libSDL3.so.0 alongside instead (see `sdl3`).
#
# RUNPATH=$ORIGIN makes the dynamic loader look next to the binary before
# the system paths, which is what lets the bundled SDL3 win. Harmless in
# a dev tree: with no libSDL3.so.0 sitting there, the loader just carries
# on to /usr/lib as usual. Set at link time so packaging needs no
# patchelf.
build:
	odin build . $(ODIN_FLAGS) -o:speed -out:$(APP_NAME) \
		-extra-linker-flags:"-Wl,-rpath='$$ORIGIN'"

debug:
	odin build . $(ODIN_FLAGS) -debug -out:$(APP_NAME)

run: build
	./$(APP_NAME)

clean:
	rm -f $(APP_NAME) $(APP_NAME).exe libSDL3.so.0
	rm -rf $(DEB_DIR) $(DEB_DIR).deb $(WIN_DIR) $(WIN_DIR).zip $(TAR_DIR) $(TAR_DIR).tar.gz

# ----------------------------------------------------------------------------
# SDL3 bundling
#
# Ubuntu 24.04 LTS and Debian 12 have no SDL3 package, so a bare binary
# won't start there. Copying the .so next to the binary costs ~1.5 MB and
# means the tarball runs anywhere with a Vulkan driver; `build` already
# linked in the RUNPATH that makes the loader find it.
# ----------------------------------------------------------------------------

sdl3: build
	@sdl=$$(ldd $(APP_NAME) | awk '/libSDL3\.so/ {print $$3}' | head -n 1); \
	 [ -n "$$sdl" ] || { echo "libSDL3.so not found in the link"; exit 1; }; \
	 cp -L "$$sdl" libSDL3.so.0; \
	 echo "bundled $$sdl"

# ----------------------------------------------------------------------------
# Linux packaging
# ----------------------------------------------------------------------------

tar: sdl3
	rm -rf $(TAR_DIR)
	mkdir -p $(TAR_DIR)/templates $(TAR_DIR)/static
	cp $(APP_NAME) libSDL3.so.0 $(DATA_FILES) $(TAR_DIR)/
	cp -r templates/* $(TAR_DIR)/templates/
	cp -r static/* $(TAR_DIR)/static/
	cp README.md LICENSE THIRD_PARTY.md $(TAR_DIR)/
	tar -czf $(TAR_DIR).tar.gz $(TAR_DIR)/
	@echo "Built $(TAR_DIR).tar.gz"

# The .deb declares libsdl3-0 as a dependency rather than bundling it —
# apt can satisfy it on the distros that ship a .deb-shaped SDL3.
deb: build
	rm -rf $(DEB_DIR)
	mkdir -p $(DEB_DIR)/DEBIAN
	mkdir -p $(DEB_DIR)$(OPT_DIR)/templates
	mkdir -p $(DEB_DIR)$(OPT_DIR)/static
	mkdir -p $(DEB_DIR)/usr/local/bin
	mkdir -p $(DEB_DIR)/usr/share/applications
	cp $(APP_NAME) $(DATA_FILES) $(DEB_DIR)$(OPT_DIR)/
	cp -r templates/* $(DEB_DIR)$(OPT_DIR)/templates/
	cp -r static/* $(DEB_DIR)$(OPT_DIR)/static/
	cp $(APP_NAME).desktop $(DEB_DIR)/usr/share/applications/
	ln -sf $(OPT_DIR)/$(APP_NAME) $(DEB_DIR)/usr/local/bin/$(APP_NAME)
	printf 'Package: $(APP_NAME)\nVersion: $(VERSION)\nSection: games\nPriority: optional\nArchitecture: $(ARCH)\nDepends: libsdl3-0, libvulkan1\nMaintainer: support@haxenabled.net\nDescription: Elden Ring Boss Checklist\n Native boss kill tracker with OBS overlay, text-file and\n obs-websocket output. Reads save files in read-only mode\n (safe with EAC).\n' > $(DEB_DIR)/DEBIAN/control
	printf '#!/bin/sh\nupdate-desktop-database /usr/share/applications 2>/dev/null || true\n' > $(DEB_DIR)/DEBIAN/postinst
	printf '#!/bin/sh\nupdate-desktop-database /usr/share/applications 2>/dev/null || true\n' > $(DEB_DIR)/DEBIAN/postrm
	chmod 755 $(DEB_DIR)/DEBIAN/postinst $(DEB_DIR)/DEBIAN/postrm
	dpkg-deb --root-owner-group --build $(DEB_DIR)
	@echo "Built $(DEB_DIR).deb"

install: build
	install -d $(DESTDIR)$(OPT_DIR)/templates
	install -d $(DESTDIR)$(OPT_DIR)/static
	install -d $(DESTDIR)/usr/local/bin
	install -d $(DESTDIR)/usr/share/applications
	install -m 755 $(APP_NAME) $(DESTDIR)$(OPT_DIR)/
	install -m 644 $(DATA_FILES) $(DESTDIR)$(OPT_DIR)/
	install -m 644 $(APP_NAME).desktop $(DESTDIR)/usr/share/applications/
	cp -r templates/* $(DESTDIR)$(OPT_DIR)/templates/
	cp -r static/* $(DESTDIR)$(OPT_DIR)/static/
	ln -sf $(OPT_DIR)/$(APP_NAME) $(DESTDIR)/usr/local/bin/$(APP_NAME)

uninstall:
	rm -f $(DESTDIR)/usr/local/bin/$(APP_NAME)
	rm -f $(DESTDIR)/usr/share/applications/$(APP_NAME).desktop
	rm -rf $(DESTDIR)$(OPT_DIR)

# ----------------------------------------------------------------------------
# Windows
#
# Cross-compiling isn't supported here: Skald links SDL3 and Vulkan
# through MSVC import libraries, so Windows builds run on Windows from a
# Developer command prompt. See BUILD.md.
# ----------------------------------------------------------------------------

windows:
	odin build . $(ODIN_FLAGS) -o:speed -out:$(APP_NAME).exe -target:windows_amd64

zip-win: windows
	rm -rf $(WIN_DIR)
	mkdir -p $(WIN_DIR)/templates $(WIN_DIR)/static
	cp $(APP_NAME).exe $(DATA_FILES) $(WIN_DIR)/
	cp -r templates/* $(WIN_DIR)/templates/
	cp -r static/* $(WIN_DIR)/static/
	cp README.md LICENSE THIRD_PARTY.md $(WIN_DIR)/
	@echo "Now copy SDL3.dll from %ODIN_ROOT%\\vendor\\sdl3\\ into $(WIN_DIR)/"
	zip -r $(WIN_DIR).zip $(WIN_DIR)/
	@echo "Built $(WIN_DIR).zip"
