#!/usr/bin/env bash
# ============================================================
# build.sh - 在 macOS / Linux 上把 MeTube 打包成适用于
# TOS（Debian 系 NAS 系统，如 TerraMaster TOS 5/6）的 deb 包
#
# 用法:
#   ./build.sh            # 完整构建，产出 out/metube_<ver>_<arch>.deb
#   ./build.sh <stage>    # 只跑某个阶段: fetch ui deps python-src bgutil-src quickjs-src stage deb
#   ./build.sh info       # 查看当前配置
#
# 构建模式（环境变量 BUILD_MODE）:
#   source  发布模式（CI/Linux）：CPython 从 python.org 官方源码编译、
#           bgutil-pot 从 Rust 源码编译、Python 依赖从 sdist 构建——包内
#           所有 ELF 均出自本仓库公开工作流（应用市场 V6 审核要求）
#   compat  开发模式（默认，macOS 可用）：预编译回退（python-build-
#           standalone、上游 bgutil release、manylinux wheels），仅供本地
#           sideload 测试，BUILD-INFO 会标注，不得用于商店提交
#
# 阶段说明:
#   fetch       下载外部资源到 build/downloads（有缓存，可重复执行）
#   ui          用 Node 22 + pnpm 构建 Angular 前端
#   deps        安装 Python 依赖到 build/vendor（source: sdist / compat: wheels）
#   python-src  [仅Linux] 从 python.org 源码构建 CPython（source 模式用）
#   bgutil-src  [仅Linux] 从 Rust 源码构建 bgutil-pot（source 模式用）
#   quickjs-src [仅Linux] 从 quickjs-ng 源码构建 qjs（source 模式用；yt-dlp JS 运行时）
#   stage       组装 deb 文件系统树 build/pkgroot
#   deb         生成最终 .deb（无 dpkg 环境，ar+tar 手工打包）
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

BUILD_DIR="$SCRIPT_DIR/build"
DL_DIR="$BUILD_DIR/downloads"
TOOLS_DIR="$BUILD_DIR/tools"
SRC_DIR="$BUILD_DIR/metube-$METUBE_VERSION"
VENDOR_DIR="$BUILD_DIR/vendor"
STAGE_DIR="$BUILD_DIR/pkgroot"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"

# ---------------- 目标平台（TOS / NAS 侧） ----------------
case "$TARGET_ARCH" in
  amd64)
    UV_PY_PLATFORM="x86_64-unknown-linux-gnu"
    PBS_TRIPLE="x86_64-unknown-linux-gnu"
    BGUTIL_ARCH="x86_64"
    TOS_PLATFORM="x86_64"
    ;;
  arm64)
    UV_PY_PLATFORM="aarch64-unknown-linux-gnu"
    PBS_TRIPLE="aarch64-unknown-linux-gnu"
    BGUTIL_ARCH="aarch64"
    TOS_PLATFORM="aarch64"
    ;;
  *)
    echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2
    exit 1
    ;;
esac

# ---------------- 构建机平台（本机侧） ----------------
BUILD_OS=$(uname -s)
BUILD_MACHINE=$(uname -m)
case "$BUILD_OS-$BUILD_MACHINE" in
  Darwin-arm64)  NODE_HOST_PLAT="darwin-arm64";   UV_HOST_ASSET="uv-aarch64-apple-darwin.tar.gz" ;;
  Darwin-x86_64) NODE_HOST_PLAT="darwin-x64";     UV_HOST_ASSET="uv-x86_64-apple-darwin.tar.gz" ;;
  Darwin-arm)    NODE_HOST_PLAT="darwin-arm64";   UV_HOST_ASSET="uv-aarch64-apple-darwin.tar.gz" ;;
  Linux-x86_64)  NODE_HOST_PLAT="linux-x64";      UV_HOST_ASSET="uv-x86_64-unknown-linux-gnu.tar.gz" ;;
  Linux-aarch64) NODE_HOST_PLAT="linux-arm64";    UV_HOST_ASSET="uv-aarch64-unknown-linux-gnu.tar.gz" ;;
  *)
    echo "错误: 不支持的构建平台 $BUILD_OS-$BUILD_MACHINE" >&2
    exit 1
    ;;
esac

NODE_TARBALL="node-v$NODE_VERSION-$NODE_HOST_PLAT.tar.gz"
NODE_DIR="$TOOLS_DIR/node-v$NODE_VERSION-$NODE_HOST_PLAT"
UV_DIR="$TOOLS_DIR/uv"
PY_RUNTIME_TARBALL="cpython-$PBS_PYTHON+$PBS_TAG-$PBS_TRIPLE-install_only_stripped.tar.gz"
BGUTIL_BIN="bgutil-pot-linux-$BGUTIL_ARCH"
BGUTIL_ZIP="bgutil-ytdlp-pot-provider-rs.zip"
QJS_BIN="qjs-linux-$BGUTIL_ARCH"
QJS_SRC_TGZ="quickjs-ng-$QUICKJS_VERSION.tar.gz"

# 构建模式（见文件头）；source 仅限 Linux（CI runner）
BUILD_MODE="${BUILD_MODE:-compat}"
if [ "$BUILD_MODE" = "source" ] && [ "$(uname -s)" != "Linux" ]; then
  die "BUILD_MODE=source 仅支持 Linux（CI ubuntu runner）；本地开发用默认 compat"
fi
# 源码构建产物目录（python-src / bgutil-src 阶段产出，stage 优先取用）
SRC_PY_ROOT="$DL_DIR/cpython-src/$PBS_PYTHON-$TARGET_ARCH"
SRC_BGUTIL_ROOT="$DL_DIR/bgutil-src/$BGUTIL_VERSION-$TARGET_ARCH"
SRC_QJS_ROOT="$DL_DIR/quickjs-src/$QUICKJS_VERSION-$TARGET_ARCH"
DEB_FILE="$OUT_DIR/metube_${METUBE_VERSION}-${PKG_RELEASE}_${TARGET_ARCH}.deb"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest-file>（多次重试 + 断点续传）
  local url=$1 dest=$2 attempt=0
  if [ -s "$dest" ]; then
    log "已缓存: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "下载: $(basename "$dest")"
  while [ $attempt -lt 8 ]; do
    attempt=$((attempt + 1))
    if curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
         --connect-timeout 30 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return 0
    fi
    rm -f "$dest.part"  # 部分服务器不支持续传时从头再来
    warn "下载失败(第 $attempt 次): $(basename "$dest")，10 秒后重试..."
    sleep 10
  done
  die "下载失败: $url"
}

