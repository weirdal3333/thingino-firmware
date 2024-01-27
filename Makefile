#
# OpenIPC Firmware
# themactep edition
# https://github.com/themactep/openipc-firmware

BUILDROOT_VERSION := 2023.11.1

# Camera IP address
CAMERA_IP_ADDRESS ?= 192.168.1.10

# Device of SD card
SDCARD_DEVICE ?= /dev/sdc

FLASH_SIZE_MB ?= 8

SENSOR_MODEL ?= jxf23

# TFTP server IP address to upload compiled images to
TFTP_IP_ADDRESS ?= 192.168.1.254

# Buildroot downloads directory
# can be reused from environment, just export the value:
# export BR2_DL_DIR = /path/to/your/local/storage
BR2_DL_DIR ?= $(HOME)/dl

# directory for extracting Buildroot sources
SRC_DIR ?= $(HOME)/src
BUILDROOT_BUNDLE := $(SRC_DIR)/buildroot-$(BUILDROOT_VERSION).tar.gz
BUILDROOT_DIR := $(SRC_DIR)/buildroot-$(BUILDROOT_VERSION)

# working directory
OUTPUT_DIR = $(HOME)/openipc-fw-output/$(BOARD)-br$(BUILDROOT_VERSION)
STDOUT_LOG = $(OUTPUT_DIR)/compilation.log
STDERR_LOG = $(OUTPUT_DIR)/compilation-errors.log

# OpenIPC project directories
BR2_EXTERNAL := $(CURDIR)
SCRIPTS_DIR := $(CURDIR)/scripts

# make command for buildroot
BR2_MAKE = $(MAKE) -C $(BUILDROOT_DIR) BR2_EXTERNAL=$(BR2_EXTERNAL) O=$(OUTPUT_DIR)

