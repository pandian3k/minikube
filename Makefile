# Copyright 2016 The Kubernetes Authors All rights reserved.
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

# Bump these on release - and please check ISO_VERSION for correctness.
VERSION_MAJOR ?= 1
VERSION_MINOR ?= 6
VERSION_BUILD ?= 1
RAW_VERSION=$(VERSION_MAJOR).$(VERSION_MINOR).${VERSION_BUILD}
VERSION ?= v$(RAW_VERSION)

# Default to .0 for higher cache hit rates, as build increments typically don't require new ISO versions
ISO_VERSION ?= v$(VERSION_MAJOR).$(VERSION_MINOR).0
# Dashes are valid in semver, but not Linux packaging. Use ~ to delimit alpha/beta
DEB_VERSION ?= $(subst -,~,$(RAW_VERSION))
RPM_VERSION ?= $(DEB_VERSION)

# used by hack/jenkins/release_build_and_upload.sh and KVM_BUILD_IMAGE, see also BUILD_IMAGE below
GO_VERSION ?= 1.13.4

INSTALL_SIZE ?= $(shell du out/minikube-windows-amd64.exe | cut -f1)
BUILDROOT_BRANCH ?= 2019.02.7
REGISTRY?=gcr.io/k8s-minikube

# Get git commit id
COMMIT_NO := $(shell git rev-parse HEAD 2> /dev/null || true)
COMMIT ?= $(if $(shell git status --porcelain --untracked-files=no),"${COMMIT_NO}-dirty","${COMMIT_NO}")

HYPERKIT_BUILD_IMAGE 	?= karalabe/xgo-1.12.x
# NOTE: "latest" as of 2019-08-15. kube-cross images aren't updated as often as Kubernetes
BUILD_IMAGE 	?= k8s.gcr.io/kube-cross:v$(GO_VERSION)-1
ISO_BUILD_IMAGE ?= $(REGISTRY)/buildroot-image
KVM_BUILD_IMAGE ?= $(REGISTRY)/kvm-build-image:$(GO_VERSION)

ISO_BUCKET ?= minikube/iso

MINIKUBE_VERSION ?= $(ISO_VERSION)
MINIKUBE_BUCKET ?= minikube/releases
MINIKUBE_UPLOAD_LOCATION := gs://${MINIKUBE_BUCKET}
MINIKUBE_RELEASES_URL=https://github.com/kubernetes/minikube/releases/download

KERNEL_VERSION ?= 4.19.81
# latest from https://github.com/golangci/golangci-lint/releases
GOLINT_VERSION ?= v1.21.0
# Limit number of default jobs, to avoid the CI builds running out of memory
GOLINT_JOBS ?= 4
# see https://github.com/golangci/golangci-lint#memory-usage-of-golangci-lint
GOLINT_GOGC ?= 100
# options for lint (golangci-lint)
GOLINT_OPTIONS = --timeout 4m \
	  --build-tags "${MINIKUBE_INTEGRATION_BUILD_TAGS}" \
	  --enable goimports,gocritic,golint,gocyclo,misspell,nakedret,stylecheck,unconvert,unparam,dogsled \
	  --exclude 'variable on range scope.*in function literal|ifElseChain'

# Major version of gvisor image. Increment when there are breaking changes.
GVISOR_IMAGE_VERSION ?= 2

export GO111MODULE := on

GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)
GOPATH ?= $(shell go env GOPATH)
BUILD_DIR ?= ./out
$(shell mkdir -p $(BUILD_DIR))

# Use system python if it exists, otherwise use Docker.
PYTHON := $(shell command -v python || echo "docker run --rm -it -v $(shell pwd):/minikube -w /minikube python python")
BUILD_OS := $(shell uname -s)

SHA512SUM=$(shell command -v sha512sum || echo "shasum -a 512")

STORAGE_PROVISIONER_TAG := v1.8.1

# Set the version information for the Kubernetes servers
MINIKUBE_LDFLAGS := -X k8s.io/minikube/pkg/version.version=$(VERSION) -X k8s.io/minikube/pkg/version.isoVersion=$(ISO_VERSION) -X k8s.io/minikube/pkg/version.isoPath=$(ISO_BUCKET) -X k8s.io/minikube/pkg/version.gitCommitID=$(COMMIT)
PROVISIONER_LDFLAGS := "$(MINIKUBE_LDFLAGS) -s -w"

