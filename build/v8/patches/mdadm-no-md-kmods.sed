# build/v7/patches/mdadm-no-md-kmods.sed: package/utils/mdadm/Makefile pulls kmod-md-mod/-raid0/-raid1/-raid10,
# and kmod-md-mod forces CONFIG_MD_AUTODETECT=y through its KCONFIG override. Our kernel has md + raid1 + raid456
# BUILT IN with autodetect OFF (kernel-config.fragment), so the package needs none of them.
s/^\(  DEPENDS:=+libpthread\) +kmod-md-mod +kmod-md-raid0 +kmod-md-raid10 +kmod-md-raid1$/\1/
