# Shorthand for the local Meltingplot build, nothing more. Every target runs
# exactly the command meltingplot/README.md documents, so this file never has
# to know anything rpi-image-gen does not already do. Usage:
#
#   make build                development build
#   make build VERSION=1.2.0-rc.1
#   make installer VERSION=1.2.0-rc.1
#                             installer card for the image of that version,
#                             built before with make build
#   make test                 shell library unit tests
#   make clean                remove the work directory

CONFIG  := duet-pi5.yaml
CACHE   := $(CURDIR)/meltingplot/.cache/apt
VERSION :=
TARGET  := $(basename $(CONFIG))

.PHONY: build installer test clean deps

build:
	mkdir -p $(CACHE)
	./rpi-image-gen build -S ./meltingplot -c $(CONFIG) \
	   -- IGconf_sys_apt_cachedir="$(CACHE)" \
	      $(if $(VERSION),IGconf_artefact_version="$(VERSION)")

installer:
	$(if $(VERSION),,$(error VERSION is the version of the image the card installs))
	mkdir -p $(CACHE)
	./rpi-image-gen build -S ./meltingplot -c $(TARGET)-installer.yaml \
	   -- IGconf_sys_apt_cachedir="$(CACHE)" \
	      IGconf_artefact_version="$(VERSION)" \
	      IGconf_mpinst_image="$(CURDIR)/work/deploy-$(VERSION)/mp-$(TARGET)-$(VERSION).img.zst"

test:
	sh meltingplot/test/test-mp-common.sh
	sh meltingplot/test/test-mp-dsf.sh
	sh meltingplot/test/test-mp-dsf-firmware-files.sh
	sh meltingplot/test/test-mp-installer.sh

clean:
	./rpi-image-gen clean

# Once per machine, see meltingplot/README.md.
deps:
	sudo ./install_deps.sh meltingplot/depends
	chmod o+x "$$HOME"