MINIKUBEFILES := ./cmd/minikube/
HYPERKIT_FILES := ./cmd/drivers/hyperkit
STORAGE_PROVISIONER_FILES := ./cmd/storage-provisioner
KVM_DRIVER_FILES := ./cmd/drivers/kvm/

MINIKUBE_TEST_FILES := ./cmd/... ./pkg/...

# npm install -g markdownlint-cli
MARKDOWNLINT ?= markdownlint


MINIKUBE_MARKDOWN_FILES := README.md docs CONTRIBUTING.md CHANGELOG.md

MINIKUBE_BUILD_TAGS := container_image_ostree_stub containers_image_openpgp
MINIKUBE_BUILD_TAGS += go_getter_nos3 go_getter_nogcs
MINIKUBE_INTEGRATION_BUILD_TAGS := integration $(MINIKUBE_BUILD_TAGS)

CMD_SOURCE_DIRS = cmd pkg
SOURCE_DIRS = $(CMD_SOURCE_DIRS) test
SOURCE_PACKAGES = ./cmd/... ./pkg/... ./test/...

SOURCE_GENERATED = pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
SOURCE_FILES = $(shell find $(CMD_SOURCE_DIRS) -type f -name "*.go" | grep -v _test.go)

# kvm2 ldflags
KVM2_LDFLAGS := -X k8s.io/minikube/pkg/drivers/kvm.version=$(VERSION) -X k8s.io/minikube/pkg/drivers/kvm.gitCommitID=$(COMMIT)

# hyperkit ldflags
HYPERKIT_LDFLAGS := -X k8s.io/minikube/pkg/drivers/hyperkit.version=$(VERSION) -X k8s.io/minikube/pkg/drivers/hyperkit.gitCommitID=$(COMMIT)

# $(call DOCKER, image, command)
define DOCKER
	docker run --rm -e GOCACHE=/app/.cache -e IN_DOCKER=1 --user $(shell id -u):$(shell id -g) -w /app -v $(PWD):/app -v $(GOPATH):/go --init $(1) /bin/bash -c '$(2)'
endef

ifeq ($(BUILD_IN_DOCKER),y)
	MINIKUBE_BUILD_IN_DOCKER=y
endif

# If we are already running in docker,
# prevent recursion by unsetting the BUILD_IN_DOCKER directives.
# The _BUILD_IN_DOCKER variables should not be modified after this conditional.
ifeq ($(IN_DOCKER),1)
	MINIKUBE_BUILD_IN_DOCKER=n
endif

ifeq ($(GOOS),windows)
	IS_EXE = .exe
	DIRSEP_ = \\
	DIRSEP = $(strip $(DIRSEP_))
	PATHSEP = ;
else
	DIRSEP = /
	PATHSEP = :
endif


out/minikube$(IS_EXE): $(SOURCE_GENERATED) $(SOURCE_FILES) go.mod
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),GOOS=$(GOOS) GOARCH=$(GOARCH) /usr/bin/make $@)
else
	go build -tags "$(MINIKUBE_BUILD_TAGS)" -ldflags="$(MINIKUBE_LDFLAGS)" -o $@ k8s.io/minikube/cmd/minikube
endif

out/minikube-windows-amd64.exe: out/minikube-windows-amd64
	cp $< $@

out/minikube-linux-x86_64: out/minikube-linux-amd64
	cp $< $@

out/minikube-linux-aarch64: out/minikube-linux-arm64
	cp $< $@

.PHONY: minikube-linux-amd64 minikube-linux-arm64 minikube-darwin-amd64 minikube-windows-amd64.exe
minikube-linux-amd64: out/minikube-linux-amd64 ## Build Minikube for Linux 64bit
minikube-linux-arm64: out/minikube-linux-arm64 ## Build Minikube for ARM 64bit
minikube-darwin-amd64: out/minikube-darwin-amd64 ## Build Minikube for Darwin 64bit
minikube-windows-amd64.exe: out/minikube-windows-amd64.exe ## Build Minikube for Windows 64bit

