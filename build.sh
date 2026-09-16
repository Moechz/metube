#!/usr/bin/env bash
# ============================================================
# build.sh - 在 macOS / Linux 上把 MeTube 打包成适用于
# TOS（Debian 系 NAS 系统，如 TerraMaster TOS 5/6）的 deb 包
#
# 用法:
#   ./build.sh            # 完整构建，产出 out/metube_<ver>_<arch>.deb
#   ./build.sh <stage>    # 只跑某个阶段: fetch ui deps stage deb
#   ./build.sh info       # 查看当前配置
#
# 阶段说明:
#   fetch  下载全部外部资源到 build/downloads（有缓存，可重复执行）
#   ui     用 Node 22 + pnpm 构建 Angular 前端
#   deps   用 uv 按 uv.lock 交叉安装 Python 依赖到 build/vendor
#   stage  组装 deb 文件系统树 build/pkgroot
#   deb    生成最终 .deb（macOS 上用 ar+tar 手工打包）
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
    DENO_TRIPLE="x86_64-unknown-linux-gnu"
    BGUTIL_ARCH="x86_64"
    ;;
  arm64)
    UV_PY_PLATFORM="aarch64-unknown-linux-gnu"
    PBS_TRIPLE="aarch64-unknown-linux-gnu"
    DENO_TRIPLE="aarch64-unknown-linux-gnu"
    BGUTIL_ARCH="aarch64"
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
DENO_ZIP="deno-$DENO_TRIPLE.zip"
BGUTIL_BIN="bgutil-pot-linux-$BGUTIL_ARCH"
BGUTIL_ZIP="bgutil-ytdlp-pot-provider-rs.zip"
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

  # 4. 独立 CPython 3.13（目标平台，进入 deb）
  fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/$PY_RUNTIME_TARBALL" \
        "$DL_DIR/$PY_RUNTIME_TARBALL"

  # 5. Deno（目标平台，进入 deb）
  fetch "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-$DENO_TRIPLE.zip" \
        "$DL_DIR/$DENO_ZIP"

  # 6. bgutil PO Token provider（目标平台，进入 deb）
  fetch "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/$BGUTIL_VERSION/$BGUTIL_BIN" \
        "$DL_DIR/$BGUTIL_BIN"
  fetch "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/$BGUTIL_VERSION/$BGUTIL_ZIP" \
        "$DL_DIR/$BGUTIL_ZIP"

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

  log "从 uv.lock 导出锁定版本依赖..."
  ( cd "$SRC_DIR"
    "$uv" export --frozen --no-dev --no-hashes --no-emit-project \
      --format requirements-txt -o "$BUILD_DIR/requirements.txt"
  )

  log "交叉安装 Python 依赖到 build/vendor（目标: $UV_PY_PLATFORM / py3.13）..."
  rm -rf "$VENDOR_DIR"
  # 国内网络可 export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
  "$uv" pip install \
    -r "$BUILD_DIR/requirements.txt" \
    --python-version 3.13 \
    --python-platform "$UV_PY_PLATFORM" \
    --no-compile \
    --target "$VENDOR_DIR"

  [ -d "$VENDOR_DIR/yt_dlp" ] || die "yt-dlp 未安装到 vendor，构建异常"
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

  # 独立 Python 3.13 运行时（tarball 顶层为 python/）
  log "  + python/（捆绑 CPython $PBS_PYTHON+$PBS_TAG）"
  tar xzf "$DL_DIR/$PY_RUNTIME_TARBALL" -C "$STAGE_DIR/opt/metube"

  # Deno + bgutil PO Token provider（对齐上游 Docker 镜像行为）
  log "  + bin/deno, bin/bgutil-pot（PO Token 组件）"
  unzip -oq "$DL_DIR/$DENO_ZIP" -d "$M/bin"
  cp "$DL_DIR/$BGUTIL_BIN" "$M/bin/bgutil-pot"
  chmod 0755 "$M/bin/bgutil-pot"

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
  {
    echo "metube ($METUBE_VERSION-$PKG_RELEASE) TOS; urgency=medium"
    echo ""
    echo "  * 基于 MeTube 上游 $METUBE_VERSION 打包"
    echo "  * 捆绑 CPython $PBS_PYTHON+$PBS_TAG / Deno v$DENO_VERSION / bgutil-pot $BGUTIL_VERSION"
    echo ""
    echo " -- $MAINTAINER  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/metube/changelog.Debian"

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
           "$M/python/bin/python3" "$M/bin/deno" "$M/bin/bgutil-pot" \
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
目标架构       : $TARGET_ARCH ($UV_PY_PLATFORM)
捆绑 CPython   : $PBS_PYTHON+$PBS_TAG
Node(仅构建)   : v$NODE_VERSION ($NODE_HOST_PLAT)
Deno           : v$DENO_VERSION ($DENO_TRIPLE)
bgutil-pot     : $BGUTIL_VERSION ($BGUTIL_ARCH)
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
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)        stage_fetch; stage_ui; stage_deps; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  *)          die "未知阶段: $STAGE（可用: fetch ui deps stage deb all clean distclean info）" ;;
esac