# ============================================================
# 阶段: fetch
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR" "$TOOLS_DIR"

  # 1. MeTube 源码
  fetch "https://codeload.github.com/alexta69/metube/tar.gz/refs/tags/$METUBE_VERSION" \
        "$DL_DIR/metube-$METUBE_VERSION.tar.gz"

  # 2. Node（构建前端用，宿主平台）
  fetch "https://nodejs.org/dist/v$NODE_VERSION/$NODE_TARBALL" "$DL_DIR/$NODE_TARBALL"

  # 3. uv（解析/安装 Python 依赖用，宿主平台；latest 通道）
  fetch "https://github.com/astral-sh/uv/releases/latest/download/$UV_HOST_ASSET" \
        "$DL_DIR/$UV_HOST_ASSET"

  # 4. 独立 CPython 3.13（compat 回退用；source 模式由 python-src 从官方源码构建）
  if [ ! -x "$SRC_PY_ROOT/python/bin/python3" ]; then
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/$PY_RUNTIME_TARBALL" \
          "$DL_DIR/$PY_RUNTIME_TARBALL"
  fi

  # 5. bgutil PO Token provider（compat 回退用；source 模式由 bgutil-src 从源码构建）
  fetch "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/$BGUTIL_VERSION/$BGUTIL_BIN" \
        "$DL_DIR/$BGUTIL_BIN"
  fetch "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/$BGUTIL_VERSION/$BGUTIL_ZIP" \
        "$DL_DIR/$BGUTIL_ZIP"

  # 6. quickjs-ng（yt-dlp JS challenge 解密运行时；compat 回退用官方 qjs 二进制，
  #    source 模式由 quickjs-src 从源码构建）
  fetch "https://github.com/quickjs-ng/quickjs/releases/download/$QUICKJS_VERSION/$QJS_BIN" \
        "$DL_DIR/$QJS_BIN"
  fetch "https://codeload.github.com/quickjs-ng/quickjs/tar.gz/refs/tags/$QUICKJS_VERSION" \
        "$DL_DIR/$QJS_SRC_TGZ"

  # 7. 解压构建工具
  if [ ! -x "$NODE_DIR/bin/node" ]; then
    log "解压 Node..."
    tar xzf "$DL_DIR/$NODE_TARBALL" -C "$TOOLS_DIR"
  fi
  if [ ! -x "$UV_DIR/uv" ]; then
    log "解压 uv..."
    rm -rf "$UV_DIR.tmp"
    mkdir -p "$UV_DIR.tmp"
    tar xzf "$DL_DIR/$UV_HOST_ASSET" -C "$UV_DIR.tmp"
    UV_BIN_FOUND=$(find "$UV_DIR.tmp" -type f -name uv | head -1)
    mkdir -p "$UV_DIR"
    mv "$UV_BIN_FOUND" "$UV_DIR/uv"
    rm -rf "$UV_DIR.tmp"
  fi

  # 8. 解压 MeTube 源码
  if [ ! -d "$SRC_DIR" ]; then
    log "解压 MeTube 源码..."
    tar xzf "$DL_DIR/metube-$METUBE_VERSION.tar.gz" -C "$BUILD_DIR"
  fi
}

# ============================================================
# 阶段: python-src —— 从 python.org 官方源码构建 CPython（仅 Linux）
# 产物: build/downloads/cpython-src/<ver>-<arch>/python/（stage 优先取用）
# ============================================================
stage_python_src() {
  [ "$(uname -s)" = "Linux" ] || die "python-src 仅支持 Linux"
  if [ -f "$SRC_PY_ROOT/.built" ] && [ -x "$SRC_PY_ROOT/python/bin/python3" ]; then
    log "CPython 源码构建已缓存: $SRC_PY_ROOT"
    return 0
  fi
  [ -n "${CPYTHON_SRC_SHA256:-}" ] || die "config.env 缺少 CPYTHON_SRC_SHA256（官方源码包哈希）"

  local tgz="Python-$PBS_PYTHON.tgz" bdir="$SRC_PY_ROOT/build"
  fetch "https://www.python.org/ftp/python/$PBS_PYTHON/$tgz" "$DL_DIR/$tgz"
  log "校验 CPython 源码哈希（config.env 固化值）..."
  echo "$CPYTHON_SRC_SHA256  $DL_DIR/$tgz" | sha256sum -c - \
    || die "CPython 源码哈希不匹配（供应链异常？）"

  rm -rf "$bdir" "$SRC_PY_ROOT/python"
  mkdir -p "$bdir"
  tar xzf "$DL_DIR/$tgz" -C "$bdir" --strip-components=1
  log "configure + make CPython $PBS_PYTHON（约 15-25 分钟）..."
  ( cd "$bdir"
    ./configure --prefix="$SRC_PY_ROOT/python" \
                --disable-test-modules --with-ensurepip=no
    make -j"$(nproc)"
    make install
  )
  find "$SRC_PY_ROOT/python" -type f \( -name "python3*" -o -name "*.so" \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true
  rm -rf "$SRC_PY_ROOT/python/lib/python3.13/test" \
         "$SRC_PY_ROOT/python/lib/python3.13/idlelib" \
         "$SRC_PY_ROOT/python/lib/python3.13/tkinter" \
         "$SRC_PY_ROOT/python/lib/python3.13/turtledemo"
  "$SRC_PY_ROOT/python/bin/python3" -c \
    "import sys,sqlite3,ssl,ctypes,bz2,lzma,zlib; print('CPython 自检通过:', sys.version.split()[0])" \
    || die "CPython 源码构建自检失败"
  touch "$SRC_PY_ROOT/.built"
  log "CPython 源码构建完成: $SRC_PY_ROOT/python"
}

# ============================================================
# 阶段: bgutil-src —— 从 Rust 源码构建 bgutil-pot（仅 Linux）
# 产物: build/downloads/bgutil-src/<ver>-<arch>/bgutil-pot（stage 优先取用）
# ============================================================
stage_bgutil_src() {
  [ "$(uname -s)" = "Linux" ] || die "bgutil-src 仅支持 Linux"
  command -v cargo >/dev/null 2>&1 || die "需要 Rust 工具链（cargo）"
  if [ -f "$SRC_BGUTIL_ROOT/.built" ] && [ -x "$SRC_BGUTIL_ROOT/bgutil-pot" ]; then
    log "bgutil-pot 源码构建已缓存: $SRC_BGUTIL_ROOT"
    return 0
  fi
  rm -rf "$SRC_BGUTIL_ROOT"
  mkdir -p "$SRC_BGUTIL_ROOT"
  git clone --depth 1 --branch "$BGUTIL_VERSION" \
    https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs "$SRC_BGUTIL_ROOT/src"
  # 链接器（runs 15-20 对照实验实证）：22.04 默认 gcc-11（以及 clang-14/lld-14）
  # 链接 v8 130 静态库产出的二进制运行即 SIGSEGV；gcc-12 链接正常（SMOKE OK）。
  # 用 gcc-12 专用链接，glibc 2.35 floor 仍由 22.04 容器环境保证。
  command -v gcc-12 >/dev/null 2>&1 || die "需要 gcc-12（apt install gcc-12）供 bgutil-pot 链接"
  case "$TARGET_ARCH" in
    amd64) export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="gcc-12" ;;
    arm64) export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="gcc-12" ;;
    *) die "未知架构: $TARGET_ARCH" ;;
  esac
  export CC=gcc-12
  ( cd "$SRC_BGUTIL_ROOT/src" && cargo build --release --locked --features ffi )
  local bin
  bin=$(find "$SRC_BGUTIL_ROOT/src/target/release" -maxdepth 1 -type f -executable -name "bgutil-pot*" | head -1)
  [ -n "$bin" ] || die "未找到构建出的 bgutil-pot 二进制"
  # 注意：不做 strip —— 内嵌 V8 的二进制被 strip 后会 SIGSEGV（-012 真机实锤）
  cp "$bin" "$SRC_BGUTIL_ROOT/bgutil-pot"
  chmod 0755 "$SRC_BGUTIL_ROOT/bgutil-pot"
  # glibc 符号 ceiling 断言：glibc-versioned target 兑现的契约必须验证
  local bad_sym
  bad_sym=$(objdump -T "$SRC_BGUTIL_ROOT/bgutil-pot" 2>/dev/null \
              | grep -oE 'GLIBC_[0-9.]+' | sed 's/GLIBC_//' | sort -uV \
              | awk -F. '($1>2) || ($1==2 && $2>35)')
  [ -z "$bad_sym" ] || die "bgutil-pot glibc 符号超限（需≤2.35）: $bad_sym"
  # 冒烟测试：坏二进制不许进缓存，构型/工具链问题构建期就暴露
  "$SRC_BGUTIL_ROOT/bgutil-pot" --version >/dev/null 2>&1 \
    || die "bgutil-pot 构建后冒烟测试失败（--version 异常）"
  git -C "$SRC_BGUTIL_ROOT/src" rev-parse HEAD > "$SRC_BGUTIL_ROOT/.commit"
  rustc --version > "$SRC_BGUTIL_ROOT/.rustc" 2>/dev/null || true
  rm -rf "$SRC_BGUTIL_ROOT/src"
  log "bgutil-pot 源码构建完成: $SRC_BGUTIL_ROOT/bgutil-pot ($(cut -c1-12 "$SRC_BGUTIL_ROOT/.commit"))"
}