out/minikube-%: $(SOURCE_GENERATED) $(SOURCE_FILES)
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),/usr/bin/make $@)
else
	GOOS="$(firstword $(subst -, ,$*))" GOARCH="$(lastword $(subst -, ,$(subst $(IS_EXE), ,$*)))" \
	go build -tags "$(MINIKUBE_BUILD_TAGS)" -ldflags="$(MINIKUBE_LDFLAGS)" -a -o $@ k8s.io/minikube/cmd/minikube
endif

.PHONY: e2e-linux-amd64 e2e-darwin-amd64 e2e-windows-amd64.exe
e2e-linux-amd64: out/e2e-linux-amd64 ## Execute end-to-end testing for Linux 64bit
e2e-darwin-amd64: out/e2e-darwin-amd64 ## Execute end-to-end testing for Darwin 64bit
e2e-windows-amd64.exe: out/e2e-windows-amd64.exe ## Execute end-to-end testing for Windows 64bit

out/e2e-%: out/minikube-%
	GOOS="$(firstword $(subst -, ,$*))" GOARCH="$(lastword $(subst -, ,$(subst $(IS_EXE), ,$*)))" go test -c k8s.io/minikube/test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS)" -o $@

out/e2e-windows-amd64.exe: out/e2e-windows-amd64
	cp $< $@

minikube_iso: # old target kept for making tests happy
	echo $(ISO_VERSION) > deploy/iso/minikube-iso/board/coreos/minikube/rootfs-overlay/etc/VERSION
	if [ ! -d $(BUILD_DIR)/buildroot ]; then \
		mkdir -p $(BUILD_DIR); \
		git clone --depth=1 --branch=$(BUILDROOT_BRANCH) https://github.com/buildroot/buildroot $(BUILD_DIR)/buildroot; \
	fi;
	$(MAKE) BR2_EXTERNAL=../../deploy/iso/minikube-iso minikube_defconfig -C $(BUILD_DIR)/buildroot
	$(MAKE) -C $(BUILD_DIR)/buildroot
	mv $(BUILD_DIR)/buildroot/output/images/rootfs.iso9660 $(BUILD_DIR)/minikube.iso

# Change buildroot configuration for the minikube ISO
.PHONY: iso-menuconfig
iso-menuconfig: ## Configure buildroot configuration
	$(MAKE) -C $(BUILD_DIR)/buildroot menuconfig
	$(MAKE) -C $(BUILD_DIR)/buildroot savedefconfig

# Change the kernel configuration for the minikube ISO
.PHONY: linux-menuconfig
linux-menuconfig:  ## Configure Linux kernel configuration
	$(MAKE) -C $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/ menuconfig
	$(MAKE) -C $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/ savedefconfig
	cp $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/defconfig deploy/iso/minikube-iso/board/coreos/minikube/linux_defconfig

out/minikube.iso: $(shell find "deploy/iso/minikube-iso" -type f)
ifeq ($(IN_DOCKER),1)
	$(MAKE) minikube_iso
else
	docker run --rm --workdir /mnt --volume $(CURDIR):/mnt $(ISO_DOCKER_EXTRA_ARGS) \
		--user $(shell id -u):$(shell id -g) --env HOME=/tmp --env IN_DOCKER=1 \
		$(ISO_BUILD_IMAGE) /usr/bin/make out/minikube.iso
endif

iso_in_docker:
	docker run -it --rm --workdir /mnt --volume $(CURDIR):/mnt $(ISO_DOCKER_EXTRA_ARGS) \
		--user $(shell id -u):$(shell id -g) --env HOME=/tmp --env IN_DOCKER=1 \
		$(ISO_BUILD_IMAGE) /bin/bash

test-iso: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
	go test -v ./test/integration --tags=iso --minikube-start-args="--iso-url=file://$(shell pwd)/out/buildroot/output/images/rootfs.iso9660"

.PHONY: test-pkg
test-pkg/%: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go ## Trigger packaging test
	go test -v -test.timeout=60m ./$* --tags="$(MINIKUBE_BUILD_TAGS)"

.PHONY: all
all: cross drivers e2e-cross out/gvisor-addon ## Build all different minikube components

.PHONY: drivers
drivers: docker-machine-driver-hyperkit docker-machine-driver-kvm2 ## Build Hyperkit and KVM2 drivers