BOARDS = $(shell find ./configs/*_defconfig | sort | sed -E "s/^\.\/configs\/(.*)_defconfig/'\1' '\1'/")
#BOARDS = $(shell find $(CURDIR)/br-ext-*/configs/*_defconfig | sort | awk -F '/' '{print $$NF}')

# check BOARD value from env
# if empty, check for journal
# if found, restore BOARD from journal, ask permision to reuse the value.
# if told no, reset the BOARD and remove the journal
ifeq ($(BOARD),)
ifeq ($(shell test -f .board; echo $$?),0)
BOARD = $(shell cat .board)
ifeq ($(shell whiptail --yesno "Use $(BOARD) from the previous session?" 10 40 3>&1 1>&2 2>&3; echo $$?),1)
BOARD =
endif
endif
endif

# if still no BOARD, select it from a list of boards
ifeq ($(BOARD),)
BOARD := $(or $(shell whiptail --title "Boards" --menu "Select a board:" 20 76 12 --notags $(BOARDS) 3>&1 1>&2 2>&3))
endif

# if still no BOARD, bail out with an error
ifeq ($(BOARD),)
$(error NO BOARD!)
endif

# otherwise, save selection to the journal
$(shell echo $(BOARD)>.board)

# find board config file
BOARD_CONFIG = $(shell find $(BR2_EXTERNAL)/configs/ -name $(BOARD)_defconfig)

# if board config file not found, bail out with an error
ifeq ($(BOARD_CONFIG),)
$(error Cannot find a config for the board: $(BOARD))
endif

# if multimple config files are found, bail out with an error
ifeq ($(echo $(BOARD_CONFIGS) | wc -w), 1)
$(error Found multiple configs for $(BOARD): $(BOARD_CONFIG))
endif

# read common config file
include $(BR2_EXTERNAL)/common.mk

# read camera config file
include $(BOARD_CONFIG)

# include device tree makefile
include $(BR2_EXTERNAL)/external.mk

# hardcoded variables
WGET := wget --quiet --no-verbose --retry-connrefused --continue --timeout=3
KERNEL_BIN := $(OUTPUT_DIR)/images/uImage
ROOTFS_BIN := $(OUTPUT_DIR)/images/rootfs.squashfs
ROOTFS_TAR := $(OUTPUT_DIR)/images/rootfs.tar

ALIGN_BLOCK := $(shell echo $$(( 32 * 1024 )))

FULL_FIRMWARE_NAME = openipc-$(SOC_MODEL)-$(FLASH_SIZE_MB)mb.bin
FULL_FIRMWARE_BIN = $(OUTPUT_DIR)/images/$(FULL_FIRMWARE_NAME)

U_BOOT_GITHUB_URL := https://github.com/OpenIPC/firmware/releases/download/latest
U_BOOT_BIN = $(OUTPUT_DIR)/images/u-boot-$(SOC_MODEL)-universal.bin

U_BOOT_OFFSET := 0
U_BOOT_SIZE = $(shell stat -c%s $(U_BOOT_BIN))
U_BOOT_SIZE_ALIGNED = $(shell echo $$(( ($(U_BOOT_SIZE) / $(ALIGN_BLOCK) + 1) * $(ALIGN_BLOCK) )))

U_BOOT_ENV_OFFSET := $(shell echo $$(( 0x40000 ))) # 256K
U_BOOT_ENV_SIZE := $(shell echo $$(( 0x10000 ))) # 64K

KERNEL_SIZE = $(shell stat -c%s $(KERNEL_BIN))
KERNEL_SIZE_ALIGNED = $(shell echo $$(( ($(KERNEL_SIZE) / $(ALIGN_BLOCK) + 1) * $(ALIGN_BLOCK) )))
KERNEL_OFFSET = $(shell echo $$(( $(U_BOOT_ENV_OFFSET) + $(U_BOOT_ENV_SIZE) )))

ROOTFS_SIZE = $(shell stat -c%s $(ROOTFS_BIN))
ROOTFS_SIZE_ALIGNED = $(shell echo $$(( ($(ROOTFS_SIZE) / $(ALIGN_BLOCK) + 1) * $(ALIGN_BLOCK) )))
ROOTFS_OFFSET = $(shell echo $$(( $(KERNEL_OFFSET) + $(KERNEL_SIZE_ALIGNED) )))

ifeq ($(SENSOR_MODEL),)
$(error SENSOR IS NOT SET)
endif

.PHONY: all toolchain sdk clean defconfig distclean help pack pack_flex tftp sdcard install-prerequisites overlayed-rootfs-% br-%

all: defconfig
ifndef BOARD
	$(MAKE) BOARD=$(BOARD) $@ 1>>$(STDOUT_LOG) # 2>>$(STDERR_LOG)
endif
	$(BR2_MAKE) all 1>>$(STDOUT_LOG) # 2>>$(STDERR_LOG)

# delete all build/{package} and per-package/{package} files
br-%-dirclean: defconfig
	rm -rf $(OUTPUT_DIR)/per-package/$(subst -dirclean,,$(subst br-,,$@)) \
			$(OUTPUT_DIR)/build/$(subst -dirclean,,$(subst br-,,$@))*

br-%: defconfig
	$(BR2_MAKE) $(subst br-,,$@)

toolchain: defconfig
	$(BR2_MAKE) toolchain

sdk: defconfig
	$(BR2_MAKE) sdk

clean: defconfig
	$(BR2_MAKE) clean
	rm -rvf $(OUTPUT_DIR)/target $(OUTPUT_DIR)/.config

defconfig: $(BUILDROOT_DIR)
	@rm -rvf $(OUTPUT_DIR)/.config
	$(BR2_MAKE) BR2_DEFCONFIG=$(BOARD_CONFIG) defconfig

delete_full_bin:
	@if [ -f $(FULL_FIRMWARE_BIN) ]; then rm $(FULL_FIRMWARE_BIN); fi

distclean:
	# $(BOARD_MAKE) distclean
	if [ -d "$(OUTPUT_DIR)" ]; then rm -rf $(OUTPUT_DIR); fi

pack: defconfig delete_full_bin $(FULL_FIRMWARE_BIN)
	@echo "DONE"

# upload kernel. rootfs and full image to tftp server
tftp: $(FULL_FIRMWARE_BIN)
	@busybox tftp -l $(KERNEL_BIN) -r uImage.$(SOC_FAMILY) -p $(TFTP_IP_ADDRESS)
	@busybox tftp -l $(ROOTFS_BIN) -r rootfs.squashfs.$(SOC_FAMILY) -p $(TFTP_IP_ADDRESS)
	@busybox tftp -l $(FULL_FIRMWARE_BIN) -r $(FULL_FIRMWARE_NAME) -p $(TFTP_IP_ADDRESS)

# upload full image to an sd card
sdcard: $(FULL_FIRMWARE_BIN)
	@cp -v $(KERNEL_BIN) $$(mount | grep $(SDCARD_DEVICE)1 | awk '{print $$3}')
	@cp -v $(ROOTFS_BIN) $$(mount | grep $(SDCARD_DEVICE)1 | awk '{print $$3}')
	@cp -v $(FULL_FIRMWARE_BIN) $$(mount | grep $(SDCARD_DEVICE)1 | awk '{print $$3}')
	sync
	umount $(SDCARD_DEVICE)1
	@echo "Done"

# upload kernel and rootfs in /tmp/ directory of the camera
upload:
	scp -O $(KERNEL_BIN) root@$(CAMERA_IP_ADDRESS):/tmp/uImage
	scp -O $(ROOTFS_BIN) root@$(CAMERA_IP_ADDRESS):/tmp/rootfs.squashfs

# upload firmware file on the camera via ssh and run upgrade remotely
upgrade: upload
	ssh root@$(CAMERA_IP_ADDRESS) "sysupgrade -z --kernel=/tmp/uImage --rootfs=/tmp/rootfs.squashfs --force_ver"

# install prerequisites
install-prerequisites:
ifneq ($(shell id -u), 0)
	$(error requested operation requires superuser privilege)
else
	@DEBIAN_FRONTEND=noninteractive apt-get update
	@DEBIAN_FRONTEND=noninteractive apt-get -y install build-essential bc bison cpio curl file flex git libncurses-dev make rsync unzip wget whiptail
endif

# prepare: defconfig $(BUILDROOT_DIR)/Makefile
#	@echo "Buildroot $(BUILDROOT_VERSION) is in $(BUILDROOT_DIR) directory."

# create output directory
$(OUTPUT_DIR):
	mkdir -p $(OUTPUT_DIR)

# check for toolchain parameters file
#$(OUTPUT_DIR)/toolchain-params.mk:
#	echo "$@ is not defined!"

# create source directory
$(SRC_DIR):
	mkdir -p $(SRC_DIR)

# install Buildroot sources
#$(BUILDROOT_DIR)/.installed: $(BUILDROOT_BUNDLE)
$(BUILDROOT_DIR): $(BUILDROOT_BUNDLE)
	ls -l $(dirname $@)
	mkdir -p $(SRC_DIR)
	tar -C $(SRC_DIR) -xf $(BUILDROOT_BUNDLE)
	touch $@

# download Buildroot bundle
$(BUILDROOT_BUNDLE):
	$(WGET) -O $@ https://github.com/buildroot/buildroot/archive/refs/tags/$(BUILDROOT_VERSION).tar.gz
	#https://github.com/buildroot/buildroot/archive/refs/heads/master.zip

## create defconfig
#$(OUTPUT_DIR)/.config: $(BUILDROOT_DIR)/.installed
#	$(info $(BR2_MAKE) BR2_DEFCONFIG=$(BOARD_CONFIG) defconfig)
#	$(BR2_MAKE) BR2_DEFCONFIG=$(BOARD_CONFIG) defconfig

# download bootloader
# FIXME: should be built locally
$(U_BOOT_BIN):
	$(info U_BOOT_BIN:          $@)
	$(WGET) -O $@ $(U_BOOT_GITHUB_URL)/u-boot-$(SOC_MODEL)-universal.bin || \
	$(WGET) -O $@ $(U_BOOT_GITHUB_URL)/u-boot-$(SOC_FAMILY)-universal.bin

# rebuild Linux kernel
$(KERNEL_BIN):
	$(info KERNEL_BIN:          $@)
	$(info KERNEL_SIZE:         $(KERNEL_SIZE))
	$(info KERNEL_SIZE_ALIGNED: $(KERNEL_SIZE_ALIGNED))
	$(BR2_MAKE) linux-rebuild
#	mv -vf $(OUTPUT_DIR)/images/uImage $@

# rebuild rootfs
$(ROOTFS_BIN):
	$(info ROOTFS_BIN:          $@)
	$(info ROOTFS_SIZE:         $(ROOTFS_SIZE))
	$(info ROOTFS_SIZE_ALIGNED: $(ROOTFS_SIZE_ALIGNED))
	$(BR2_MAKE) all
#	mv -vf $(OUTPUT_DIR)/images/rootfs.squashfs $@

# create .tar file of rootfs
$(ROOTFS_TAR):
	$(info ROOTFS_TAR:          $@)
	$(BR2_MAKE) all
#	mv -vf $(OUTPUT_DIR)/images/rootfs.tar $@

# create .cpio file of rootfs
$(ROOTFS_CPIO):
	$(info ROOTFS_CPIO:         $@)
	$(BR2_MAKE) all
#	mv -vf $(OUTPUT_DIR)/images/rootfs.cpio $@

$(FULL_FIRMWARE_BIN): $(U_BOOT_BIN) $(KERNEL_BIN) $(ROOTFS_BIN)
	@dd if=/dev/zero bs=$$(($(FLASH_SIZE_HEX))) skip=0 count=1 status=none | tr '\000' '\377' > $@
	@dd if=$(U_BOOT_BIN) bs=$(U_BOOT_SIZE) seek=$(U_BOOT_OFFSET) count=1 of=$@ conv=notrunc status=none
	@dd if=$(KERNEL_BIN) bs=$(KERNEL_SIZE) seek=$(KERNEL_OFFSET)B count=1 of=$@ conv=notrunc status=none
	@dd if=$(ROOTFS_BIN) bs=$(ROOTFS_SIZE) seek=$(ROOTFS_OFFSET)B count=1 of=$@ conv=notrunc status=none

info:
	$(info =========================================================================)
	$(info BASE_DIR:           $(BASE_DIR))
	$(info BOARD:              $(BOARD))
	$(info BOARD_CONFIG:       $(BOARD_CONFIG))
	$(info BR2_DL_DIR:         $(BR2_DL_DIR))
	$(info BR2_EXTERNAL:       $(BR2_EXTERNAL))
	$(info BR2_KERNEL:         $(BR2_KERNEL))
	$(info BR2_MAKE:           $(BR2_MAKE))
	$(info BUILDROOT_BUNDLE:   $(BUILDROOT_BUNDLE))
	$(info BUILDROOT_DIR:      $(BUILDROOT_DIR))
	$(info BUILDROOT_VERSION:  $(BUILDROOT_VERSION))
	$(info CAMERA_IP_ADDRESS:  $(CAMERA_IP_ADDRESS))
	$(info CONFIG_DIR:         $(CONFIG_DIR))
	$(info CURDIR:             $(CURDIR))
	$(info FLASH_SIZE_HEX:     $(FLASH_SIZE_HEX))
	$(info FLASH_SIZE_MB:      $(FLASH_SIZE_MB))
	$(info KERNEL:             $(KERNEL))
	$(info SENSOR_MODEL:       $(SENSOR_MODEL))
	$(info SOC_FAMILY:         $(SOC_FAMILY))
	$(info SOC_MODEL:          $(SOC_MODEL))
	$(info SOC_VENDOR:         $(SOC_VENDOR))
	$(info TOOLCHAIN:          $(TOOLCHAIN))
	$(info OUTPUT_DIR:         $(OUTPUT_DIR))
	$(info SCRIPTS_DIR:        $(SCRIPTS_DIR))
	$(info SRC_DIR:            $(SRC_DIR))
	$(info STDERR_LOG:         $(STDERR_LOG))
	$(info STDOUT_LOG:         $(STDOUT_LOG))
	$(info TFTP_IP_ADDRESS:    $(TFTP_IP_ADDRESS))
	$(info TOPDIR:             $(TOPDIR))
	$(info U_BOOT_BIN:         $(U_BOOT_BIN))
	$(info U_BOOT_GITHUB_URL:  $(U_BOOT_GITHUB_URL))
	$(info =========================================================================)

help:
	@echo "\n\
	BR-OpenIPC usage:\n\
	  - make help - print this help\n\
	  - make install-prerequisites - install system deps\n\
	  - make BOARD=<BOARD-ID> - build all needed for a board (toolchain, kernel and rootfs images)\n\
	  - make BOARD=<BOARD-ID> pack - create a full binary for programmer\n\
	  - make BOARD=<BOARD-ID> clean - cleaning before reassembly\n\
	  - make BOARD=<BOARD-ID> distclean - switching to the factory state\n\
	  - make BOARD=<BOARD-ID> prepare - download and unpack buildroot\n\
	  - make BOARD=<BOARD-ID> board-info - write to stdout information about selected board\n\
	Example:\n\
	    make overlayed-rootfs-squashfs ROOTFS_OVERLAYS=./examples/echo_server/overlay\n\
	"

###### Buildroot directories
# TOPDIR             = ./buildroot
# STAGING_DIR        = ./output/staging
# TARGET_DIR         = ./output/target

# BASE_DIR           = ./output
# BASE_TARGET_DIR    = ./output/target
# BINARIES_DIR       = ./output/images
# HOST_DIR           = ./output/host
# HOST_DIR_SYMLINK   = ./output/host
# BUILD_DIR          = ./output/build
# LEGAL_INFO_DIR     = ./output/legal-info
# GRAPHS_DIR         = ./output/graphs
# PER_PACKAGE_DIR    = ./output/per-package
# CPE_UPDATES_DIR    = ./output/cpe-updates

#  <pkg>                         - Build and install <pkg> and all its dependencies
#  <pkg>-source                  - Only download the source files for <pkg>
#  <pkg>-extract                 - Extract <pkg> sources
#  <pkg>-patch                   - Apply patches to <pkg>
#  <pkg>-depends                 - Build <pkg>'s dependencies
#  <pkg>-configure               - Build <pkg> up to the configure step
#  <pkg>-build                   - Build <pkg> up to the build step
#  <pkg>-show-info               - Generate info about <pkg>, as a JSON blurb
#  <pkg>-show-depends            - List packages on which <pkg> depends
#  <pkg>-show-rdepends           - List packages which have <pkg> as a dependency
#  <pkg>-show-recursive-depends  - Recursively list packages on which <pkg> depends
#  <pkg>-show-recursive-rdepends - Recursively list packages which have <pkg> as a dependency
#  <pkg>-graph-depends           - Generate a graph of <pkg>'s dependencies
#  <pkg>-graph-rdepends          - Generate a graph of <pkg>'s reverse dependencies
#  <pkg>-dirclean                - Remove <pkg> build directory
#  <pkg>-reconfigure             - Restart the build from the configure step
#  <pkg>-rebuild                 - Restart the build from the build step
#  <pkg>-reinstall               - Restart the build from the install step
#  busybox-menuconfig            - Run BusyBox menuconfig
#  linux-menuconfig              - Run Linux kernel menuconfig
#  linux-savedefconfig           - Run Linux kernel savedefconfig
#  linux-update-defconfig        - Save the Linux configuration to the path specified by BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE
#  list-defconfigs               - list all defconfigs (pre-configured minimal systems)
#  source                        - download all sources needed for offline-build
#  external-deps                 - list external packages used
#  legal-info                    - generate info about license compliance
#  show-info                     - generate info about packages, as a JSON blurb
#  pkg-stats                     - generate info about packages as JSON and HTML
#  printvars                     - dump internal variables selected with VARS=...
#  make V=0|1                    - 0 => quiet build (default), 1 => verbose build
