#!/bin/sh
# ============================================================
# makedeb.sh - 不依赖 dpkg 的极简 deb 打包器（macOS/Linux 通用）
#
# 原理: deb = ar 归档，依次包含三个成员:
#   1. debian-binary   "2.0\n"
#   2. control.tar.gz  (control/conffiles/postinst/prerm/postrm/md5sums)
#   3. data.tar.xz     (文件系统树, root:root)
#
# 用法: makedeb.sh <pkgroot> <assets_dir> <out.deb> <version> <release> <arch> <maintainer>
# ============================================================
set -eu

PKGROOT=$1
ASSETS=$2
OUTDEB=$3
VERSION=$4
RELEASE=$5
ARCH=$6
MAINTAINER=$7

[ -d "$PKGROOT" ] || { echo "错误: pkgroot 不存在: $PKGROOT" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/makedeb.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------- 工具兼容层 ----------
md5_of() { # md5_of <file> -> 输出 32 位哈希
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | cut -d' ' -f1
  else
    md5 -q "$1"
  fi
}

# ---------- 1. 生成 DEBIAN/control ----------
INSTALLED_SIZE_KB=$(du -sk "$PKGROOT" | cut -f1)

# 模板变量替换
CONTROL_SRC="$ASSETS/control.in"
if [ ! -f "$CONTROL_SRC" ]; then
  echo "错误: 缺少 $CONTROL_SRC" >&2
  exit 1
fi
sed -e "s|@VERSION@|$VERSION-$RELEASE|g" \
    -e "s|@ARCH@|$ARCH|g" \
    -e "s|@SIZE@|$INSTALLED_SIZE_KB|g" \
    -e "s|@MAINTAINER@|$MAINTAINER|g" \
    "$CONTROL_SRC" > "$WORK/control"

DEBIAN_DIR="$PKGROOT/DEBIAN"
rm -rf "$DEBIAN_DIR"
mkdir -p "$DEBIAN_DIR"
cp "$WORK/control" "$DEBIAN_DIR/control"

# conffiles / 维护脚本
cp "$ASSETS/conffiles" "$DEBIAN_DIR/conffiles"
for f in postinst prerm postrm; do
  sed -e "s|@VERSION@|$VERSION-$RELEASE|g" "$ASSETS/$f" > "$DEBIAN_DIR/$f"
  chmod 0755 "$DEBIAN_DIR/$f"
done

# ---------- 2. md5sums ----------
( cd "$PKGROOT"
  find . -type f ! -path './DEBIAN/*' | LC_ALL=C sort | while IFS= read -r f; do
    f=${f#./}
    printf '%s  %s\n' "$(md5_of "$f")" "$f"
  done
) > "$DEBIAN_DIR/md5sums"

# ---------- 3. 打 data.tar.xz 与 control.tar.gz ----------
# 注意: 必须用 Python tarfile(GNU_FORMAT) 而非 bsdtar——
#   macOS bsdtar 即使 --format gnutar，遇长路径/特殊元数据仍会插入 PAX
#   扩展头(type 'x')，而 dpkg 只认纯 ustar/gnu 头，安装时报
#   "corrupted filesystem tarfile ... unsupported PAX tar header type 'x'"
#   Python GNU_FORMAT 保证纯 GNU 头，且 uid/gid/uname/gname/mtime 完全可控
#   （root:root + mtime 归一，顺带满足可复现构建）。
python3 - "$PKGROOT" "$WORK" <<'PYEOF'
import os, sys, tarfile

pkgroot, work = sys.argv[1], sys.argv[2]

def build(out_path, src_dir, exclude_debian=False):
    mode = 'w:xz' if out_path.endswith('.xz') else 'w:gz'
    with tarfile.open(out_path, mode, format=tarfile.GNU_FORMAT) as tf:
        entries = []
        for root, dirs, files in os.walk(src_dir):
            dirs.sort()
            for name in sorted(dirs) + sorted(files):
                entries.append(os.path.join(root, name))
        for full in entries:
            rel = './' + os.path.relpath(full, src_dir)
            if exclude_debian and rel.startswith('./DEBIAN'):
                continue
            ti = tf.gettarinfo(full, arcname=rel)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = 0
            if ti.isfile():
                with open(full, 'rb') as f:
                    tf.addfile(ti, f)
            else:
                tf.addfile(ti)

build(os.path.join(work, 'data.tar.xz'), pkgroot, exclude_debian=True)
build(os.path.join(work, 'control.tar.gz'), os.path.join(pkgroot, 'DEBIAN'))
print('tar 归档完成(GNU_FORMAT, root:root, mtime=0)')
PYEOF

# ---------- 4. 组装 ar 归档 ----------
printf '2.0\n' > "$WORK/debian-binary"
# 成员顺序必须为 debian-binary, control.tar.*, data.tar.*
# -S: 不写 ar 符号表（dpkg 要求）
rm -f "$OUTDEB"
ar rcS "$OUTDEB" "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.xz"

# ---------- 5. 校验 ----------
if command -v dpkg-deb >/dev/null 2>&1; then
  echo "--- dpkg-deb 校验 ---"
  dpkg-deb --info "$OUTDEB" | head -20
  dpkg-deb --contents "$OUTDEB" | head -5
  echo "..."
else
  echo "(本机无 dpkg-deb，跳过校验；deb 可在目标机上用 dpkg -c 查看)"
fi

echo "打包完成: $OUTDEB ($(du -h "$OUTDEB" | cut -f1), Installed-Size: ${INSTALLED_SIZE_KB}KB)"