# ============================================================
# 阶段: quickjs-src —— 从 quickjs-ng 源码编译 qjs（仅 Linux）
# 产物: build/downloads/quickjs-src/<ver>-<arch>/qjs（stage 优先取用）
# yt-dlp web client 解 n/sig 挑战的 JS 运行时；C 单文件项目，构建轻
# ============================================================
stage_quickjs_src() {
  [ "$(uname -s)" = "Linux" ] || die "quickjs-src 仅支持 Linux"
  command -v cmake >/dev/null 2>&1 || die "需要 cmake（apt install cmake）"
  if [ -f "$SRC_QJS_ROOT/.built" ] && [ -x "$SRC_QJS_ROOT/qjs" ]; then
    log "qjs 源码构建已缓存: $SRC_QJS_ROOT"
    return 0
  fi
  [ -n "${QUICKJS_SRC_SHA256:-}" ] || die "config.env 缺少 QUICKJS_SRC_SHA256（官方源码包哈希）"

  fetch "https://codeload.github.com/quickjs-ng/quickjs/tar.gz/refs/tags/$QUICKJS_VERSION" \
        "$DL_DIR/$QJS_SRC_TGZ"
  log "校验 quickjs-ng 源码哈希（config.env 固化值）..."
  echo "$QUICKJS_SRC_SHA256  $DL_DIR/$QJS_SRC_TGZ" | sha256sum -c - \
    || die "quickjs-ng 源码哈希不匹配（供应链异常？）"

  rm -rf "$SRC_QJS_ROOT"
  mkdir -p "$SRC_QJS_ROOT/src"
  tar xzf "$DL_DIR/$QJS_SRC_TGZ" -C "$SRC_QJS_ROOT/src" --strip-components=1
  # quickjs-ng v0.17 起用 CMake 构建（make 只是包装；无 qjs 目标）；
  # 产物固定为源码树下的 build/qjs
  log "cmake 构建 quickjs-ng qjs（约 1-2 分钟）..."
  ( cd "$SRC_QJS_ROOT/src" \
      && cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null \
      && cmake --build build --target qjs_exe -j"$(nproc)" )
  [ -x "$SRC_QJS_ROOT/src/build/qjs" ] || die "未找到编译出的 qjs（$SRC_QJS_ROOT/src/build/qjs）"
  cp "$SRC_QJS_ROOT/src/build/qjs" "$SRC_QJS_ROOT/qjs"
  chmod 0755 "$SRC_QJS_ROOT/qjs"
  # 冒烟：qjs 能执行 JS；坏产物不许进缓存（靠退出码，不依赖 console 行为）
  "$SRC_QJS_ROOT/qjs" -e 'if (1+1 !== 2) throw new Error("smoke")' \
    || die "qjs 构建后冒烟测试失败"
  rm -rf "$SRC_QJS_ROOT/src"
  touch "$SRC_QJS_ROOT/.built"
  log "qjs 源码构建完成: $SRC_QJS_ROOT/qjs"
}

