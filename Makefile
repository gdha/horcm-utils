# Makefile to build depots for horcm-utils
#
SHELL = /usr/bin/sh
product_horcmutils = horcm-utils
depot_horcmutils_dir = $(product_horcmutils).depot.dir
psf_horcmutils = ./horcm-utils.psf

all: help

help:
	@echo "======================="
	@echo "To build horcm-utils type:"
	@echo "    make horcm-utils"
	@echo "To clean all temporary depots of horcm-utils type:"
	@echo "	make clean"
	@echo "======================="

horcm-utils: $(psf_horcmutils) clean_horcmutils
	@if [ `whoami` != "root" ]; then echo "Only root may build packages"; exit 1; fi; \
	/usr/sbin/swpackage -vv -s $(psf_horcmutils) -x layout_version=1.0 -d /tmp/$(depot_horcmutils_dir) ; \
	/usr/sbin/swpackage -vv -d /tmp/$(product_horcmutils).depot -x target_type=tape -s /tmp/$(depot_horcmutils_dir) \* ; \
	echo "File depot location is /tmp/$(product_horcmutils).depot" ; \
	/usr/bin/chmod 644 /tmp/$(product_horcmutils).depot ; \
	echo "Done."

clean_horcmutils:
	@if [ `whoami` != "root" ]; then echo "Only root can run make clean"; exit 1; fi; \
	rm -rf /tmp/$(depot_horcmutils_dir) ; \
	rm -rf /tmp/$(product_horcmutils).depot ; \
	echo "Removed old versions of /tmp/$(depot_horcmutils_dir) and /tmp/$(product_horcmutils).depot"

clean: clean_horcmutils
