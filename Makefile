BUILDDIR = build
DISTDIR = dist
FAKEROOT_SERVER = $(BUILDDIR)/fakeroot_server
FAKEROOT_CLIENT = $(BUILDDIR)/fakeroot_client
PKG_OS = linux
PKG_ARCH = x86_64
PKG_NAME_SERVER = ssh-inscribe
PKG_NAME_CLIENT = sshi
PKG_MAINTAINER = Anton Aksola <aakso@iki.fi>
PKG_VERSION = $(shell git describe --tags)
PKG_SHORT_VERSION = $(shell git describe --tags --abbrev=0)
PKG_RELEASE = 1
PKG_VENDOR = Anton Aksola
PKG_BIN_SSHID = usr/bin/ssh-inscribe
PKG_BIN_SSHI = usr/bin/sshi
PKG_ETC = etc/ssh-inscribe
PKG_SSHID_CONF = $(PKG_ETC)/server_config.yaml
PKG_SERVICE_SSHID = usr/lib/systemd/system/ssh-inscribe.service
PKG_USER = sshi
PKG_GROUP = sshi
PKG_VARDIR = /var/lib/ssh-inscribe
PKG_BIN_SUFFIX =
GO_VERSION = 1.16.4
GOFLAGS=-mod=vendor

LDFLAGS += -X github.com/aakso/ssh-inscribe/pkg/globals.confDir=/$(PKG_ETC)

PKG_FILES_SERVER = $(PKG_BIN_SSHID) \
	$(PKG_SERVICE_SSHID)

PKG_FILES_CLIENT = $(PKG_BIN_SSHI)
HUBARTIFACTS = $(shell find $(BUILDDIR) -d 1 -name "ssh-inscribe*" -o -d 1 -name "sshi*" | xargs -n 1 echo -n " -a ")

BUILDER_IMAGE_NAME ?= sshi_builder_image
BUILDER_CONTAINER_NAME ?= sshi_builder

define PRE_INSTALL_SERVER
getent group $(PKG_GROUP) || groupadd -r $(PKG_GROUP)
getent passwd $(PKG_USER) || useradd -r -g $(PKG_GROUP) -d $(PKG_VARDIR) -s /sbin/nologin $(PKG_USER)
mkdir -p $(PKG_VARDIR)
chgrp $(PKG_GROUP) $(PKG_VARDIR)
chmod g+w $(PKG_VARDIR)
endef
export PRE_INSTALL_SERVER

define POST_INSTALL_SERVER
mkdir -p /$(PKG_ETC)
test -f /$(PKG_SSHID_CONF) || ssh-inscribe defaults > /$(PKG_SSHID_CONF)
endef
export POST_INSTALL_SERVER

build-server: $(BUILDDIR)/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH)

$(BUILDDIR)/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH): LDFLAGS += -X github.com/aakso/ssh-inscribe/pkg/globals.varDir=$(PKG_VARDIR)
$(BUILDDIR)/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH): LDFLAGS += -X github.com/aakso/ssh-inscribe/pkg/globals.confDir=/$(PKG_ETC)
$(BUILDDIR)/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH): LDFLAGS += -X github.com/aakso/ssh-inscribe/pkg/globals.version=$(PKG_VERSION)
$(BUILDDIR)/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH):
	GOOS=$(PKG_OS) GOFLAGS="$(GOFLAGS)" go build -ldflags '$(LDFLAGS)' \
		-o $(BUILDDIR)/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH)$(PKG_BIN_SUFFIX) .

build-client: $(BUILDDIR)/sshi-$(PKG_OS)-$(PKG_ARCH)

$(BUILDDIR)/sshi-$(PKG_OS)-$(PKG_ARCH): LDFLAGS += -X github.com/aakso/ssh-inscribe/pkg/globals.version=$(PKG_VERSION)
$(BUILDDIR)/sshi-$(PKG_OS)-$(PKG_ARCH):
	GOOS=$(PKG_OS) GOFLAGS="$(GOFLAGS)" go build -ldflags '$(LDFLAGS)' \
		-o $(BUILDDIR)/sshi-$(PKG_OS)-$(PKG_ARCH)$(PKG_BIN_SUFFIX) ./cliclient/sshi

