# SPDX-License-Identifier: GPL-2.0-only
#
# External-module entry point for kbuild.
#
# The top-level Makefile is the build driver, so this side is named Kbuild:
# `make -C <kernel> M=<repo> modules` includes this file. Add layer
# aggregators here as modules appear. A per-device build will select a subset
# instead of using this file.
#
# Kbuild descends into directories listed with a trailing slash.

obj-m += global/test_module/
