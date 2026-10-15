#!/bin/bash
# sync-github.sh —— 创建 GitHub 仓库并推送本目录
#
# 用法：
#   bash sync-github.sh release [版本号]      # 推送代码 + 建 Release 上传 ZIP/DMG（推荐）
#   bash sync-github.sh [仓库名]              # 自动检测认证方式
#   VISIBILITY=private bash sync-github.sh   # 建私有仓库
#   GITHUB_TOKEN=ghp_xxx bash sync-github.sh # 用令牌创建
#
# 认证方式（按优先级）：
#   1. gh CLI（已登录）
#   2. 环境变量 GITHUB_TOKEN / GH_TOKEN
#   3. 交互输入令牌（classic PAT 勾选 repo 权限即可）
set -u
cd "$(dirname "$0")"

REPO="${1:-smartroute-macos}"
DESC="macOS 有线/无线双网卡智能选路 —— 自动故障切换 + 双网并发分流 + SwiftUI 图形界面"
VISIBILITY="${VISIBILITY:-public}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# 把项目内下载的 gh 加入 PATH（sync-github.sh 下载的官方二进制）
for _d in "$PWD"/.tools/gh_*/bin; do
    if [ -x "$_d/gh" ]; then
        case ":$PATH:" in
            *":$_d:"*) ;;
            *) PATH="$_d:$PATH"; export PATH; echo "使用本地 gh: $_d/gh" ;;
        esac
    fi