.PHONY: dist
dist:
	@rm -rf $(DISTDIR)
	docker build -t $(BUILDER_IMAGE_NAME) -f docker/Dockerfile.builder --build-arg "GO_VERSION=$(GO_VERSION)" .
	@mkdir -p $(DISTDIR)
	@docker rm -f $(BUILDER_CONTAINER_NAME) || true
	docker run -d --rm --name=$(BUILDER_CONTAINER_NAME) $(BUILDER_IMAGE_NAME) /bin/sleep 1800
	docker exec $(BUILDER_CONTAINER_NAME) make clean-build linux darwin windows rpm \
		PKG_VERSION="$(PKG_VERSION)" \
		PKG_SHORT_VERSION="$(PKG_SHORT_VERSION)"

	docker exec $(BUILDER_CONTAINER_NAME) tar -C $(BUILDDIR) -c . | tar -C $(DISTDIR) -x

.PHONY: linux
linux:
	$(MAKE) PKG_OS=linux build-server
	$(MAKE) PKG_OS=linux build-client
.PHONY: darwin
darwin:
	$(MAKE) PKG_OS=darwin build-server
	$(MAKE) PKG_OS=darwin build-client
.PHONY: windows
windows:
	$(MAKE) PKG_OS=windows PKG_BIN_SUFFIX=.exe build-client
.PHONY: rpm
rpm:
	$(MAKE) PKG_OS=linux rpm-client rpm-server
.PHONY: release
release: clean test linux darwin rpm windows
	hub release create -d $(HUBARTIFACTS) -m $(PKG_VERSION) $(PKG_SHORT_VERSION)

.PHONY: rpm-server
rpm-server: $(BUILDDIR)/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH) rpm_setup_fakeroot rpm_setup_server_fpm_files rpm_create_server_scripts
	fpm \
		-n $(PKG_NAME_SERVER) -v "$(PKG_SHORT_VERSION)" \
		-a "$(PKG_ARCH)" -m "$(PKG_MAINTAINER)" \
		--vendor "$(PKG_VENDOR)" \
		--iteration "$(PKG_RELEASE)" \
		--rpm-os $(PKG_OS) \
		-s dir -t rpm -f \
		-C $(FAKEROOT_SERVER) \
		--pre-install $(BUILDDIR)/server_pre_install.sh \
		--post-install $(BUILDDIR)/server_post_install.sh \
		-p $(BUILDDIR) \
		$(PKG_FILES_SERVER)

.PHONY: rpm-client
rpm-client: $(BUILDDIR)/sshi-$(PKG_OS)-$(PKG_ARCH) rpm_setup_fakeroot rpm_setup_client_fpm_files
	fpm \
		-n $(PKG_NAME_CLIENT) -v "$(PKG_SHORT_VERSION)" \
		-a "$(PKG_ARCH)" -m "$(PKG_MAINTAINER)" \
		--vendor "$(PKG_VENDOR)" \
		--iteration "$(PKG_RELEASE)" \
		--rpm-os $(PKG_OS) \
		-s dir -t rpm -f \
		-C $(FAKEROOT_CLIENT) \
		-p $(BUILDDIR) \
		$(PKG_FILES_CLIENT)

.PHONY: rpm_setup_fakeroot
rpm_setup_fakeroot:
	mkdir -p $(FAKEROOT_SERVER)/$(PKG_ETC)
	mkdir -p $(FAKEROOT_SERVER)/usr/bin
	mkdir -p $(FAKEROOT_SERVER)/usr/lib/systemd/system
	mkdir -p $(FAKEROOT_CLIENT)/usr/bin

.PHONY: rpm_create_server_scripts
rpm_create_server_scripts:
	@echo "$$PRE_INSTALL_SERVER" > $(BUILDDIR)/server_pre_install.sh
	@echo "$$POST_INSTALL_SERVER" > $(BUILDDIR)/server_post_install.sh

.PHONY: rpm_setup_server_fpm_files
rpm_setup_server_fpm_files:
	cp build/ssh-inscribe-$(PKG_OS)-$(PKG_ARCH) $(FAKEROOT_SERVER)/$(PKG_BIN_SSHID)
	cp etc/ssh-inscribe.service $(FAKEROOT_SERVER)/$(PKG_SERVICE_SSHID)

.PHONY: rpm_setup_client_fpm_files
rpm_setup_client_fpm_files:
	cp build/sshi-$(PKG_OS)-$(PKG_ARCH) $(FAKEROOT_CLIENT)/$(PKG_BIN_SSHI)

.PHONY: test
test:
	go test $(shell git grep  -l '!race' ./pkg | xargs -n 1 dirname | uniq | sed 's/^/\.\//')
	go test -race ./pkg/...


.PHONY: clean-builder
clean-builder:
	docker rm -f $(BUILDER_CONTAINER_NAME) || true
	docker rmi $(BUILDER_IMAGE_NAME) || true


.PHONY: clean-build
clean-build:
	rm -rf $(BUILDDIR)
	rm -rf $(DISTDIR)

.PHONY: clean
clean: clean-builder clean-build