# ============================================================
# 阶段: ui —— 构建 Angular 前端
# ============================================================
stage_ui() {
  [ -d "$SRC_DIR" ] || stage_fetch
  if [ -f "$SRC_DIR/ui/dist/metube/browser/index.html" ]; then
    log "前端已构建，跳过（如需重建请先 rm -rf build/metube-$METUBE_VERSION/ui/dist）"
    return 0
  fi

  # 下游 UI 微调（幂等，python3 跨 macOS/Linux；fetch 重新解出源码后自动重应用）：
  #   1) Download Folder 空值时不显示 "Default" 占位文字（本包语义：无默认下载目录，
  #      显示 Default 会误导）；其余字段的 Default 占位保留
  #   2) add 错误 toast 去掉 "Error adding URL: " 前缀，服务端提示语原样弹出
  #      （闸门提示语需精确展示；msg 缺失时回退英文泛化提示）
  #   3) Download Folder 帮助气泡：说明相对路径=子目录、绝对路径=下载目录本身
  #      （会被记住；需先在 NAS 共享权限里授予 metube 写权限）
  #   4) 导航栏 GitHub 图标链接指向本发行版仓库（不留上游个人信息）
  #   5) 页脚 GitHub 链接旁加 "Privacy Policy" 入口（相对链接 privacy-policy.html：
  #      直连 :8081 根路径与 App Center iframe /metube/ 前缀两种场景均正确解析；
  #      否则应用内可达但不可发现，市场复查 C8 有风险）
  python3 - "$SRC_DIR/ui/src/app/app.html" "$SRC_DIR/ui/src/app/app.ts" <<'PYEOF'
import re, sys
html_p, ts_p = sys.argv[1], sys.argv[2]

html = open(html_p).read()
html2 = re.sub(r'placeholder="Default"(\s+name="folder")', r'placeholder=""\1', html, count=1)
# Download Folder 帮助气泡：相对路径=基目录下的子目录；绝对路径=直接作为下载目录
# （校验通过后被记住，刷新页面自动回填；写入前提是 NAS 共享权限已授予 metube 用户）
POPOVER_FINAL = ('ngbPopover="A subfolder of the download directory, or an absolute path to a folder '
                 'the app can write (grant access in your NAS sharing settings first). '
                 'Absolute paths are remembered."')
html2 = html2.replace(
    'ngbPopover="Type to filter existing folders, or enter a new folder name."',
    POPOVER_FINAL)
# 导航栏 GitHub 图标 → 指向本发行版仓库（幂等：已改过则无变化）
html2 = html2.replace('href="https://github.com/alexta69/metube"',
                      'href="https://github.com/Moechz/metube"')
# 5) 页脚隐私政策入口（幂等：已插入则跳过）
if 'privacy-policy.html' not in html2:
    html2 = re.sub(
        r'(<a href="https://github\.com/Moechz/metube"[^>]*>\s*<fa-icon \[icon\]="faGithub"\s*/>\s*<span>GitHub</span>\s*</a>)',
        r'\1\n'
        '        <div class="version-separator"></div>\n'
        '        <a href="privacy-policy.html" target="_blank" rel="noopener" class="github-link">\n'
        '          <span>Privacy Policy</span>\n'
        '        </a>',
        html2, count=1)
html2 = html2.replace(
    'ngbPopover="A subfolder within the server-configured download directory. '
    'To set the directory itself, edit DOWNLOAD_DIR in /etc/metube/metube.env '
    'and run metube-apply-config."',
    POPOVER_FINAL)  # 兼容上一版文案
if html2 != html:
    open(html_p, 'w').write(html2)

ts = open(ts_p).read()
final = "this.toasts.error(status.msg || 'Error adding URL');"
ts = ts.replace("this.toasts.error(`Error adding URL: ${status.msg}`);", final)
ts = ts.replace("this.toasts.error(status.msg);", final)  # 兼容中间态
open(ts_p, 'w').write(ts)
PYEOF

  command -v xz >/dev/null 2>&1 || true
  log "准备 Node $NODE_VERSION + corepack(pnpm)..."
  export PATH="$NODE_DIR/bin:$PATH"
  node --version

  # corepack 随 Node 发行，按 ui/package.json 的 packageManager 字段安装 pnpm
  corepack enable --install-directory "$NODE_DIR/bin" 2>/dev/null || true
  command -v pnpm >/dev/null 2>&1 || die "pnpm 不可用（corepack enable 失败）"

  log "安装前端依赖 (pnpm install)..."
  ( cd "$SRC_DIR/ui"
    # 国内网络可提前 export NPM_CONFIG_REGISTRY=https://registry.npmmirror.com
    CI=true pnpm install --frozen-lockfile
    log "构建前端 (ng build)..."
    CI=true pnpm run build
  )

  [ -f "$SRC_DIR/ui/dist/metube/browser/index.html" ] \
    || die "前端构建产物缺失: ui/dist/metube/browser/index.html"
  log "前端构建完成"
}

# ============================================================
# 阶段: deps —— 交叉安装 Python 依赖（按 uv.lock 锁定）
# ============================================================
stage_deps() {
  [ -f "$SRC_DIR/pyproject.toml" ] || stage_fetch
  if [ -d "$VENDOR_DIR" ] && [ -d "$VENDOR_DIR/yt_dlp" ]; then
    log "Python 依赖已安装，跳过（如需重装请 rm -rf build/vendor）"
    return 0
  fi
  local uv="$UV_DIR/uv"
  [ -x "$uv" ] || stage_fetch

  log "从 uv.lock 导出锁定版本依赖（剔除 deno——运行时不使用，见 BUILD-INFO）..."
  ( cd "$SRC_DIR"
    "$uv" export --frozen --no-dev --no-hashes --no-emit-project \
      --format requirements-txt -o "$BUILD_DIR/requirements.txt"
  )
  grep -v '^deno==' "$BUILD_DIR/requirements.txt" > "$BUILD_DIR/requirements.nodeps"
  mv "$BUILD_DIR/requirements.nodeps" "$BUILD_DIR/requirements.txt"

  rm -rf "$VENDOR_DIR"
  if [ "$BUILD_MODE" = "source" ]; then
    # source 模式：用本仓库 CI 从官方源码构建的 CPython，逐包从 sdist 编译
    # （所有 ELF 出自本工作流——V6 要求；uv 构建隔离仅拉取构建工具，不入包）
    local pybin="$SRC_PY_ROOT/python/bin/python3"
    [ -x "$pybin" ] || die "source 模式需先运行: ./build.sh python-src"
    log "从 sdist 构建 Python 依赖到 build/vendor（curl-cffi 较慢，约 10-25 分钟）..."
    "$uv" pip install \
      -r "$BUILD_DIR/requirements.txt" \
      --python "$pybin" \
      --no-binary=:all: \
      --no-compile \
      --target "$VENDOR_DIR"
  else
    # compat 模式：manylinux wheels 交叉安装（开发用）
    log "交叉安装 Python 依赖到 build/vendor（目标: $UV_PY_PLATFORM / py3.13）..."
    # 国内网络可 export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
    "$uv" pip install \
      -r "$BUILD_DIR/requirements.txt" \
      --python-version 3.13 \
      --python-platform "$UV_PY_PLATFORM" \
      --no-compile \
      --target "$VENDOR_DIR"
  fi
  echo "$BUILD_MODE" > "$VENDOR_DIR/.build-mode"

  [ -d "$VENDOR_DIR/yt_dlp" ] || die "yt-dlp 未安装到 vendor，构建异常"
  [ ! -e "$VENDOR_DIR/bin/deno" ] || die "vendor 内不应出现 deno（依赖导出过滤失败？）"
  log "Python 依赖安装完成（$(ls "$VENDOR_DIR" | wc -l | tr -d ' ') 个包）"
}