done
die() { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- release 模式：推送代码 + 建 Release 上传产物 ----------
if [ "${1:-}" = "release" ]; then
    shift
    VERSION="${1:-2.2}"
    say "发布模式 v$VERSION"
    command -v git >/dev/null 2>&1 || die "没有安装 git"
    [ -d .git ] || die "还没有 git 仓库，请先运行: bash sync-github.sh"
    git remote get-url origin >/dev/null 2>&1 || die "还没有 origin 远端，请先运行: bash sync-github.sh"

    # 1) 构建产物
    say "构建 ZIP"
    bash build_release.sh >/dev/null 2>&1 || die "build_release.sh 失败"
    ZIP="dist/SmartRoute-${VERSION}-macOS.zip"
    [ -f "$ZIP" ] || die "找不到 $ZIP"

    say "尝试构建 DMG（需要普通终端；沙箱内会失败，跳过即可）"
    if bash build_dmg.sh >/dev/null 2>&1; then
        echo "  ✓ DMG 已生成"
    else
        echo "  ⚠️ DMG 构建失败（多半是当前环境无权创建设备映像），本次只上传 ZIP"
    fi
    DMG="dist/SmartRoute-${VERSION}-macOS.dmg"

    # 2) 推送代码
    say "推送代码到 origin"
    git add -A
    if git diff --cached --quiet; then echo "  代码无变动"; else
        git commit -q -m "Release v${VERSION}" && echo "  已提交"
    fi
    git push -u origin main 2>&1 | tail -2 || die "推送失败"

    # 3) 建 Release 并上传产物
    say "创建 GitHub Release v${VERSION}"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        NOTES="$(mktemp)"; { echo "# SmartRoute v${VERSION}"; echo; cat INSTALL.md 2>/dev/null || cat README.md; } > "$NOTES"
        if [ -f "$DMG" ]; then
            gh release create "v${VERSION}" "$ZIP" "$DMG" --title "SmartRoute v${VERSION}" --notes-file "$NOTES"
        else
            gh release create "v${VERSION}" "$ZIP" --title "SmartRoute v${VERSION}" --notes-file "$NOTES"
        fi
        rm -f "$NOTES"
        say "✅ 已发布: $(gh release view "v${VERSION}" --json url -q .url 2>/dev/null)"
    else
        echo "没有 gh CLI 登录，无法直接建 Release。请先认证："
        echo "  export PATH=\"\$HOME/Pictures/smartroute/.tools/gh_*/bin:\$PATH\""
        echo "  gh auth login"
        echo "然后手动上传产物："
        echo "  gh release create v${VERSION} $ZIP $DMG --title \"SmartRoute v${VERSION}\" --notes-file INSTALL.md"
    fi
    exit 0
fi

# ---------- 0. git 基础 ----------
say "准备 git 仓库"
command -v git >/dev/null 2>&1 || die "没有安装 git"

if [ ! -d .git ]; then
    git init -b main 2>/dev/null || git init
fi

# 没有配置身份信息时给个默认值（可在仓库里用 git config 修改）
if [ -z "$(git config user.name)" ]; then
    git config user.name "SmartRoute"
    git config user.email "smartroute@users.noreply.github.com"
    echo "已设置默认提交身份（SmartRoute <smartroute@users.noreply.github.com）"
fi

# 确保 .gitignore 生效（不提交构建产物）
git add -A
if git diff --cached --quiet; then
    echo "没有需要提交的更改"
else
    git commit -q -m "SmartRoute v2.1：智能选路 + 双网并发 + 分流规则 + SwiftUI App

- 每 20 秒探测以太网/Wi-Fi 外网连通性，自动调整默认路由（滞回 + 冷却）
- 双网并发：pf round-robin 把新连接分发到两个网关，开启前自动验证、失败自动还原
- 分流规则：指定网段固定走指定接口（静态路由，普通用户可管理）
- 网速/延迟监控：实时速率曲线 + 逐接口延迟丢包
- SwiftUI App：9 个页面 + 应用图标 + 菜单栏图标，通用二进制（macOS 13+，Intel/Apple Silicon）"
    echo "已创建提交"
fi

# ---------- 1. 找认证 ----------
TOKEN=""
AUTH_MODE=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    AUTH_MODE="gh"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    TOKEN="$GITHUB_TOKEN"; AUTH_MODE="token"
elif [ -n "${GH_TOKEN:-}" ]; then
    TOKEN="$GH_TOKEN"; AUTH_MODE="token"
fi

if [ -z "$AUTH_MODE" ]; then
    say "需要 GitHub 认证"
    echo "没有检测到 gh CLI 登录或 GITHUB_TOKEN。"
    echo
    echo "请选择："
    echo "  1) 现在粘贴一个 Personal Access Token（classic，勾选 repo 权限）"
    echo "     https://github.com/settings/tokens/new?scopes=repo&description=SmartRoute"
    echo "  2) 或直接用项目自带的 gh（已下载好）:"
    echo "       export PATH=\"$HOME/Pictures/smartroute/.tools/gh_2.102.0_macOS_arm64/bin:\$PATH\""
    echo "       gh auth login"
    echo "       bash sync-github.sh"
    echo
    printf "粘贴令牌（直接回车则改为手动模式）: "
    read -r TOKEN
    if [ -n "$TOKEN" ]; then
        AUTH_MODE="token"
    fi
fi

# ---------- 2. 创建仓库并推送 ----------
say "创建仓库 $REPO 并推送"

if [ "$AUTH_MODE" = "gh" ]; then
    gh repo create "$REPO" --$VISIBILITY --source=. --remote=origin \
        --description "$DESC" --push \
        || git push -u origin main

elif [ "$AUTH_MODE" = "token" ]; then
    USER="$(curl -s -m 20 -H "Authorization: token $TOKEN" https://api.github.com/user \
            | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("login",""))' 2>/dev/null)"
    [ -n "$USER" ] || die "令牌无效或无法连接 GitHub API（请检查令牌权限）"
    echo "认证为用户: $USER"

    CODE="$(curl -s -m 20 -o /tmp/sr_repo.json -w '%{http_code}' \
        -X POST -H "Authorization: token $TOKEN" \
        -d "{\"name\":\"$REPO\",\"description\":\"$DESC\",\"private\":$([ "$VISIBILITY" = private ] && echo true || echo false),\"has_issues\":true}" \
        https://api.github.com/user/repos)"
    if [ "$CODE" = "201" ]; then
        echo "仓库已创建"
    elif [ "$CODE" = "422" ]; then
        echo "仓库已存在，直接推送"
    else
        cat /tmp/sr_repo.json 2>/dev/null | head -5
        die "创建仓库失败（HTTP ${CODE}）"
    fi

    git remote remove origin 2>/dev/null
    git remote add origin "https://x-access-token:$TOKEN@github.com/$USER/$REPO.git"
    git push -u origin main

else
    say "手动模式（不推送）"
    echo "仓库已在本地初始化并提交。手动上传："
    echo
    echo "  1. 打开 https://github.com/new 新建仓库（不要勾选初始化 README）"
    echo "  2. 然后执行："
    echo "       git remote add origin https://github.com/<你的用户名>/$REPO.git"
    echo "       git push -u origin main"
    echo
    echo "或者安装 GitHub CLI："
    echo "       brew install gh && gh auth login && bash sync-github.sh"
    exit 0
fi

say "完成"
git remote -v | head -2
echo
echo "接下来（可选）：把构建产物作为 Release 发布："
echo "  bash build_release.sh        # 生成 dist/SmartRoute-2.1-macOS.zip"
echo "  bash build_dmg.sh            # 生成 dist/SmartRoute-2.1-macOS.dmg（需普通终端）"
if [ "$AUTH_MODE" = "gh" ]; then
    echo "  gh release create v2.1 dist/SmartRoute-2.1-macOS.zip dist/SmartRoute-2.1-macOS.dmg \\"
    echo "      --title \"SmartRoute v2.1\" --notes-file INSTALL.md"
fi
