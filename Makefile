# SPDX-License-Identifier: GPL-2.0-only
#
# gki_world top-level build.
#
#   make            latest target checkout + defconfig + kernel + all modules
#   make kernel     same, module build omitted
#   make modules    gki_world modules only, against an existing kernel tree
#   make update     move to the current tip of the target branch and rebuild
#   make defconfig  configure the kernel tree only
#   make clean      remove module build artifacts
#   make distclean  also remove the kernel checkout
#
# The kernel checkout lives in .kernel/ and is never committed. External
# modules need a Module.symvers that matches the tree, so the first build is a
# full kernel build; later iterations use `make modules`.

KERNEL_REPO ?= https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
KERNEL_REF  ?= linux-6.18.y
KERNEL_DIR  ?= $(CURDIR)/.kernel/linux-6.18.y

ARCH          ?= arm64
CROSS_COMPILE ?= aarch64-linux-gnu-
JOBS          ?= $(shell nproc)

KBUILD = $(MAKE) -C $(KERNEL_DIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE)

.DEFAULT_GOAL := all

all: modules

$(KERNEL_DIR)/.git:
	@mkdir -p $(dir $(KERNEL_DIR))
	git clone --depth=1 --branch $(KERNEL_REF) $(KERNEL_REPO) $(KERNEL_DIR)

# -stable is append-only, so this is a fast-forward to the branch tip.
update: $(KERNEL_DIR)/.git
	git -C $(KERNEL_DIR) fetch --depth=1 origin $(KERNEL_REF)
	git -C $(KERNEL_DIR) checkout -q --detach FETCH_HEAD
	rm -f $(KERNEL_DIR)/Module.symvers
	$(KBUILD) olddefconfig
	@printf 'kernel: %s\n' "$$(git -C $(KERNEL_DIR) describe --always)"

$(KERNEL_DIR)/.config: $(KERNEL_DIR)/.git
	$(KBUILD) defconfig

defconfig: $(KERNEL_DIR)/.config

# A full build is the simplest way to get a Module.symvers consistent with the
# tree. In-tree modules are built as a side effect; that is acceptable here.
$(KERNEL_DIR)/Module.symvers: $(KERNEL_DIR)/.config
	$(KBUILD) -j$(JOBS)

kernel: $(KERNEL_DIR)/Module.symvers

modules: $(KERNEL_DIR)/Module.symvers
	$(KBUILD) M=$(CURDIR) modules

clean:
	@if [ -f $(KERNEL_DIR)/Makefile ]; then $(KBUILD) M=$(CURDIR) clean; fi
	@rm -f $(CURDIR)/Module.symvers $(CURDIR)/modules.order
	@find $(CURDIR) -path $(CURDIR)/.kernel -prune -o \
		\( -name '*.o' -o -name '*.ko' -o -name '*.mod' \
		-o -name '*.mod.c' -o -name '.*.cmd' \) -print | xargs -r rm -f

distclean:
	@rm -rf $(CURDIR)/.kernel
	@$(MAKE) --no-print-directory clean

.PHONY: all update defconfig kernel modules clean distclean
