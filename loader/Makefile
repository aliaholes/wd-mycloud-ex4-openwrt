# SPDX-License-Identifier: GPL-2.0-or-later
# out-of-tree build against the PREPARED WD GPL tree (linux-3.2.40 + WD's own .config, modules_prepare done):
#   make -C <tree> M=$PWD ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- KCFLAGS=-DALPHA_CUSTOMIZE modules
obj-m := ex4boot.o
ex4boot-objs := ex4boot_main.o ex4boot_stub.o
# v2 (Nov 16 2026): EX4_L2OFF=1 builds the stub that also turns the Feroceon L2 cache off before the jump
# (see ex4boot_stub.S). Without it the build is v1's, byte for byte. The C file is the same in both.
ifeq ($(EX4_L2OFF),1)
AFLAGS_ex4boot_stub.o := -DEX4_L2OFF
endif
