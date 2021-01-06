# Copyright 2016 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# The binaries to build (just the basenames).
BINS := etags

# Where to push the docker image.
REGISTRY ?= r-push.lerch.org

# This version-strategy uses git tags to set the version string
VERSION ?= $(shell git describe --tags --always --dirty)
#
# This version-strategy uses a manual value to set the version string
#VERSION ?= 1.2.3

###
### These variables should not need tweaking.
###

DKR := $(shell if command -v docker > /dev/null 2>&1; then echo "docker"; else echo "podman"; fi)

# Rootless podman, "root" in the shell will be the uid of the user
UID ?= $(shell if [ "$(DKR)" = "podman" ]; then echo 0; else id -u; fi)
GID ?= $(shell if [ "$(DKR)" = "podman" ]; then echo 0; else id -g; fi)

SRC_DIRS := cmd pkg # directories which hold app source (not vendored)

# Windows not working atm
#ALL_PLATFORMS := linux/amd64 linux/arm linux/arm64 linux/ppc64le linux/s390x
# Unlikely I'll run on ppc or s390x anytime soon
# scons needs hacking for old arm
ALL_PLATFORMS := linux/amd64 linux/arm64

# Used internally.  Users should pass BUILDOS and/or BUILDARCH.
# guess if go isn't installed on the host
OS := $(if $(BUILDOS),$(BUILDOS),$(shell go env BUILDOS 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]'))
HOSTARCH := $(shell uname -m)
HOSTARCH := $(if $(findstring armv5,$(HOSTARCH)),armv5,$(HOSTARCH))
HOSTARCH := $(if $(findstring armv5,$(HOSTARCH)),armv5,$(HOSTARCH))
HOSTARCH := $(if $(findstring armv6,$(HOSTARCH)),armv6,$(HOSTARCH))
HOSTARCH := $(if $(findstring armv7,$(HOSTARCH)),armv7,$(HOSTARCH))
HOSTARCH := $(if $(subst aarch64,,$(HOSTARCH)),$(HOSTARCH),arm64)
HOSTARCH := $(if $(subst x86,,$(HOSTARCH)),$(HOSTARCH),386)
HOSTARCH := $(if $(subst x86_64,,$(HOSTARCH)),$(HOSTARCH),amd64)
HOSTARCH := $(if $(subst i686,,$(HOSTARCH)),$(HOSTARCH),386)
HOSTARCH := $(if $(subst i386,,$(HOSTARCH)),$(HOSTARCH),386)
ARCH := $(if $(BUILDARCH),$(BUILDARCH),$(HOSTARCH))

TAG := $(VERSION)__$(OS)_$(ARCH)

BUILD_IMAGE ?= python:3.8.7-alpine3.12

# For the following OS/ARCH expansions, we transform OS/ARCH into OS_ARCH
# because make pattern rules don't match with embedded '/' characters.

container-%:
	@$(MAKE) container                    \
	    --no-print-directory              \
	    GOOS=$(firstword $(subst _, ,$*)) \
	    GOARCH=$(lastword $(subst _, ,$*))\
	    BUILDOS=$(firstword $(subst _, ,$*)) \
	    BUILDARCH=$(lastword $(subst _, ,$*))

push-%:
	@$(MAKE) push                         \
	    --no-print-directory              \
	    BUILDOS=$(firstword $(subst _, ,$*)) \
	    BUILDARCH=$(lastword $(subst _, ,$*))

all-container: # @HELP builds containers for all platforms
all-container: $(addprefix container-, $(subst /,_, $(ALL_PLATFORMS)))

all-push: # @HELP pushes containers for all platforms to the defined registry
all-push: $(addprefix push-, $(subst /,_, $(ALL_PLATFORMS)))

CONTAINER_DOTFILES = $(foreach bin,$(BINS),.container-$(subst /,_,$(REGISTRY)/$(bin))-$(TAG))

container containers: # @HELP builds containers for one platform ($OS/$ARCH)
container containers: $(CONTAINER_DOTFILES)
	@for bin in $(BINS); do              \
	    echo "container: $(REGISTRY)/$$bin:$(TAG)"; \
	done

lambda-layer: # @HELP creates a lambda layer zipfile "lambda.zip" suitable for uploading
lambda-layer: # Python - mostly not compiled, and deps that are, are linux/amd64
	@echo "todo"

# Each container-dotfile target can reference a $(BIN) variable.
# This is done in 2 steps to enable target-specific variables.
$(foreach bin,$(BINS),$(eval $(strip                                 \
    .container-$(subst /,_,$(REGISTRY)/$(bin))-$(TAG): BIN = $(bin)  \
)))
$(foreach bin,$(BINS),$(eval                                                                   \
    .container-$(subst /,_,$(REGISTRY)/$(bin))-$(TAG): Dockerfile     \
))
# This is the target definition for all container-dotfiles.
# These are used to track build state in hidden files.
$(CONTAINER_DOTFILES):
	@sed                                 \
	    -e 's|{ARG_BIN}|$(BIN)|g'        \
	    -e 's|{ARG_ARCH}|$(ARCH)|g'      \
	    -e 's|{ARG_OS}|$(OS)|g'          \
	    Dockerfile > .dockerfile-$(BIN)-$(OS)_$(ARCH)
	@export DOCKER_CLI_EXPERIMENTAL=enabled  &&                               \
	if $(DKR) --version | grep -q podman; then                                \
		[ "$(HOSTARCH)" != "$(ARCH)" ] &&                                       \
			echo "Podman build on different arch is likely broken" &&             \
			echo "See: https://github.com/containers/buildah/issues/1590";        \
		$(DKR) build --platform $(OS)/$(ARCH) -t $(REGISTRY)/$(BIN):$(TAG)      \
			-f .dockerfile-$(BIN)-$(OS)_$(ARCH) .;                                \
	else                                                                      \
		$(DKR) build --pull --no-cache                                          \
			-t $(REGISTRY)/$(BIN):$(TAG) -f .dockerfile-$(BIN)-$(OS)_$(ARCH)      \
			--platform $(OS)/$(ARCH)                                              \
			. ;                                                                   \
	fi
	@$(DKR) images -q $(REGISTRY)/$(BIN):$(TAG) > $@
	@echo

push: # @HELP pushes the container for one platform ($OS/$ARCH) to the defined registry
push: $(CONTAINER_DOTFILES)
	@for bin in $(BINS); do                    \
	    $(DKR) push $(REGISTRY)/$$bin:$(TAG);  \
	done

# TODO: podman and docker are pretty different wrt manifests and workflow here
#       docker is experimental CLI and requires pushed images (which then should probably
#       be untagged on the server), podman can push everything at once when the manifest
#       is cleaned
manifest-list: # @HELP builds a manifest list of containers for all platforms
manifest-list: all-container
	@export DOCKER_CLI_EXPERIMENTAL=enabled  &&                                          \
	if $(DKR) --version | grep -q podman; then                                           \
		for bin in $(BINS); do                                                             \
			$(DKR) manifest create $(REGISTRY)/$$bin:$(VERSION);                             \
			for platform in $(ALL_PLATFORMS); do                                             \
				$(DKR) manifest add --arch $$(echo $$platform | cut -d/ -f2)                   \
					$(REGISTRY)/$$bin:$(VERSION)                                                 \
					$(REGISTRY)/$$bin:$(VERSION)__$$(echo $$platform | sed 's#/#_#g');           \
			done;                                                                            \
			$(DKR) manifest push --all $(REGISTRY)/$$bin:$(VERSION)                          \
											docker://$(REGISTRY)/$$bin:$(VERSION);                           \
		done;                                                                              \
	else                                                                                 \
		for bin in $(BINS); do                                                             \
			cmd="$(DKR) manifest create $(REGISTRY)/$$bin:$(VERSION)";                       \
			for platform in $(ALL_PLATFORMS); do                                             \
			  cmd="$$cmd $(REGISTRY)/$$bin:$(VERSION)__$$(echo $$platform | sed 's#/#_#g')"; \
				$(DKR) push $(REGISTRY)/$$bin:$(VERSION)__$$(echo $$platform | sed 's#/#_#g'); \
			done;                                                                            \
			eval "$$cmd";                                                                    \
			for platform in $(ALL_PLATFORMS); do                                             \
				$(DKR) manifest annotate --arch $$(echo $$platform | cut -d/ -f2)              \
					$(REGISTRY)/$$bin:$(VERSION)                                                 \
					$(REGISTRY)/$$bin:$(VERSION)__$$(echo $$platform | sed 's#/#_#g');           \
			done;                                                                            \
			$(DKR) manifest push $(REGISTRY)/$$bin:$(VERSION);                               \
		done;                                                                              \
	fi

version: # @HELP outputs the version string
version:
	@echo $(VERSION)

test: # @HELP runs tests, as defined in ./build/test.sh (not yet implemented)
test: $(BUILD_DIRS)
	@$(DKR) run                                                 \
	    -i                                                      \
	    --rm                                                    \
	    -u $(UID):$(GID)                                        \
	    -v $$(pwd):/src                                         \
	    -w /src                                                 \
	    --env HTTP_PROXY=$(HTTP_PROXY)                          \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                        \
	    $(BUILD_IMAGE)                                          \
	    /bin/sh -c "                                            \
	        ARCH=$(ARCH)                                        \
	        OS=$(OS)                                            \
	        VERSION=$(VERSION)                                  \
	        ./build/test.sh $(SRC_DIRS)                         \
	    "

$(BUILD_DIRS):
	@mkdir -p $@

clean: # @HELP removes built binaries and temporary files
clean: container-clean bin-clean

container-clean:
	@rm -rf .container-* .dockerfile-*;                                             \
	for bin in $(BINS); do                                                          \
		if $(DKR) --version |grep -q podman; then                                     \
			$(DKR) image exists "$(REGISTRY)/$$bin:$(VERSION)" &&                       \
			$(DKR) image rm "$(REGISTRY)/$$bin:$(VERSION)";                             \
		else                                                                          \
			$(DKR) image rm "$(REGISTRY)/$$bin:$(VERSION)";                             \
		fi;                                                                           \
		for platform in $(ALL_PLATFORMS); do                                          \
			if $(DKR) --version |grep -q podman; then                                   \
				$(DKR) image exists                                                       \
				  "$(REGISTRY)/$$bin:$(VERSION)__$$(echo $$platform | sed 's#/#_#g')" &&  \
				$(DKR) image rm                                                           \
				  "$(REGISTRY)/$$bin:$(VERSION)__$$(echo $$platform | sed 's#/#_#g')";    \
			else                                                                        \
				$(DKR) image rm                                                           \
				  "$(REGISTRY)/$$bin:$(VERSION)__$$(echo $$platform | sed 's#/#_#g')";    \
			fi;                                                                         \
		done;                                                                         \
	done; true

bin-clean:
	rm -rf .go bin

help: # @HELP prints this message
help:
	@echo "NOTE: Use BUILDARCH/BUILDOS variables to override OS/ARCH"
	@echo
	@echo "VARIABLES:"
	@echo "  BINS = $(BINS)"
	@echo "  OS = $(OS)"
	@echo "  ARCH = $(ARCH)"
	@echo "  REGISTRY = $(REGISTRY)"
	@echo "  HOSTARCH = $(HOSTARCH)"
	@echo
	@echo "TARGETS:"
	@grep -E '^.*: *# *@HELP' $(MAKEFILE_LIST)    \
	    | awk '                                   \
	        BEGIN {FS = ": *# *@HELP"};           \
	        { printf "  %-30s %s\n", $$1, $$2 };  \
	    '