.PHONY: docker-machine-driver-hyperkit
docker-machine-driver-hyperkit: out/docker-machine-driver-hyperkit ## Build Hyperkit driver

.PHONY: docker-machine-driver-kvm2
docker-machine-driver-kvm2: out/docker-machine-driver-kvm2 ## Build KVM2 driver

.PHONY: integration
integration: out/minikube ## Trigger minikube integration test
	go test -v -test.timeout=60m ./test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS)" $(TEST_ARGS)

.PHONY: integration-none-driver
integration-none-driver: e2e-linux-$(GOARCH) out/minikube-linux-$(GOARCH)  ## Trigger minikube none driver test
	sudo -E out/e2e-linux-$(GOARCH) -testdata-dir "test/integration/testdata" -minikube-start-args="--vm-driver=none" -test.v -test.timeout=60m -binary=out/minikube-linux-amd64 $(TEST_ARGS)

.PHONY: integration-versioned
integration-versioned: out/minikube ## Trigger minikube integration testing
	go test -v -test.timeout=60m ./test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS) versioned" $(TEST_ARGS)

.PHONY: test
test: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go ## Trigger minikube test
	./test.sh

.PHONY: extract
extract: ## Compile extract tool
	go run cmd/extract/extract.go

# Regenerates assets.go when template files have been updated
pkg/minikube/assets/assets.go: $(shell find "deploy/addons" -type f)
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),/usr/bin/make $@)
endif
	which go-bindata || GO111MODULE=off GOBIN="$(GOPATH)$(DIRSEP)bin" go get github.com/jteeuwen/go-bindata/...
	PATH="$(PATH)$(PATHSEP)$(GOPATH)$(DIRSEP)bin" go-bindata -nomemcopy -o $@ -pkg assets deploy/addons/...
	-gofmt -s -w $@
	@#golint: Dns should be DNS (compat sed)
	@sed -i -e 's/Dns/DNS/g' $@ && rm -f ./-e
	@#golint: Html should be HTML (compat sed)
	@sed -i -e 's/Html/HTML/g' $@ && rm -f ./-e

pkg/minikube/translate/translations.go: $(shell find "translations/" -type f)
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),/usr/bin/make $@)
endif
	which go-bindata || GO111MODULE=off GOBIN="$(GOPATH)$(DIRSEP)bin" go get github.com/jteeuwen/go-bindata/...
	PATH="$(PATH)$(PATHSEP)$(GOPATH)$(DIRSEP)bin" go-bindata -nomemcopy -o $@ -pkg translate translations/...
	-gofmt -s -w $@
	@#golint: Json should be JSON (compat sed)
	@sed -i -e 's/Json/JSON/' $@ && rm -f ./-e

.PHONY: cross
cross: minikube-linux-amd64 minikube-linux-arm64 minikube-darwin-amd64 minikube-windows-amd64.exe ## Build minikube for all platform

.PHONY: windows
windows: minikube-windows-amd64.exe ## Build minikube for Windows 64bit

.PHONY: darwin
darwin: minikube-darwin-amd64 ## Build minikube for Darwin 64bit

.PHONY: linux
linux: minikube-linux-amd64 ## Build minikube for Linux 64bit

.PHONY: e2e-cross
e2e-cross: e2e-linux-amd64 e2e-darwin-amd64 e2e-windows-amd64.exe ## End-to-end cross test

.PHONY: checksum
checksum: ## Generate checksums
	for f in out/minikube.iso out/minikube-linux-amd64 minikube-linux-arm64 \
		 out/minikube-darwin-amd64 out/minikube-windows-amd64.exe \
		 out/docker-machine-driver-kvm2 out/docker-machine-driver-hyperkit; do \
		if [ -f "$${f}" ]; then \
			openssl sha256 "$${f}" | awk '{print $$2}' > "$${f}.sha256" ; \
		fi ; \
	done

.PHONY: clean
clean: ## Clean build
	rm -rf $(BUILD_DIR)
	rm -f pkg/minikube/assets/assets.go
	rm -f pkg/minikube/translate/translations.go
	rm -rf ./vendor

.PHONY: gendocs
gendocs: out/docs/minikube.md  ## Generate documentation

.PHONY: fmt
fmt: ## Run go fmt and modify files in place
	@gofmt -s -w $(SOURCE_DIRS)

