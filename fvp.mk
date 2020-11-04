################################################################################
# Following variables defines how the NS_USER (Non Secure User - Client
# Application), NS_KERNEL (Non Secure Kernel), S_KERNEL (Secure Kernel) and
# S_USER (Secure User - TA) are compiled
################################################################################
COMPILE_NS_USER   ?= 64
override COMPILE_NS_KERNEL := 64
COMPILE_S_USER    ?= 64
COMPILE_S_KERNEL  ?= 64

OPTEE_OS_PLATFORM = vexpress-fvp

include common.mk


################################################################################
# Paths to git projects and various binaries
################################################################################
TF_A_PATH		?= $(ROOT)/trusted-firmware-a
ifeq ($(DEBUG),1)
TF_A_BUILD		?= debug
else
TF_A_BUILD		?= release
endif
EDK2_PATH		?= $(ROOT)/edk2
EDK2_PLATFORMS_PATH	?= $(ROOT)/edk2-platforms
EDK2_TOOLCHAIN		?= GCC49
EDK2_ARCH		?= AARCH64
ifeq ($(DEBUG),1)
EDK2_BUILD		?= DEBUG
else
EDK2_BUILD		?= RELEASE
endif
EDK2_BIN		?= $(EDK2_PLATFORMS_PATH)/Build/ArmVExpress-FVP-AArch64/$(EDK2_BUILD)_$(EDK2_TOOLCHAIN)/FV/FVP_$(EDK2_ARCH)_EFI.fd
USE_FVP_BASE_PLAT	?= 0
ifeq ($(USE_FVP_BASE_PLAT),1)
FVP_PATH		?= /opt/fvp/latest
FVP_BIN			?= FVP_Base_RevC-2xAEMv8A
else
FOUNDATION_PATH		?= $(ROOT)/Foundation_Platformpkg
ifeq ($(wildcard $(FOUNDATION_PATH)),)
$(error $(FOUNDATION_PATH) does not exist)
endif
endif
GRUB_PATH		?= $(ROOT)/grub
GRUB_CONFIG_PATH	?= $(BUILD_PATH)/fvp/grub
OUT_PATH		?= $(ROOT)/out
GRUB_BIN		?= $(OUT_PATH)/bootaa64.efi
BOOT_IMG		?= $(OUT_PATH)/boot-fat.uefi.img
OVERLAY_DIR		?= ${BUILD_PATH}/fvp/overlay
SHARED_DIR		?= $(ROOT)/shared

################################################################################
# Targets
################################################################################
all: arm-tf boot-img edk2 grub linux optee-os
clean: arm-tf-clean boot-img-clean buildroot-clean edk2-clean grub-clean \
	optee-os-clean


include toolchain.mk

################################################################################
# Folders
################################################################################
$(OUT_PATH):
	mkdir -p $@

################################################################################
# ARM Trusted Firmware
################################################################################
TF_A_EXPORTS ?= \
	CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"

TF_A_FLAGS ?= \
	BL32=$(OPTEE_OS_HEADER_V2_BIN) \
	BL32_EXTRA1=$(OPTEE_OS_PAGER_V2_BIN) \
	BL32_EXTRA2=$(OPTEE_OS_PAGEABLE_V2_BIN) \
	BL33=$(EDK2_BIN) \
	DEBUG=$(DEBUG) \
	ARM_TSP_RAM_LOCATION=tdram \
	FVP_USE_GIC_DRIVER=FVP_GICV3 \
	PLAT=fvp \
	SPD=opteed

arm-tf: optee-os edk2
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) $(TF_A_FLAGS) all fip

arm-tf-clean:
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) $(TF_A_FLAGS) clean

################################################################################
# EDK2 / Tianocore
################################################################################
define edk2-env
	export WORKSPACE=$(EDK2_PLATFORMS_PATH)
endef

define edk2-call
	$(EDK2_TOOLCHAIN)_$(EDK2_ARCH)_PREFIX=$(AARCH64_CROSS_COMPILE) \
	build -n `getconf _NPROCESSORS_ONLN` -a $(EDK2_ARCH) \
		-t $(EDK2_TOOLCHAIN) -p Platform/ARM/VExpressPkg/ArmVExpress-FVP-AArch64.dsc -b $(EDK2_BUILD)
endef

edk2: edk2-common

edk2-clean: edk2-clean-common

################################################################################
# Linux kernel
################################################################################
LINUX_DEFCONFIG_COMMON_ARCH := arm64
LINUX_DEFCONFIG_COMMON_FILES := \
		$(LINUX_PATH)/arch/arm64/configs/defconfig \
		$(CURDIR)/kconfigs/fvp.conf

linux-defconfig: $(LINUX_PATH)/.config

LINUX_COMMON_FLAGS += ARCH=arm64

linux: linux-common

linux-defconfig-clean: linux-defconfig-clean-common

LINUX_CLEAN_COMMON_FLAGS += ARCH=arm64

linux-clean: linux-clean-common

LINUX_CLEANER_COMMON_FLAGS += ARCH=arm64

linux-cleaner: linux-cleaner-common

################################################################################
# OP-TEE
################################################################################
OPTEE_OS_COMMON_FLAGS += CFG_ARM_GICV3=y
optee-os: optee-os-common

optee-os-clean: optee-os-clean-common

optee-os-spdevkit: optee-os-spdevkit-common

