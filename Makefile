################################################################################
# START of configuration                                                       #

GITHUB_REPO ?= shipbuilder
GITHUB_ORG ?= jaytaylor
GITHUB_DOMAIN ?= github.com
GITHUB_API ?= https://$(GITHUB_DOMAIN)/api/v3
GITHUB_TOKEN ?=
# DOCKER_REGISTRY ?= hub.docker.com

# END of configuration                                                         #
################################################################################

SHELL := /bin/bash

RM := rm -rf

EXIT_ON_ERROR := set -o errexit && set -o pipefail && set -o nounset &&

# Supported operating systems.
OSES := linux darwin

# OS class (e.g. "Linux", "Darwin").
UNAME_S := $(shell sh -c 'uname -s 2>/dev/null || echo not')
# # Machine architecture (e.g. "x86_64").
# UNAME_M := $(shell sh -c 'uname -m 2>/dev/null || echo not')
# NB: Sourced from: https://git.kernel.org/pub/scm/git/git.git/tree/config.mak.uname

TARGETS := $(shell \
	grep --files-with-matches --recursive '^package main$$' */*.go \
	| xargs -n1 dirname \
	| sort \
	| uniq \
)

VERSION_RAW := $(shell \
	git describe --abbrev=4 --dirty --always --tags \
	| tr -d '\n' \
)

# NB: For ubuntu packaging version name compatibility, add a leading '0-' when
# the version doesn't start with a number.
VERSION := $(shell \
	if ! [[ $(VERSION_RAW) =~ ^[0-9] ]] ; then echo -n '0-' ; fi \
	&& echo -n $(VERSION_RAW) \
)

VERSION_CLEAN = $(VERSION:v%=%)

RPM_VERSION = $(shell echo $(VERSION) | tr '-' '_')
RPM_FILENAME = $(GITHUB_REPO)-$(RPM_VERSION)-1.x86_64.rpm
DEB_FILENAME = $(GITHUB_REPO)_$(VERSION)_amd64.deb

DESCRIPTION = $(shell \
	git tag --list -n999 $$(echo $(VERSION) | sed -e 's/-dirty$$//' -e 's/^0-//') \
	| sed "s/'/''/g" \
	| sed '1 s/^[^ ]* *//' \
	| awk 1 ORS='\\n' \
)

all: get test build

get:
	$(EXIT_ON_ERROR) go get ./...

generate:
	$(EXIT_ON_ERROR) echo -e 'package data\nfunc Asset(name string) ([]byte, error) { return nil, nil }' > pkg/bindata_buildpacks/data/buildpacks_data.go
	$(EXIT_ON_ERROR) find . -type f -name '*.go' | grep -v '^\(\.\/\)\?\(vendor\)' | xargs -n1 dirname | sort | uniq | xargs -n1 go generate

test: generate
	$(EXIT_ON_ERROR) go test -race -v $$(go list ./... | grep -v /vendor/) || ( rc=$$? && echo "rc=$${rc}" && exit $${rc} )

# Generate build targets for long form,
# e.g. `make shipbuilder/shipbuilder-linux`.
$(foreach target,$(TARGETS),$(foreach os,$(OSES),$(target)/$(target)-$(os))): generate
	$(eval tool := $(subst /,,$(dir $@)))
	$(eval binary := $(subst $(dir $@),,$@))
	$(eval os := $(subst $(dir $@)$(tool)-,,$@))
	@echo "info: Building tool=$(tool) binary=$(binary) os=$(os) verion=$(VERSION_CLEAN)"
	$(EXIT_ON_ERROR) cd $(tool) && GOOS=$(os) GOARCH=amd64 go build \
		-ldflags "-X $(GITHUB_DOMAIN)/$(GITHUB_ORG)/$(GITHUB_REPO)/pkg/version.Version=$(VERSION_CLEAN) \
		$(shell bash -c 'test -x ldflags.sh && ./ldflags.sh || :')" \
		-o $(binary)

# Generate build targets for single-OS short form,
# e.g. `make shipbuilder-linux`.
$(foreach target,$(TARGETS),$(foreach os,$(OSES),$(target)-$(os))):
	$(eval tool := $@)
	@# Strip all `-DOLLAR(os)' strings from $(tool).
	$(foreach os,$(OSES), \
		$(eval tool := $(subst -$(os),,$(tool))) \
	)
	$(eval os := $(subst $(tool)-,,$@))
	$(EXIT_ON_ERROR) make $(tool)/$(tool)-$(os)

.SECONDEXPANSION:
# NB: See https://www.gnu.org/software/make/manual/html_node/Secondary-Expansion.html
#     for information on how `.SECONDARYEXPANSION` works.  The general idea is
#     enabling a double-var expansion capability; as in `$$..`.

# Generate build targets for multi-OS short form,
# e.g. `make shipbuilder`.
$(foreach target,$(TARGETS),$(target)): $(foreach os,$(OSES), $$@-$(os) )

build: $(foreach target,$(TARGETS),$(foreach os,$(OSES),$(target)/$(target)-$(os)))

# Generate generalized build targets for each OS,
# e.g. `make build-linux`.
$(foreach os,$(OSES),build-$(os)): $(foreach target,$(TARGETS), $(target)/$(target)-$$(subst build-,,$$@) )

# Generate packaging targets for each OS,
# e.g. `make package-linux`.
$(foreach os,$(OSES),package-$(os)): build-$$(subst package-,,$$@)
	$(eval os := $(subst package-,,$@))
	$(EXIT_ON_ERROR) mkdir -p build/$(os) dist
	$(EXIT_ON_ERROR) $(foreach target,$(TARGETS), \
		cp $(target)/$(target)-$(os) build/$(os)/$(target) ; \
	)
	$(EXIT_ON_ERROR) cd build/$(os) && tar -cjvf ../../dist/$(GITHUB_REPO)-$(VERSION)-$(os).tar.bz *

# Installs Ubuntu dependencies for RPM construction.
# TODO: Detect OS and support both Ubuntu and Centos.
deps:
ifeq ($(UNAME_S),Linux)
	@#$(EXIT_ON_ERROR) command gcc || sudo --non-interactive apt-get install --yes gcc
	@#$(EXIT_ON_ERROR) command gem || sudo --non-interactive apt-get install --yes gem
	@#$(EXIT_ON_ERROR) command git || sudo --non-interactive apt-get install --yes git
	@#$(EXIT_ON_ERROR) command unzip || sudo --non-interactive apt-get install --yes unzip
	$(EXIT_ON_ERROR) sudo --non-interactive apt-get install --yes bzr gcc gem git rpm ruby-dev rubygems unzip
	$(EXIT_ON_ERROR) command -v fpm 1>/dev/null 2>/dev/null || sudo --non-interactive gem install fpm
else
ifeq ($(UNAME_S),Darwin)
	$(EXIT_ON_ERROR) command -v fpm 1>/dev/null 2>/dev/null || sudo --non-interactive gem install fpm
	@# NB: gtar is required by for fpm to work properly on macOS.
	@#
	@# Avoids errors like:
	@#
	@#     tar: Option --owner=0 is not supported
	@#     tar: Option --group=0 is not supported
	@#
	$(EXIT_ON_ERROR) command -v gtar 1>/dev/null 2>/dev/null || brew install gtar
else
	$(EXIT_ON_ERROR) @echo "Unrecognized operation system: $(UNAME_S)" 1>&2 && exit 1
endif
endif

_create_environment:
	@$(EXIT_ON_ERROR) test -d env || ( echo 'error: missing required "env" configuration directory' 1>&2 && exit 1 )
	$(EXIT_ON_ERROR) echo -n '' > build/environment
	$(EXIT_ON_ERROR) cd env && for f in $$(ls -1) ; do echo "$${f}='$$(cat "$${f}")'" >> ../build/environment ; done ; cd - 1>/dev/null

_prep_fpm: _create_environment build-linux package-linux deps
	$(EXIT_ON_ERROR) test -r build/environment || ( echo 'error: missing build/environment; hint: start out by copying build/environment.example' 1>&2 && exit 1 )
	$(EXIT_ON_ERROR) \
		mkdir -p dist \
		&& cd build \
		&& mkdir -p $(GITHUB_REPO)/etc/default $(GITHUB_REPO)/etc/$(GITHUB_REPO) $(GITHUB_REPO)/etc/systemd/system $(GITHUB_REPO)/usr/bin \
		&& cp linux/$(GITHUB_REPO) $(GITHUB_REPO)/usr/bin/$(GITHUB_REPO) \
		&& chmod 755 $(GITHUB_REPO)/usr/bin/$(GITHUB_REPO) \
		&& cp ../build/environment $(GITHUB_REPO)/etc/default/$(GITHUB_REPO) \
		&& chmod 644 $(GITHUB_REPO)/etc/default/$(GITHUB_REPO) \
		&& cp ../build/$(GITHUB_REPO).service $(GITHUB_REPO)/etc/systemd/system/

dist/$(DEB_FILENAME): _prep_fpm
	$(EXIT_ON_ERROR) \
		cd dist \
		&& fpm --input-type dir --output-type deb --chdir ../build/$(GITHUB_REPO) --name $(GITHUB_REPO) --version $(VERSION)

deb: dist/$(DEB_FILENAME)

dist/$(RPM_FILENAME): _prep_fpm
	$(EXIT_ON_ERROR) \
		cd dist \
		&& fpm --input-type dir --output-type rpm --chdir ../build/$(GITHUB_REPO) --name $(GITHUB_REPO) --version $(RPM_VERSION)

rpm: dist/$(RPM_FILENAME)

# docker:
# 	$(EXIT_ON_ERROR) sudo --non-interactive docker rmi -f $(GITHUB_ORG)/autocap:$(VERSION) || true
# 	$(EXIT_ON_ERROR) cd build && sudo --non-interactive docker build -t $(GITHUB_ORG)/autocap:$(VERSION) .

package: $(foreach os,$(OSES), package-$(os)) deb rpm docker

publish-github:
	@echo "Publishing release to Github for version=$(VERSION)"

	$(EXIT_ON_ERROR) test -n "$$(command -v github-release)" || go get github.com/aktau/github-release
	
	$(EXIT_ON_ERROR) github-release release --user "$(GITHUB_ORG)" --repo "$(GITHUB_REPO)" --tag "$(VERSION)" --name "$(VERSION)" --description "$$(echo "$(DESCRIPTION)" | perl -pe 's/\\n/\n/g')"

	$(foreach os,$(OSES), \
		$(EXIT_ON_ERROR) \
			github-release upload --user "$(GITHUB_ORG)" --repo "$(GITHUB_REPO)" --tag "$(VERSION)" --name "$(GITHUB_REPO)-$(VERSION)-$(os).tar.bz" --label "$(GITHUB_REPO)-$(VERSION)-$(os).tar.bz" --file "dist/$(GITHUB_REPO)-$(VERSION)-$(os).tar.bz" ; \
	)

	$(EXIT_ON_ERROR) github-release upload --user "$(GITHUB_ORG)" --repo "$(GITHUB_REPO)" --tag "$(VERSION)" --name "$(DEB_FILENAME)" --label "$(DEB_FILENAME)" --file "dist/$(DEB_FILENAME)"
	$(EXIT_ON_ERROR) github-release upload --user "$(GITHUB_ORG)" --repo "$(GITHUB_REPO)" --tag "$(VERSION)" --name "$(RPM_FILENAME)" --label "$(RPM_FILENAME)" --file "dist/$(RPM_FILENAME)"

publish-packagecloud:
	@echo "Publishing release to Packagecloud for version=$(VERSION)"

	$(EXIT_ON_ERROR) test -n "$$(command -v pkgcloud-push)" || go get github.com/mlafeldt/pkgcloud/...
	$(EXIT_ON_ERROR) pkgcloud-push $(GITHUB_ORG)/ops/el/7 dist/$(RPM_FILENAME)
	$(EXIT_ON_ERROR) pkgcloud-push $(GITHUB_ORG)/ops/ubuntu/xenial dist/$(DEB_FILENAME)

publish-docker:
	@echo "Publishing docker image to registry=$(DOCKER_REGISTRY) for version=$(VERSION)"

	$(EXIT_ON_ERROR) sudo --non-interactive docker tag $(GITHUB_ORG)/autocap:$(VERSION) $(DOCKER_REGISTRY)/$(GITHUB_ORG)/autocap:$(VERSION)
	$(EXIT_ON_ERROR) sudo --non-interactive docker push $(DOCKER_REGISTRY)/$(GITHUB_ORG)/autocap:$(VERSION)

publish-release: package publish-github publish-packagecloud publish-docker

list-targets:
	@$(EXIT_ON_ERROR) echo "$$(echo $(TARGETS) | tr ' ' '\n')"

show-version:
	@$(EXIT_ON_ERROR) echo $(VERSION)

clean:
	$(EXIT_ON_ERROR) rm -rf $(foreach os,$(OSES), \
		$(foreach target,$(TARGETS), \
			$(target)/$(target)-$(os) \
		) \
	) \
	$(foreach os,$(OSES), \
		build/$(os) \
	) \
	build/$(GITHUB_REPO) \
	dist

.DEFAULT: all
.PHONY: all generate build $(foreach os,$(OSES), build-$(os) ) deps _prep_fpm deb rpm docker package publish-github publish-packagecloud publish-docker publish-release list-targets clean $(TARGETS)