.PHONY: gofmt
gofmt: ## Run go fmt and list the files differs from gofmt's
	@gofmt -s -l $(SOURCE_DIRS)
	@test -z "`gofmt -s -l $(SOURCE_DIRS)`"

.PHONY: vet
vet: ## Run go vet
	@go vet $(SOURCE_PACKAGES)

.PHONY: golint
golint: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go ## Run golint
	@golint -set_exit_status $(SOURCE_PACKAGES)

.PHONY: gocyclo
gocyclo: ## Run gocyclo (calculates cyclomatic complexities)
	@gocyclo -over 15 `find $(SOURCE_DIRS) -type f -name "*.go"`

out/linters/golangci-lint-$(GOLINT_VERSION):
	mkdir -p out/linters
	curl -sfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b out/linters $(GOLINT_VERSION)
	mv out/linters/golangci-lint out/linters/golangci-lint-$(GOLINT_VERSION)

# this one is meant for local use
.PHONY: lint
lint: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go out/linters/golangci-lint-$(GOLINT_VERSION) ## Run lint
	./out/linters/golangci-lint-$(GOLINT_VERSION) run ${GOLINT_OPTIONS} ./...

# lint-ci is slower version of lint and is meant to be used in ci (travis) to avoid out of memory leaks.
.PHONY: lint-ci
lint-ci: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go out/linters/golangci-lint-$(GOLINT_VERSION) ## Run lint-ci
	GOGC=${GOLINT_GOGC} ./out/linters/golangci-lint-$(GOLINT_VERSION) run \
	--concurrency ${GOLINT_JOBS} ${GOLINT_OPTIONS} ./...

.PHONY: reportcard
reportcard: ## Run goreportcard for minikube
	goreportcard-cli -v
	# "disabling misspell on large repo..."
	-misspell -error $(SOURCE_DIRS)

.PHONY: mdlint
mdlint:
	@$(MARKDOWNLINT) $(MINIKUBE_MARKDOWN_FILES)

out/docs/minikube.md: $(shell find "cmd") $(shell find "pkg/minikube/constants") pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
	go run -ldflags="$(MINIKUBE_LDFLAGS)" -tags gendocs hack/help_text/gen_help_text.go

out/minikube_$(DEB_VERSION).deb: out/minikube_$(DEB_VERSION)-0_amd64.deb
	cp $< $@

out/minikube_$(DEB_VERSION)-0_%.deb: out/minikube-linux-%
	cp -r installers/linux/deb/minikube_deb_template out/minikube_$(DEB_VERSION)
	chmod 0755 out/minikube_$(DEB_VERSION)/DEBIAN
	sed -E -i 's/--VERSION--/'$(DEB_VERSION)'/g' out/minikube_$(DEB_VERSION)/DEBIAN/control
	sed -E -i 's/--ARCH--/'$*'/g' out/minikube_$(DEB_VERSION)/DEBIAN/control
	mkdir -p out/minikube_$(DEB_VERSION)/usr/bin
	cp $< out/minikube_$(DEB_VERSION)/usr/bin/minikube
	fakeroot dpkg-deb --build out/minikube_$(DEB_VERSION) $@
	rm -rf out/minikube_$(DEB_VERSION)

out/minikube-$(RPM_VERSION).rpm: out/minikube-$(RPM_VERSION)-0.x86_64.rpm
	cp $< $@

out/minikube-$(RPM_VERSION)-0.%.rpm: out/minikube-linux-%
	cp -r installers/linux/rpm/minikube_rpm_template out/minikube-$(RPM_VERSION)
	sed -E -i 's/--VERSION--/'$(RPM_VERSION)'/g' out/minikube-$(RPM_VERSION)/minikube.spec
	sed -E -i 's|--OUT--|'$(PWD)/out'|g' out/minikube-$(RPM_VERSION)/minikube.spec
	rpmbuild -bb -D "_rpmdir $(PWD)/out" --target $* \
		 out/minikube-$(RPM_VERSION)/minikube.spec
	@mv out/$*/minikube-$(RPM_VERSION)-0.$*.rpm out/ && rmdir out/$*
	rm -rf out/minikube-$(RPM_VERSION)

.PHONY: apt
apt: out/Release ## Generate apt package file

