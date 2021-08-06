DTS				?= optee_ffa
DTS_PATH			?= $(BUILD_PATH)/fvp
USE_FVP_BASE_PLAT		?= 1

# Use "embedded" or "fip"
SP_PACKAGING_METHOD		?= embedded

OPTEE_OS_COMMON_EXTRA_FLAGS	+= CFG_CORE_SEL1_SPMC=y CFG_CORE_FFA=y
OPTEE_OS_COMMON_EXTRA_FLAGS	+= CFG_WITH_SP=y
OPTEE_OS_COMMON_EXTRA_FLAGS	+= CFG_SECURE_PARTITION=y
OPTEE_OS_COMMON_EXTRA_FLAGS	+= CFG_CORE_HEAP_SIZE=131072
OPTEE_OS_COMMON_EXTRA_FLAGS	+= O=out/arm

TF_A_FLAGS ?= \
	ARM_TSP_RAM_LOCATION=tdram \
	BL32=$(OPTEE_OS_PAGER_V2_BIN) \
	BL33=$(EDK2_BIN) \
	DEBUG=$(DEBUG) \
	PLAT=fvp \
	SPD=spmd \
	SPMD_SPM_AT_SEL2=0

include fvp.mk

TS_INSTALL_PREFIX:=$(CURDIR)/../out-ts

# Add machinery allowing to build secure partitions from Trusted Services.
#
# build-sp <sp-name>
#   <sp name>   The name of the SP.
#
# When called build and clean targets for the SP will be defined as:
#
#   ffa-<sp name>-sp            - Build the SP with cmake, and include the SP
#                                 export makefile to make the SP binary part
#                                 of the OP-TEE OS image.
#   ffa-<sp name>-sp-clean      - run make clean on the cmake project
#   ffa-<sp name>-sp-realclean  - remove all cmake output
#
# To run these for each SP in one step, the "ffa-sp-all", "ffa-sp-all-clean" and
# "ffa-sp-all-realclean" targets are defined.
#
# The build and the clean target are added to the dependency tree of common
# op-tee targets.
#

.PHONY: ffa-sp-all
.PHONY: ffa-sp-all-clean
.PHONY: ffa-sp-all-realclean

optee-os-common: ffa-sp-all
optee-os-clean: ffa-sp-all-clean

ffa-sp-all-realclean:
	rm -rf $(TS_INSTALL_PREFIX)/opteesp

define build-sp
.PHONY: ffa-$1$3-sp
ffa-$1$3-sp: ${TS_INSTALL_PREFIX}/opteesp/lib/make/$1$3.mk

${TS_INSTALL_PREFIX}/opteesp/lib/make/$1$3.mk: optee-os-spdevkit
	CROSS_COMPILE="$$(AARCH64_CROSS_COMPILE)" cmake -G"Unix Makefiles" -DCMAKE_INSTALL_PREFIX=$${TS_INSTALL_PREFIX} \
		-DSP_DEV_KIT_DIR=$$(CURDIR)/../optee_os/out/arm/export-sp_arm64 \
		-S $$(CURDIR)/../trusted-services/deployments/$1/opteesp -B $$(CURDIR)/../ts-build/$1$3  -D$2=$3
	cmake --build $$(CURDIR)/../ts-build/$1$3 -- -j$$(nproc)
	cmake --install $$(CURDIR)/../ts-build/$1$3

-include ${TS_INSTALL_PREFIX}/opteesp/lib/make/$1$3.mk

.PHONY: ffa-$1$3-sp-clean
ffa-$1$3-sp-clean:
	cmake --build $$(CURDIR)/../ts-build/$1$3 -- clean -j$$(nproc)

.PHONY: ffa-$1$3-sp-realclean
ffa-$1$3-sp-realclean:
	rm -rf $$(CURDIR)/../ts-build/$1$3

ffa-sp-all: ${TS_INSTALL_PREFIX}/opteesp/lib/make/$1$3.mk

ffa-sp-all-clean: ffa-$1-sp-clean
ffa-sp-all-realclean: ffa-$1-sp-realclean
endef

$(eval $(call build-sp,internal-trusted-storage))
$(eval $(call build-sp,protected-storage))
$(eval $(call build-sp,attestation))
$(eval $(call build-sp,crypto))
$(eval $(call build-sp,spm_test,SP_NUMBER,1))
$(eval $(call build-sp,spm_test,SP_NUMBER,2))
$(eval $(call build-sp,spm_test,SP_NUMBER,3))


# If FIP packaging method is selected, TF-A requires a number of config options:
# - ARM_BL2_SP_LIST_DTS:   This file will be included into the TB_FW_CONFIG DT
#                          of TF-A. It contains the UUID and load address of SP
#                          packages present in the FIP, BL2 will load them based
#                          on this information.
# - ARM_SPMC_MANIFEST_DTS: Contains information about the SPMC: consumed by the
#                          SPMD at SPMC init. And about the SP packages: the
#                          SPMC can only know where the packages were loaded by
#                          BL2 based on this file.
# - SP_LAYOUT_FILE:        JSON file which describes the corresponding SP image
#                          and SP manifest DT pairs, TF-A will create the SP
#                          packages based on this. However, the TS build
#                          provides a separate JSON file for each SP. A Python
#                          snippet is used to merge these JSONs into one file.
ifeq (fip, $(SP_PACKAGING_METHOD))
SP_LAYOUT_FILE := $(TS_INSTALL_PREFIX)/opteesp/json/sp_layout.json

TF_A_FLAGS+=SP_LAYOUT_FILE=$(SP_LAYOUT_FILE)
TF_A_FLAGS+=ARM_BL2_SP_LIST_DTS=$(CURDIR)/fvp/bl2_sp_images.dtsi
TF_A_FLAGS+=ARM_SPMC_MANIFEST_DTS=$(CURDIR)/fvp/spmc_manifest.dts
OPTEE_OS_COMMON_EXTRA_FLAGS+=CFG_FIP_SP=y

MERGE_JSON_PY := import json, sys
MERGE_JSON_PY += \ncombined = {}
MERGE_JSON_PY += \nfor path in sys.stdin.read().split():
MERGE_JSON_PY += \n  with open(path) as f:
MERGE_JSON_PY += \n    current = json.load(f)
MERGE_JSON_PY += \n    combined = {**combined, **current}
MERGE_JSON_PY += \nprint(json.dumps(combined, indent=4))

$(SP_LAYOUT_FILE): ffa-sp-all
	@echo $(TS_SP_JSON_LIST) | python3 -c "$$(echo -e '$(MERGE_JSON_PY)')" > $(SP_LAYOUT_FILE)

.PHONY: ffa-sp-layout-clean
ffa-sp-layout-clean:
	@rm -f $(SP_LAYOUT_FILE)

arm-tf: $(SP_LAYOUT_FILE)
ffa-sp-all-clean: ffa-sp-layout-clean
endif

# Add targets to build the "arm_ffa_user" Linux Kernel module.
arm_ffa_user: linux
	$(eval ROOT:=$(CURDIR)/..)
	make -C $(CURDIR)/../linux_poc $(LINUX_COMMON_FLAGS) install
	find $(TS_INSTALL_PREFIX)/opteesp/bin -name "[0-9a-f-]*.elf" -type f | \
		sed -n "s@.*/\(.*\).stripped.elf@\1@gp" | tr '\n' ',' | \
		head -c -1 > $(SHARED_DIR)/sp_uuid_list.txt

arm_ffa_user_clean:
	make -C $(CURDIR)/../linux_poc clean

all: arm_ffa_user
