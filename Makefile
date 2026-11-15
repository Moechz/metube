# Makefile - 便捷入口（实际逻辑都在 build.sh）
.PHONY: all fetch ui deps stage deb clean distclean info check

all: package

package:
	./build.sh

fetch:
	./build.sh fetch

ui:
	./build.sh ui

deps:
	./build.sh deps

stage:
	./build.sh stage

deb:
	./build.sh deb

clean:
	./build.sh clean

distclean:
	./build.sh distclean

info:
	./build.sh info

# 语法检查
check:
	sh -n makedeb.sh
	sh -n assets/postinst
	sh -n assets/prerm
	sh -n assets/postrm
	sed -e 's|@METUBE_VERSION@|x|g' assets/metube.sh.in | sh -n
	sed -e 's|@METUBE_VERSION@|x|g' assets/metube-update-ytdlp.in | sh -n
	bash -n build.sh
	@echo "语法检查通过"