out/Release: out/minikube_$(DEB_VERSION).deb
	( cd out && apt-ftparchive packages . ) | gzip -c > out/Packages.gz
	( cd out && apt-ftparchive release . ) > out/Release

.PHONY: yum
yum: out/repodata/repomd.xml

out/repodata/repomd.xml: out/minikube-$(RPM_VERSION).rpm
	createrepo --simple-md-filenames --no-database \
	-u "$(MINIKUBE_RELEASES_URL)/$(VERSION)/" out

.SECONDEXPANSION:
TAR_TARGETS_linux-amd64   := out/minikube-linux-amd64 out/docker-machine-driver-kvm2
TAR_TARGETS_linux-arm64   := out/minikube-linux-arm64
TAR_TARGETS_darwin-amd64  := out/minikube-darwin-amd64 out/docker-machine-driver-hyperkit
TAR_TARGETS_windows-amd64 := out/minikube-windows-amd64.exe
out/minikube-%.tar.gz: $$(TAR_TARGETS_$$*)
	tar -cvzf $@ $^

.PHONY: cross-tars
cross-tars: out/minikube-linux-amd64.tar.gz out/minikube-linux-arm64.tar.gz \ ## Cross-compile minikube
	    out/minikube-windows-amd64.tar.gz out/minikube-darwin-amd64.tar.gz
	-cd out && $(SHA512SUM) *.tar.gz > SHA512SUM

out/minikube-installer.exe: out/minikube-windows-amd64.exe
	rm -rf out/windows_tmp
	cp -r installers/windows/ out/windows_tmp
	cp -r LICENSE out/windows_tmp/LICENSE
	awk 'sub("$$", "\r")' out/windows_tmp/LICENSE > out/windows_tmp/LICENSE.txt
	sed -E -i 's/--VERSION_MAJOR--/'$(VERSION_MAJOR)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--VERSION_MINOR--/'$(VERSION_MINOR)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--VERSION_BUILD--/'$(VERSION_BUILD)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--INSTALL_SIZE--/'$(INSTALL_SIZE)'/g' out/windows_tmp/minikube.nsi
	cp out/minikube-windows-amd64.exe out/windows_tmp/minikube.exe
	makensis out/windows_tmp/minikube.nsi
	mv out/windows_tmp/minikube-installer.exe out/minikube-installer.exe
	rm -rf out/windows_tmp

out/docker-machine-driver-hyperkit:
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	docker run --rm -e GOCACHE=/app/.cache -e IN_DOCKER=1 \
		--user $(shell id -u):$(shell id -g) -w /app \
		-v $(PWD):/app -v $(GOPATH):/go --init --entrypoint "" \
		$(HYPERKIT_BUILD_IMAGE) /bin/bash -c 'CC=o64-clang CXX=o64-clang++ /usr/bin/make $@'
else
	GOOS=darwin CGO_ENABLED=1 go build \
		-ldflags="$(HYPERKIT_LDFLAGS)"   \
		-o $@ k8s.io/minikube/cmd/drivers/hyperkit
endif

hyperkit_in_docker:
	rm -f out/docker-machine-driver-hyperkit
	$(MAKE) MINIKUBE_BUILD_IN_DOCKER=y out/docker-machine-driver-hyperkit

.PHONY: install-hyperkit-driver
install-hyperkit-driver: out/docker-machine-driver-hyperkit ## Install hyperkit to local machine
	mkdir -p $(HOME)/bin
	sudo cp out/docker-machine-driver-hyperkit $(HOME)/bin/docker-machine-driver-hyperkit
	sudo chown root:wheel $(HOME)/bin/docker-machine-driver-hyperkit
	sudo chmod u+s $(HOME)/bin/docker-machine-driver-hyperkit

.PHONY: release-hyperkit-driver
release-hyperkit-driver: install-hyperkit-driver checksum ## Copy hyperkit using gsutil
	gsutil cp $(GOBIN)/docker-machine-driver-hyperkit gs://minikube/drivers/hyperkit/$(VERSION)/
	gsutil cp $(GOBIN)/docker-machine-driver-hyperkit.sha256 gs://minikube/drivers/hyperkit/$(VERSION)/

.PHONY: check-release
check-release: ## Execute go test
	go test -v ./deploy/minikube/release_sanity_test.go -tags=release

