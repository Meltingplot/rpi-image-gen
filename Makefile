# Shorthand for the local Meltingplot build, nothing more. Every target runs
# exactly the command meltingplot/README.md documents, so this file never has
# to know anything rpi-image-gen does not already do. Usage:
#
#   make build                development build
#   make build VERSION=1.2.0-rc.1
#   make test                 shell library unit tests
#   make clean                remove the work directory

CONFIG  := duet-pi5.yaml
CACHE   := $(CURDIR)/meltingplot/.cache/apt
VERSION :=

.PHONY: build test clean deps

build:
	mkdir -p $(CACHE)
	./rpi-image-gen build -S ./meltingplot -c $(CONFIG) \
	   -- IGconf_sys_apt_cachedir="$(CACHE)" \
	      $(if $(VERSION),IGconf_artefact_version="$(VERSION)")

test:
	sh meltingplot/test/test-mp-common.sh

clean:
	./rpi-image-gen clean

# Once per machine, see meltingplot/README.md.
deps:
	sudo ./install_deps.sh meltingplot/depends
	chmod o+x "$$HOME"