# ============================================================
# 阶段: stage —— 组装 deb 文件系统树
# ============================================================
stage_stage() {
  [ -f "$SRC_DIR/ui/dist/metube/browser/index.html" ] || die "前端未构建，请先运行: ./build.sh ui"
  [ -d "$VENDOR_DIR/yt_dlp" ] || die "Python 依赖未安装，请先运行: ./build.sh deps"

  log "组装文件系统树: $STAGE_DIR"
  # 捆绑运行时解出的目录可能带只读权限，先放权再删，避免 rm 失败中断
  chmod -R u+rwx "$STAGE_DIR" >/dev/null 2>&1 || true
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR/opt/metube/bin"
  mkdir -p "$STAGE_DIR/opt/metube/ui/dist"
  mkdir -p "$STAGE_DIR/usr/bin"
  mkdir -p "$STAGE_DIR/usr/local/metubedownload/images/icons"
  mkdir -p "$STAGE_DIR/usr/local/metubedownload/init.d"
  mkdir -p "$STAGE_DIR/etc/metube"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  mkdir -p "$STAGE_DIR/var/lib/metube/state"
  mkdir -p "$STAGE_DIR/usr/share/doc/metube"

  local M="$STAGE_DIR/opt/metube"

  # 后端代码：从上游原始 tarball 解出（保证补丁始终基于纯净源，杜绝工作树脏改
  # 导致的双重应用）；去掉测试
  log "  + app/（后端，上游原始源）"
  tar xzf "$DL_DIR/metube-$METUBE_VERSION.tar.gz" -C "$M" \
    --strip-components=1 "metube-$METUBE_VERSION/app"
  rm -rf "$M/app/tests"

  # 下游补丁（assets/patches/*.patch 按文件名序应用；上游升级后需检查补丁适配）
  if ls assets/patches/*.patch >/dev/null 2>&1; then
    log "  + app/ 下游补丁"
    local p
    for p in assets/patches/*.patch; do
      patch -d "$M" -p1 < "$p" || die "补丁应用失败: $p（上游源码变动？请基于新源码重新生成补丁）"
    done
  fi

  # 前端产物（main.py 从 {BASE_DIR}/ui/dist/metube/browser 提供静态文件）
  log "  + ui/dist/metube（前端）"
  cp -R "$SRC_DIR/ui/dist/metube" "$M/ui/dist/metube"

  # Python 依赖
  log "  + vendor/（Python 依赖）"
  cp -R "$VENDOR_DIR" "$M/vendor"

  # Python 3.13 运行时：优先源码构建产物（V6）；compat 回退 python-build-standalone
  local PYTHON_ORIGIN="srcbuild"
  if [ -x "$SRC_PY_ROOT/python/bin/python3" ]; then
    log "  + python/（源码构建: python.org 官方源码 ← 本仓库 CI 编译）"
    cp -R "$SRC_PY_ROOT/python" "$M/python"
  elif [ "$BUILD_MODE" = "source" ]; then
    die "source 模式缺源码构建的 CPython（先运行: ./build.sh python-src）"
  else
    warn "compat 模式: 使用 python-build-standalone 预编译运行时（仅供开发测试）"
    PYTHON_ORIGIN="python-build-standalone"
    tar xzf "$DL_DIR/$PY_RUNTIME_TARBALL" -C "$STAGE_DIR/opt/metube"
  fi

  # PO Token provider：优先 Rust 源码构建产物；compat 回退上游 release 二进制。
  # Deno 已移除（-011）：应用与 Rust 版 bgutil 服务均不使用（上游 TS 时代遗产， 2×91MB）
  local BGUTIL_ORIGIN="srcbuild"
  if [ -x "$SRC_BGUTIL_ROOT/bgutil-pot" ]; then
    log "  + bin/bgutil-pot（源码构建: GitHub 源码 ← 本仓库 CI cargo 编译）"
    cp "$SRC_BGUTIL_ROOT/bgutil-pot" "$M/bin/bgutil-pot"
  elif [ "$BUILD_MODE" = "source" ]; then
    die "source 模式缺源码构建的 bgutil-pot（先运行: ./build.sh bgutil-src）"
  else
    warn "compat 模式: 使用上游 bgutil 预编译二进制（仅供开发测试）"
    BGUTIL_ORIGIN="upstream-release"
    cp "$DL_DIR/$BGUTIL_BIN" "$M/bin/bgutil-pot"
  fi
  chmod 0755 "$M/bin/bgutil-pot"

  # quickjs-ng qjs：yt-dlp JS challenge 解密运行时。优先源码构建产物；compat 回退上游 release。
  # （-016：早期 deno 被误删导致 web client 无 JS runtime；qjs 源码轻、无 V8）
  local QJS_ORIGIN="srcbuild"
  if [ -x "$SRC_QJS_ROOT/qjs" ]; then
    log "  + bin/qjs（源码构建: quickjs-ng 官方源码 ← 本仓库 CI make）"
    cp "$SRC_QJS_ROOT/qjs" "$M/bin/qjs"
  elif [ "$BUILD_MODE" = "source" ]; then
    die "source 模式缺源码构建的 qjs（先运行: ./build.sh quickjs-src）"
  else
    warn "compat 模式: 使用上游 quickjs-ng 预编译 qjs（仅供开发测试）"
    QJS_ORIGIN="upstream-release"
    cp "$DL_DIR/$QJS_BIN" "$M/bin/qjs"
  fi
  chmod 0755 "$M/bin/qjs"

  log "  + vendor/ 内置 bgutil yt-dlp 插件"
  unzip -oq "$DL_DIR/$BGUTIL_ZIP" -d "$M/vendor"

  # 包装脚本 /usr/bin/metube
  sed -e "s|@METUBE_VERSION@|$METUBE_VERSION|g" \
      "$ASSETS_DIR/metube.sh.in" > "$STAGE_DIR/usr/bin/metube"
  chmod 0755 "$STAGE_DIR/usr/bin/metube"

  # 配置应用工具（改下载目录后一键生效）
  sed -e "s|@METUBE_VERSION@|$METUBE_VERSION|g" \
      "$ASSETS_DIR/metube-apply-config.in" > "$STAGE_DIR/usr/bin/metube-apply-config"
  chmod 0755 "$STAGE_DIR/usr/bin/metube-apply-config"

  # 配置模板（非 conffile：以 example 形式随包分发，postinst 仅在
  # /etc/metube/metube.env 不存在时复制首装副本；升级永不触碰用户配置，
  # 避免本地修改过的配置触发 dpkg conffile 交互提示（应用中心非交互安装会失败））
  mkdir -p "$STAGE_DIR/usr/share/metube"
  cp "$ASSETS_DIR/metube.env" "$STAGE_DIR/usr/share/metube/metube.env.example"
  chmod 0644 "$STAGE_DIR/usr/share/metube/metube.env.example"

  # systemd 服务：F06 规范要求应用自带单元位于 /usr/local/<appid>/init.d/；
  # 同时在 /etc/systemd/system 放实体文件供 systemd 直接加载（名称与 app id 对齐）
  cp "$ASSETS_DIR/metubedownload.service" "$STAGE_DIR/usr/local/metubedownload/init.d/metubedownload.service"
  cp "$ASSETS_DIR/metubedownload.service" "$STAGE_DIR/etc/systemd/system/metubedownload.service"
  cp "$ASSETS_DIR/metube-pot.service" "$STAGE_DIR/etc/systemd/system/metube-pot.service"

  # TOS 应用中心集成层（官方规范：/usr/local/<appid>/ 下 config.ini + <appid>.lang
  # + <appid>.svg —— 文件名必须与 id 一致，市场校验器按此检查）
  log "  + TOS 应用中心元数据（/usr/local/metubedownload）"
  sed -e "s|@@VERSION@@|$METUBE_VERSION-$PKG_RELEASE|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/tos/config.ini.in" > "$STAGE_DIR/usr/local/metubedownload/config.ini"
  sed -e "s|@@VERSION@@|$METUBE_VERSION-$PKG_RELEASE|g" \
      "$ASSETS_DIR/tos/metubedownload.lang" > "$STAGE_DIR/usr/local/metubedownload/metubedownload.lang"
  cp "$ASSETS_DIR/tos/images/icons/metubedownload.svg" \
     "$STAGE_DIR/usr/local/metubedownload/images/icons/metubedownload.svg"

  # F22 规范：应用自带前端资源 /usr/local/<appid>/webui.bz2
  # （实际服务仍由应用自身提供；此副本满足应用中心包结构要求）
  tar -cjf "$STAGE_DIR/usr/local/metubedownload/webui.bz2" \
      -C "$M/ui/dist/metube/browser" .

  # C3-C8：隐私政策（包内 + 应用内可达：网页路径 /metube/privacy-policy.html）
  cp "$ASSETS_DIR/tos/privacy-policy.html" \
     "$STAGE_DIR/usr/local/metubedownload/privacy-policy.html"
  cp "$ASSETS_DIR/tos/privacy-policy.html" \
     "$M/ui/dist/metube/browser/privacy-policy.html"

  # nginx 反代（TOS 桌面 iframe 集成；conffile）
  sed -e "s|@@VERSION@@|$METUBE_VERSION-$PKG_RELEASE|g" \
      "$ASSETS_DIR/tos/nginx/metube.conf.in" > "$STAGE_DIR/etc/nginx/conf.d/metube.conf"

  # 文档
  cp "$SRC_DIR/LICENSE" "$STAGE_DIR/usr/share/doc/metube/copyright" 2>/dev/null || true
  # 源码级审计说明（回应应用市场 S9/V6/T1/S4：逐组件列出源码来源/构建方式/可复现审计）
  cp "$SCRIPT_DIR/docs/SOURCE-AUDIT.md" "$STAGE_DIR/usr/share/doc/metube/SOURCE-AUDIT.md" 2>/dev/null \
    || warn "缺少 docs/SOURCE-AUDIT.md（审计说明文档）"
  {
    echo "metube ($METUBE_VERSION-$PKG_RELEASE) TOS; urgency=medium"
    echo ""
    echo "  * 基于 MeTube 上游 $METUBE_VERSION 打包"
    echo "  * 包内运行时全部由公开 CI 从源码构建（CPython 官方源码、bgutil"
    echo "    Rust 源码、quickjs-ng C 源码、Python 依赖 sdist）——应用市场 V6 整改"
    echo "  * -016: 捆绑 quickjs-ng(qjs) 作为 yt-dlp JS 挑战解密运行时，修复"
    echo "    web client 因缺 JS runtime 导致格式缺失/下载失败（早期 deno 被误删）"
    echo "  * -017: 端口收敏（metube/pot 均仅监听 127.0.0.1，外部经 TOS nginx）；"
    echo "    新增源码级审计说明 /usr/share/doc/metube/SOURCE-AUDIT.md"
    echo "  * -018: config.ini 的 platform 随架构生成（x86_64/aarch64），修复 aarch64"
    echo "    包被应用市场判定 platform 与包架构不一致"
    echo ""
    echo " -- $MAINTAINER  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/metube/changelog.Debian"

  # BUILD-INFO（随包溯源；compat 构建明确标注不可用于商店提交）
  local VENDOR_MODE BGUTIL_COMMIT SRCYES
  VENDOR_MODE=$(cat "$VENDOR_DIR/.build-mode" 2>/dev/null || echo unknown)
  BGUTIL_COMMIT=""
  [ "$BGUTIL_ORIGIN" = "srcbuild" ] && [ -f "$SRC_BGUTIL_ROOT/.commit" ] \
    && BGUTIL_COMMIT=$(cat "$SRC_BGUTIL_ROOT/.commit")
  SRCYES=no
  [ "$BUILD_MODE" = "source" ] && [ "$PYTHON_ORIGIN" = "srcbuild" ] \
    && [ "$BGUTIL_ORIGIN" = "srcbuild" ] && [ "$VENDOR_MODE" = "source" ] \
    && [ "$QJS_ORIGIN" = "srcbuild" ] && SRCYES=yes
  cat > "$M/BUILD-INFO" <<EOF
build-mode: $BUILD_MODE (vendor: $VENDOR_MODE)
built-from-source: $SRCYES
built-at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
packaging-commit: ${BUILD_GIT_SHA:-local-dev}
ci-run: ${BUILD_RUN_URL:-local-dev-build}
metube-upstream: $METUBE_VERSION
python: $PBS_PYTHON (origin: $PYTHON_ORIGIN, source: https://www.python.org/ftp/python/$PBS_PYTHON/Python-$PBS_PYTHON.tgz, sha256: ${CPYTHON_SRC_SHA256:-n/a})
bgutil-pot: $BGUTIL_VERSION (origin: $BGUTIL_ORIGIN${BGUTIL_COMMIT:+, commit: $BGUTIL_COMMIT})
quickjs: $QUICKJS_VERSION (origin: $QJS_ORIGIN, source: https://github.com/quickjs-ng/quickjs, sha256: ${QUICKJS_SRC_SHA256:-n/a})
EOF

  # PROVENANCE（审计用：包内 ELF 组件的来源与构建方式；行文随实际 origin 变化）
  local PY_ROW BG_ROW QJS_ROW VENDOR_ROW
  if [ "$PYTHON_ORIGIN" = "srcbuild" ]; then
    PY_ROW="python.org official source tarball (sha256 ${CPYTHON_SRC_SHA256:-n/a}, pinned in config.env) | this repo's public workflow, stage python-src"
  else
    PY_ROW="python-build-standalone release $PBS_TAG (PREBUILT - dev builds only, do not submit) | n/a"
  fi
  if [ "$BGUTIL_ORIGIN" = "srcbuild" ]; then
    BG_ROW="github.com/jim60105/bgutil-ytdlp-pot-provider-rs tag $BGUTIL_VERSION${BGUTIL_COMMIT:+ (commit $BGUTIL_COMMIT)} | this repo's public workflow, stage bgutil-src (cargo build --release --locked --features ffi)"
  else
    BG_ROW="upstream release binary $BGUTIL_VERSION (PREBUILT - dev builds only, do not submit) | n/a"
  fi
  if [ "$QJS_ORIGIN" = "srcbuild" ]; then
    QJS_ROW="github.com/quickjs-ng/quickjs tag $QUICKJS_VERSION (sha256 ${QUICKJS_SRC_SHA256:-n/a}) | this repo's public workflow, stage quickjs-src (make qjs)"
  else
    QJS_ROW="upstream release binary $QUICKJS_VERSION (PREBUILT - dev builds only, do not submit) | n/a"
  fi
  if [ "$VENDOR_MODE" = "source" ]; then
    VENDOR_ROW="PyPI sdists, versions locked by upstream uv.lock | this repo's public workflow, stage deps (uv --no-binary)"
  else
    VENDOR_ROW="PyPI manylinux wheels (PREBUILT - dev builds only, do not submit) | n/a"
  fi
  cat > "$STAGE_DIR/usr/share/doc/metube/PROVENANCE.md" <<EOF
# Provenance - how every binary in this package was built

Built by: ${BUILD_RUN_URL:-local build (not CI)}
Packaging repo: https://github.com/Moechz/metube (commit ${BUILD_GIT_SHA:-unknown})
Build mode: $BUILD_MODE / vendor: $VENDOR_MODE

| Component | In package | Built from | By |
|---|---|---|---|
| CPython runtime | /opt/metube/python | $PY_ROW |
| PO Token server | /opt/metube/bin/bgutil-pot | $BG_ROW |
| JS runtime (qjs) | /opt/metube/bin/qjs | $QJS_ROW |
| Python dependencies | /opt/metube/vendor | $VENDOR_ROW |
| Web UI | /opt/metube/ui | upstream ui/ sources (tag $METUBE_VERSION) + assets/patches | this repo's public workflow, stage ui (pnpm/ng build) |
| ffmpeg / aria2 | system (not bundled) | Ubuntu/TOS apt packages | dpkg dependencies |

quickjs-ng (qjs) is bundled as the yt-dlp JS challenge runtime: the web player
client requires n/sig signature solving, and yt-dlp defaults to deno which this
package does not ship. The metube launcher exports YTDL_OPTIONS with
{"js_runtimes": {"quickjs": {}}} unless the user overrides it explicitly.

Audit: rerun the same public GitHub Actions workflow and compare artifacts.
A compat build (local development) bundles third-party prebuilt runtimes and is
marked as such in /opt/metube/BUILD-INFO; never submit compat builds to the store.

See /usr/share/doc/metube/SOURCE-AUDIT.md for the component-by-component
source-audit statement (review items S9 / V6 / T1 / S4).
EOF

  # 清理 macOS 扩展属性，避免污染 tar（AppleDouble / quarantine）
  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" -name '._*' -delete 2>/dev/null || true
  find "$STAGE_DIR" -name '.DS_Store' -delete 2>/dev/null || true

  log "组装完成"
}

# ============================================================
# 阶段: verify —— 交叉安装正确性校验（防 mac/linux 二进制混装）
# ============================================================
stage_verify() {
  [ -d "$STAGE_DIR/opt/metube" ] || die "尚未组装，请先运行: ./build.sh stage"
  local M="$STAGE_DIR/opt/metube"
  local fail=0

  log "校验关键路径..."
  local p
  for p in "$M/app/main.py" "$M/ui/dist/metube/browser/index.html" \
           "$M/vendor/yt_dlp" "$M/vendor/yt_dlp_plugins/extractor/getpot_bgutil.py" \
           "$M/python/bin/python3" "$M/bin/bgutil-pot" "$M/bin/qjs" "$M/BUILD-INFO" \
           "$STAGE_DIR/usr/share/doc/metube/PROVENANCE.md" \
           "$STAGE_DIR/usr/share/doc/metube/SOURCE-AUDIT.md" \
           "$STAGE_DIR/usr/bin/metube" \
           "$STAGE_DIR/usr/share/metube/metube.env.example" \
           "$STAGE_DIR/etc/systemd/system/metubedownload.service" \
           "$STAGE_DIR/etc/systemd/system/metube-pot.service" \
           "$STAGE_DIR/etc/nginx/conf.d/metube.conf" \
           "$STAGE_DIR/usr/local/metubedownload/config.ini" \
           "$STAGE_DIR/usr/local/metubedownload/metubedownload.lang" \
           "$STAGE_DIR/usr/local/metubedownload/images/icons/metubedownload.svg" \
           "$STAGE_DIR/usr/local/metubedownload/init.d/metubedownload.service" \
           "$STAGE_DIR/usr/local/metubedownload/webui.bz2" \
           "$STAGE_DIR/usr/local/metubedownload/privacy-policy.html"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  # 下游补丁存在时，验证补丁确实应用到了组装后的源码（以标记字符串为代表）
  if ls assets/patches/*.patch >/dev/null 2>&1; then
    log "校验下游补丁已生效..."
    grep -q "Set a download folder before downloading" "$M/app/main.py" \
      || { warn "app/main.py 缺少闸门补丁标记（补丁未应用？）"; fail=1; }
    grep -q "_metube_validate_custom_root" "$M/app/ytdl.py" \
      || { warn "app/ytdl.py 缺少粘性目录补丁标记（补丁未应用？）"; fail=1; }
    grep -q "_metube_startup_sticky" "$M/app/main.py" \
      || { warn "app/main.py 缺少启动采用标记（补丁未应用？）"; fail=1; }
  fi

  # V6 相关断言：deno 不得随包（-016 用 quickjs 替代）；qjs 必须存在
  if [ -e "$M/bin/deno" ] || [ -e "$M/vendor/bin/deno" ] \
     || ls "$M"/vendor/deno-*.dist-info >/dev/null 2>&1; then
    warn "发现 deno 随包（-011 起应彻底移除）"; fail=1
  fi
  [ -x "$M/bin/qjs" ] || { warn "缺少 qjs（quickjs-ng JS 运行时）"; fail=1; }

  # 应用市场规则：config.ini 的 platform 必须与包架构一致，否则后台报
  # "Platform mismatch: the platform bound architecture is aarch64, but the
  #  package resolves to x86_64"（-017 aarch64 实测）
  local cfg_plat
  cfg_plat=$(grep -oE '"platform"[[:space:]]*:[[:space:]]*"[^"]*"' \
               "$STAGE_DIR/usr/local/metubedownload/config.ini" 2>/dev/null \
             | sed 's/.*"\([^"]*\)"$/\1/')
  if [ "$cfg_plat" != "$TOS_PLATFORM" ]; then
    warn "config.ini platform=$cfg_plat 与目标架构 $TOS_PLATFORM 不一致（aarch64/x86_64 必须随架构生成）"; fail=1
  fi
  if [ "$BUILD_MODE" = "source" ]; then
    grep -q "built-from-source: yes" "$M/BUILD-INFO" \
      || { warn "source 构建的 BUILD-INFO 未标注 built-from-source: yes"; fail=1; }
  fi

  case "$TARGET_ARCH" in
    amd64) ELF_ARCH="x86-64" ;;
    arm64) ELF_ARCH="ARM aarch64" ;;
  esac

  log "校验 ELF 架构（目标: $ELF_ARCH, for GNU/Linux）..."
  # 只检查真正的 ELF：file 输出 ELF 的才算；避免 *.solver*.js 等 glob 误匹配
  local n_total=0 n_bad=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if file "$f" | grep -q "ELF"; then
      n_total=$((n_total + 1))
      file "$f" | grep -q "ELF.*$ELF_ARCH" \
        || { n_bad=$((n_bad + 1)); warn "错误架构: ${f#$STAGE_DIR/}"; }
    fi
  done < <(find "$M" -type f \
            \( -name "*.so" -o -name "*.so.*" -o -path "*/bin/*" -o -name "python3*" \))
  log "ELF 二进制 $n_total 个，异常 $n_bad 个"
  [ "$n_bad" -eq 0 ] || fail=1

  log "检查 macOS Mach-O 混入（应为 0）..."
  local n_macho
  n_macho=$(find "$M" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_macho" -eq 0 ] || { warn "发现 $n_macho 个 Mach-O 文件！"; fail=1; }

  # glibc 符号上限：防止在过新基座（如 ubuntu-24.04, glibc 2.39）上编译导致
  # 目标机 (TOS 7 / glibc 2.35) "GLIBC_2.xx not found"（-011 真机实锤）
  if command -v objdump >/dev/null 2>&1 \
     && objdump --version 2>/dev/null | head -1 | grep -q "GNU" \
     && [ -n "${GLIBC_FLOOR:-}" ]; then
    log "校验 glibc 符号上限（目标 ≤ $GLIBC_FLOOR）..."
    local n_glibc=0 ver bad
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      file "$f" | grep -q ELF || continue
      bad=""
      for ver in $(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -u); do
        if [ "$(printf '%s\n' "$GLIBC_FLOOR" "${ver#GLIBC_}" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]; then
          bad="$ver"; break
        fi
      done
      if [ -n "$bad" ]; then
        warn "glibc 符号超限: ${f#$STAGE_DIR/} 需要 $bad > $GLIBC_FLOOR"
        n_glibc=$((n_glibc + 1))
      fi
    done < <(find "$M" -type f \( -name "python3*" -o -name "*.so*" -o -path "*/bin/*" \))
    [ "$n_glibc" -eq 0 ] \
      || { warn "共 $n_glibc 个 ELF 引用了高于 $GLIBC_FLOOR 的 glibc 符号（换 ubuntu:22.04 容器重建）"; fail=1; }
  fi

  if [ "$fail" -eq 0 ]; then
    log "校验通过 ✅"
  else
    die "校验失败，请检查上方警告"
  fi
}

# ============================================================
# 阶段: deb —— 生成 .deb
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/opt/metube" ] || die "尚未组装，请先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  # shellcheck source=makedeb.sh
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$METUBE_VERSION" "$PKG_RELEASE" "$TARGET_ARCH" "$MAINTAINER"
  log "完成: $DEB_FILE"
}

stage_info() {
  cat <<EOF
MeTube 版本     : $METUBE_VERSION (deb $METUBE_VERSION-$PKG_RELEASE)
构建模式       : $BUILD_MODE（source=CI 全源码构建 / compat=开发回退）
目标架构       : $TARGET_ARCH ($UV_PY_PLATFORM)
CPython        : $PBS_PYTHON（source: 源码构建 / compat: PBS $PBS_TAG）
Node(仅构建)   : v$NODE_VERSION ($NODE_HOST_PLAT)
bgutil-pot     : $BGUTIL_VERSION ($BGUTIL_ARCH; source: Rust 源码构建)
quickjs-ng     : $QUICKJS_VERSION ($BGUTIL_ARCH; source: C 源码构建)
产物           : $DEB_FILE
EOF
}

stage_clean() {
  rm -rf "$STAGE_DIR" "$VENDOR_DIR" "$BUILD_DIR/requirements.txt"
  rm -rf "$SRC_DIR/ui/dist" 2>/dev/null || true
  log "已清理 stage/vendor/前端产物（保留下载缓存）"
}

stage_distclean() {
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  log "已清理全部构建产物与下载缓存"
}

# ============================================================
# 入口
# ============================================================
STAGE=${1:-all}
case "$STAGE" in
  fetch)      stage_fetch ;;
  ui)         stage_ui ;;
  deps)       stage_deps ;;
  python-src) stage_python_src ;;
  bgutil-src) stage_bgutil_src ;;
  quickjs-src) stage_quickjs_src ;;
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)
    if [ "$BUILD_MODE" = "source" ]; then
      stage_python_src
      stage_bgutil_src
      stage_quickjs_src
    fi
    stage_fetch; stage_ui; stage_deps; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  *)          die "未知阶段: $STAGE（可用: fetch ui deps python-src bgutil-src stage deb all clean distclean verify info）" ;;
esac