################################################################################
# grub
################################################################################
grub-flags := CC="$(CCACHE)gcc" \
	TARGET_CC="$(AARCH64_CROSS_COMPILE)gcc" \
	TARGET_OBJCOPY="$(AARCH64_CROSS_COMPILE)objcopy" \
	TARGET_NM="$(AARCH64_CROSS_COMPILE)nm" \
	TARGET_RANLIB="$(AARCH64_CROSS_COMPILE)ranlib" \
	TARGET_STRIP="$(AARCH64_CROSS_COMPILE)strip" \
	--disable-werror

GRUB_MODULES += boot chain configfile echo efinet eval ext2 fat font gettext \
		gfxterm gzio help linux loadenv lsefi normal part_gpt \
		part_msdos read regexp search search_fs_file search_fs_uuid \
		search_label terminal terminfo test tftp time

$(GRUB_PATH)/configure: $(GRUB_PATH)/configure.ac
	cd $(GRUB_PATH) && ./autogen.sh

$(GRUB_PATH)/Makefile: $(GRUB_PATH)/configure
	cd $(GRUB_PATH) && ./configure --target=aarch64 --enable-boot-time $(grub-flags)

.PHONY: grub
grub: $(GRUB_PATH)/Makefile | $(OUT_PATH)
	$(MAKE) -C $(GRUB_PATH) && \
	cd $(GRUB_PATH) && ./grub-mkimage \
		--output=$(GRUB_BIN) \
		--config=$(GRUB_CONFIG_PATH)/grub.cfg \
		--format=arm64-efi \
		--directory=grub-core \
		--prefix=/boot/grub \
		$(GRUB_MODULES)

.PHONY: grub-clean
grub-clean:
	@if [ -e $(GRUB_PATH)/Makefile ]; then $(MAKE) -C $(GRUB_PATH) clean; fi
	@rm -f $(GRUB_BIN)
	@rm -f $(GRUB_PATH)/configure

################################################################################
# Buildroot
################################################################################
BR2_ROOTFS_OVERLAY=$(OVERLAY_DIR)

################################################################################
# Shared directory
################################################################################
.PHONY: shared_directory
shared_directory:
	mkdir -p $(SHARED_DIR)

################################################################################
# Boot Image
################################################################################
.PHONY: boot-img
boot-img: linux grub buildroot dtb shared_directory
	rm -f $(BOOT_IMG)
	mformat -i $(BOOT_IMG) -n 64 -h 255 -T 131072 -v "BOOT IMG" -C ::
	mcopy -i $(BOOT_IMG) $(LINUX_PATH)/arch/arm64/boot/Image ::
	mcopy -i $(BOOT_IMG) $(DTB) ::/fvp.dtb
	mmd -i $(BOOT_IMG) ::/EFI
	mmd -i $(BOOT_IMG) ::/EFI/BOOT
	mcopy -i $(BOOT_IMG) $(ROOT)/out-br/images/rootfs.cpio.gz ::/initrd.img
	mcopy -i $(BOOT_IMG) $(GRUB_BIN) ::/EFI/BOOT/bootaa64.efi
	mcopy -i $(BOOT_IMG) $(GRUB_CONFIG_PATH)/grub.cfg ::/EFI/BOOT/grub.cfg

.PHONY: boot-img-clean
boot-img-clean:
	rm -f $(BOOT_IMG)

################################################################################
# DTB
################################################################################
ifeq ($(USE_FVP_BASE_PLAT),1)
DTSI_PATH	?= $(TF_A_PATH)/fdts
DTS_PATH	?= $(TF_A_PATH)/fdts
DTS		?= fvp-base-gicv3-psci-1t
DTS_PRE		?= $(OUT_PATH)/$(DTS).pre.dts
DTB		?= $(OUT_PATH)/$(DTS).dtb

$(DTB): $(DTS_PATH)/$(DTS).dts
	gcc -E -P -nostdinc -undef -x assembler-with-cpp -I$(DTSI_PATH) \
		-I$(TF_A_PATH)/include -o $(DTS_PRE) $(DTS_PATH)/$(DTS).dts
	dtc -i$(DTSI_PATH) -I dts -O dtb -o $(DTB) $(DTS_PRE)

.PHONY: dtb-clean
dtb-clean:
	@rm -f $(DTB) $(DTS_PRE)
else
DTB	:= $(LINUX_PATH)/arch/arm64/boot/dts/arm/foundation-v8-gicv3-psci.dtb
endif

.PHONY: dtb
dtb: $(DTB)

################################################################################
# Run targets
################################################################################
# This target enforces updating root fs etc
run: all
	$(MAKE) run-only

run-only:
ifeq ($(USE_FVP_BASE_PLAT),1)
	$(FVP_PATH)/$(FVP_BIN) \
	-C bp.flashloader0.fname=$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/fip.bin \
	-C bp.secureflashloader.fname=$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/bl1.bin \
	-C bp.secure_memory=1 \
	-C bp.ve_sysregs.exit_on_shutdown=1 \
	-C bp.virtioblockdevice.image_path=$(BOOT_IMG) \
	-C bp.virtiop9device.root_path=$(SHARED_DIR) \
	-C cache_state_modelled=0 \
	-C cluster0.NUM_CORES=4 \
	-C cluster1.NUM_CORES=4 \
	-C pctl.startup=0.0.0.0
else
	@cd $(FOUNDATION_PATH); \
	$(FOUNDATION_PATH)/models/Linux64_GCC-6.4/Foundation_Platform \
	--arm-v8.0 \
	--cores=4 \
	--secure-memory \
	--visualization \
	--gicv3 \
	--data="$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/bl1.bin"@0x0 \
	--data="$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/fip.bin"@0x8000000 \
	--block-device=$(BOOT_IMG)
endif