buildroot-image: $(ISO_BUILD_IMAGE) # convenient alias to build the docker container
$(ISO_BUILD_IMAGE): deploy/iso/minikube-iso/Dockerfile
	docker build $(ISO_DOCKER_EXTRA_ARGS) -t $@ -f $< $(dir $<)
	@echo ""
	@echo "$(@) successfully built"

out/storage-provisioner:
	GOOS=linux go build -o $@ -ldflags=$(PROVISIONER_LDFLAGS) cmd/storage-provisioner/main.go

.PHONY: storage-provisioner-image
storage-provisioner-image: out/storage-provisioner ## Build storage-provisioner docker image
ifeq ($(GOARCH),amd64)
	docker build -t $(REGISTRY)/storage-provisioner:$(STORAGE_PROVISIONER_TAG) -f deploy/storage-provisioner/Dockerfile  .
else
	docker build -t $(REGISTRY)/storage-provisioner-$(GOARCH):$(STORAGE_PROVISIONER_TAG) -f deploy/storage-provisioner/Dockerfile-$(GOARCH) .
endif

.PHONY: push-storage-provisioner-image
push-storage-provisioner-image: storage-provisioner-image ## Push storage-provisioner docker image using gcloud
ifeq ($(GOARCH),amd64)
	gcloud docker -- push $(REGISTRY)/storage-provisioner:$(STORAGE_PROVISIONER_TAG)
else
	gcloud docker -- push $(REGISTRY)/storage-provisioner-$(GOARCH):$(STORAGE_PROVISIONER_TAG)
endif

.PHONY: out/gvisor-addon
out/gvisor-addon: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go ## Build gvisor addon
	GOOS=linux CGO_ENABLED=0 go build -o $@ cmd/gvisor/gvisor.go

.PHONY: gvisor-addon-image
gvisor-addon-image: out/gvisor-addon  ## Build docker image for gvisor
	docker build -t $(REGISTRY)/gvisor-addon:$(GVISOR_IMAGE_VERSION) -f deploy/gvisor/Dockerfile .

.PHONY: push-gvisor-addon-image
push-gvisor-addon-image: gvisor-addon-image
	gcloud docker -- push $(REGISTRY)/gvisor-addon:$(GVISOR_IMAGE_VERSION)

.PHONY: release-iso
release-iso: minikube_iso checksum  ## Build and release .iso file
	gsutil cp out/minikube.iso gs://$(ISO_BUCKET)/minikube-$(ISO_VERSION).iso
	gsutil cp out/minikube.iso.sha256 gs://$(ISO_BUCKET)/minikube-$(ISO_VERSION).iso.sha256

.PHONY: release-minikube
release-minikube: out/minikube checksum ## Minikube release
	gsutil cp out/minikube-$(GOOS)-$(GOARCH) $(MINIKUBE_UPLOAD_LOCATION)/$(MINIKUBE_VERSION)/minikube-$(GOOS)-$(GOARCH)
	gsutil cp out/minikube-$(GOOS)-$(GOARCH).sha256 $(MINIKUBE_UPLOAD_LOCATION)/$(MINIKUBE_VERSION)/minikube-$(GOOS)-$(GOARCH).sha256

out/docker-machine-driver-kvm2:
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	docker inspect -f '{{.Id}} {{.RepoTags}}' $(KVM_BUILD_IMAGE) || $(MAKE) kvm-image
	$(call DOCKER,$(KVM_BUILD_IMAGE),/usr/bin/make $@ COMMIT=$(COMMIT))
	# make extra sure that we are linking with the older version of libvirt (1.3.1)
	test "`strings $@ | grep '^LIBVIRT_[0-9]' | sort | tail -n 1`" = "LIBVIRT_1.2.9"
else
	go build \
		-installsuffix "static" \
		-ldflags="$(KVM2_LDFLAGS)" \
		-tags "libvirt.1.3.1 without_lxc" \
		-o $@ \
		k8s.io/minikube/cmd/drivers/kvm
endif
	chmod +X $@

