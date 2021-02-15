DTS				?= optee_ffa
DTS_PATH			?= $(BUILD_PATH)/fvp
USE_FVP_BASE_PLAT		?= 1

OPTEE_OS_COMMON_EXTRA_FLAGS	+= CFG_CORE_SEL1_SPMC=y CFG_CORE_FFA=y
OPTEE_OS_COMMON_EXTRA_FLAGS	+= CFG_WITH_SP=y
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
# The build and the clean target are added to the dependency tree of common
# op-tee targets.
#

define build-sp
.PHONY: ffa-$1-sp
ffa-$1-sp: ffa-$1-sp-build
	$$(eval include $${TS_INSTALL_PREFIX}/opteesp/lib/make/$1.mk)

.PHONY: ffa-$1-sp-build
ffa-$1-sp-build: optee-os-spdevkit
	CROSS_COMPILE="$$(AARCH64_CROSS_COMPILE)" cmake -G"Unix Makefiles" -DCMAKE_INSTALL_PREFIX=$${TS_INSTALL_PREFIX} \
		-DSP_DEV_KIT_DIR=$$(CURDIR)/../optee_os/out/arm/export-sp_arm64 \
		-S $$(CURDIR)/../trusted-services/deployments/$1/opteesp -B $$(CURDIR)/../ts-build/$1
	cmake --build $$(CURDIR)/../ts-build/$1 -- -j$$(nproc)
	cmake --install $$(CURDIR)/../ts-build/$1

.PHONY: ffa-$1-sp-clean
ffa-$1-sp-clean:
	cmake --build $$(CURDIR)/../ts-build/$1 -- clean -j$$(nproc)

ffa-$1-sp-realclean:
	rm -rf $$(CURDIR)/../ts-build/$1

ffa-sp-realclean: ffa-$1-sp-realclean

optee-os-common: ffa-$1-sp
optee-os-clean: ffa-$1-sp-clean

endef

$(eval $(call build-sp,secure-storage))
$(eval $(call build-sp,crypto))

ffa-sp-realclean:
	rm -rf $(TS_INSTALL_PREFIX)/opteesp

# Add targets to build the "arm_ffa_user" Linux Kernel module.
arm_ffa_user: linux
	$(eval ROOT:=$(CURDIR)/..)
	make -C $(CURDIR)/../linux_poc $(LINUX_COMMON_FLAGS) install

arm_ffa_user_clean:
	make -C $(CURDIR)/../linux_poc clean

all: arm_ffa_user
