#!/bin/bash
# 发布 GitHub Release（含 deb 资产）。用法: GH_TOKEN=<PAT> ./scripts/publish-release.sh
# 仅依赖 curl + python3（macOS/Linux 自带）；可重复执行（已存在的 release/资产会复用/替换）
set -euo pipefail
REPO="Moechz/metube"
TAG="v2026.08.28-010"
DEB="out/metube_2026.08.28-010_amd64.deb"
NOTES="scripts/release-notes-v2026.08.28-010.md"
[ -n "${GH_TOKEN:-}" ] || { echo "缺少 GH_TOKEN（需要 contents:write 权限的 PAT）"; exit 1; }
[ -f "$DEB" ] || { echo "缺少 $DEB"; exit 1; }
[ -f "$NOTES" ] || { echo "缺少 $NOTES"; exit 1; }

API="https://api.github.com/repos/$REPO"

# curl 带 http_code 输出，交给 python 解析：成功打印所需字段，失败原样报错退出
gh_post() { # gh_post <url> <content-type> <data>
  curl -sS -X POST "$1" -H "Authorization: Bearer $GH_TOKEN" \
    -H "Content-Type: $2" --data-binary "$3" -w '\n%{http_code}'
}

# ---------- 1. release 对象 ----------
echo "==> 创建/获取 release $TAG ..."
RESP=$(gh_post "$API/releases" "application/json" "$(python3 - "$NOTES" "$TAG" <<'PYEOF'
import json, sys
notes = open(sys.argv[1]).read()
print(json.dumps({"tag_name": sys.argv[2], "name": sys.argv[2],
                  "body": notes, "draft": False, "prerelease": False}))
PYEOF
)")
REL_ID=$(python3 - "$RESP" <<'PYEOF'
import json, sys
raw = sys.argv[1]
body, _, code = raw.rpartition('\n')
try:
    d = json.loads(body)
except json.JSONDecodeError:
    d = {}
if code == '201':
    print(d['id'])
elif code == '422' or d.get('errors', [{}])[0].get('code') == 'already_exists':
    raise SystemExit('EXISTS')
else:
    sys.stderr.write(f"创建失败 HTTP {code}: {body[:500]}\n")
    raise SystemExit(1)
PYEOF
) || REL_ID=""
if [ -z "$REL_ID" ]; then
  REL_ID=$(curl -sS "$API/releases/tags/$TAG" -H "Authorization: Bearer $GH_TOKEN" |
    python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  echo "    已存在，复用 release id=$REL_ID"
else
  echo "    已创建 release id=$REL_ID"
fi

# ---------- 2. 清理同名旧资产 ----------
DEBNAME=$(basename "$DEB")
curl -sS "$API/releases/$REL_ID/assets" -H "Authorization: Bearer $GH_TOKEN" |
  python3 -c "import json,sys; [print(a['id']) for a in json.load(sys.stdin) if a['name']=='$DEBNAME']" |
  while read -r aid; do
    echo "    删除旧资产 id=$aid"
    curl -sS -o /dev/null -X DELETE "$API/releases/assets/$aid" -H "Authorization: Bearer $GH_TOKEN"
  done

# ---------- 3. 上传资产 ----------
echo "==> 上传 $DEBNAME（${DEBNAME##*.}，112M，请稍候）..."
RESP=$(gh_post "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=$DEBNAME" \
  "application/vnd.debian.binary-package" "@$DEB")
python3 - "$RESP" <<'PYEOF'
import json, sys
raw = sys.argv[1]
body, _, code = raw.rpartition('\n')
if code != '201':
    sys.stderr.write(f"上传失败 HTTP {code}: {body[:500]}\n")
    raise SystemExit(1)
print("==> 完成:", json.loads(body)['browser_download_url'])
PYEOF