out/docker-machine-driver-kvm2_$(DEB_VERSION).deb: out/docker-machine-driver-kvm2
	cp -r installers/linux/deb/kvm2_deb_template out/docker-machine-driver-kvm2_$(DEB_VERSION)
	chmod 0755 out/docker-machine-driver-kvm2_$(DEB_VERSION)/DEBIAN
	sed -E -i 's/--VERSION--/'$(DEB_VERSION)'/g' out/docker-machine-driver-kvm2_$(DEB_VERSION)/DEBIAN/control
	mkdir -p out/docker-machine-driver-kvm2_$(DEB_VERSION)/usr/bin
	cp out/docker-machine-driver-kvm2 out/docker-machine-driver-kvm2_$(DEB_VERSION)/usr/bin/docker-machine-driver-kvm2
	fakeroot dpkg-deb --build out/docker-machine-driver-kvm2_$(DEB_VERSION)
	rm -rf out/docker-machine-driver-kvm2_$(DEB_VERSION)

out/docker-machine-driver-kvm2-$(RPM_VERSION).rpm: out/docker-machine-driver-kvm2
	cp -r installers/linux/rpm/kvm2_rpm_template out/docker-machine-driver-kvm2-$(RPM_VERSION)
	sed -E -i 's/--VERSION--/'$(RPM_VERSION)'/g' out/docker-machine-driver-kvm2-$(RPM_VERSION)/docker-machine-driver-kvm2.spec
	sed -E -i 's|--OUT--|'$(PWD)/out'|g' out/docker-machine-driver-kvm2-$(RPM_VERSION)/docker-machine-driver-kvm2.spec
	rpmbuild -bb -D "_rpmdir $(PWD)/out" -D "_rpmfilename docker-machine-driver-kvm2-$(RPM_VERSION).rpm" \
		out/docker-machine-driver-kvm2-$(RPM_VERSION)/docker-machine-driver-kvm2.spec
	rm -rf out/docker-machine-driver-kvm2-$(RPM_VERSION)

.PHONY: kvm-image
kvm-image: installers/linux/kvm/Dockerfile  ## Convenient alias to build the docker container
	docker build --build-arg "GO_VERSION=$(GO_VERSION)" -t $(KVM_BUILD_IMAGE) -f $< $(dir $<)
	@echo ""
	@echo "$(@) successfully built"

kvm_in_docker:
	docker inspect -f '{{.Id}} {{.RepoTags}}' $(KVM_BUILD_IMAGE) || $(MAKE) kvm-image
	rm -f out/docker-machine-driver-kvm2
	$(call DOCKER,$(KVM_BUILD_IMAGE),/usr/bin/make out/docker-machine-driver-kvm2 COMMIT=$(COMMIT))

.PHONY: install-kvm-driver
install-kvm-driver: out/docker-machine-driver-kvm2  ## Install KVM Driver
	mkdir -p $(GOBIN)
	cp out/docker-machine-driver-kvm2 $(GOBIN)/docker-machine-driver-kvm2

.PHONY: release-kvm-driver
release-kvm-driver: install-kvm-driver checksum  ## Release KVM Driver
	gsutil cp $(GOBIN)/docker-machine-driver-kvm2 gs://minikube/drivers/kvm/$(VERSION)/
	gsutil cp $(GOBIN)/docker-machine-driver-kvm2.sha256 gs://minikube/drivers/kvm/$(VERSION)/

site/themes/docsy/assets/vendor/bootstrap/package.js:
	git submodule update -f --init --recursive

out/hugo/hugo:
	mkdir -p out
	test -d out/hugo || git clone https://github.com/gohugoio/hugo.git out/hugo
	(cd out/hugo && go build --tags extended)

.PHONY: site
site: site/themes/docsy/assets/vendor/bootstrap/package.js out/hugo/hugo ## Serve the documentation site to localhost
	(cd site && ../out/hugo/hugo serve \
	  --disableFastRender \
	  --navigateToChanged \
	  --ignoreCache \
	  --buildFuture)

.PHONY: out/mkcmp
out/mkcmp:
	GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o $@ cmd/performance/mkcmp/main.go

.PHONY: out/performance-monitor
out/performance-monitor:
	GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o $@ cmd/performance/monitor/monitor.go

.PHONY: help
help:
	@printf "\033[1mAvailable targets for minikube ${VERSION}\033[21m\n"
	@printf "\033[1m--------------------------------------\033[21m\n"
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
