#!/usr/bin/env bash
# 把桌面端打包成 .app 并部署到本机（默认 /Applications/Piko.app），部署后直接启动。
#
#   scripts/macos/deploy.sh                 # 开发构建（不跑 ProGuard，速度快，数据目录 ~/.piko-dev）
#   scripts/macos/deploy.sh --release       # Release 构建（ProGuard 裁剪，数据目录同样是 ~/.piko-dev）
#   scripts/macos/deploy.sh --install-dir ~/Applications
#   scripts/macos/deploy.sh --no-launch
#   scripts/macos/deploy.sh --force         # 目标位置已有非开发版 Piko 时仍然覆盖
#   scripts/macos/deploy.sh --check-only    # 只检查环境，不写配置
#   scripts/macos/deploy.sh --clone-sdk     # pikpak-kotlin 缺失时顺便克隆到约定路径
#   scripts/macos/deploy.sh --skip-env-check
#
# 构建前默认运行 check-env.sh --fix --quiet，自动写入缺失的本机配置（local.properties /
# ~/.gradle/gradle.properties）；空白 Mac 上先按提示补装 JDK、Xcode 命令行工具与 Android SDK。
#
# 不带 -PpikoDesktopVersion 构建出来的包固定使用 ~/.piko-dev，与正式安装版的 ~/.piko 和单实例锁相互隔离，
# 因此可以与本机已安装的正式版并存。脚本一旦发现目标路径上的 Piko 不是这种开发构建（例如正式版），
# 默认拒绝覆盖，避免误删用户的正式安装。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env-lib.sh
source "$script_dir/env-lib.sh"

app_name="Piko"
install_dir="/Applications"
build_type="dev"
launch=true
force=false
check_only=false
clone_sdk=false
skip_env_check=false

usage() {
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) build_type="release" ;;
        --install-dir)
            [[ $# -ge 2 ]] || { echo "--install-dir 需要目录参数" >&2; exit 1; }
            install_dir="$2"
            shift
            ;;
        --no-launch) launch=false ;;
        --force) force=true ;;
        --check-only) check_only=true ;;
        --clone-sdk) clone_sdk=true ;;
        --skip-env-check) skip_env_check=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

die() { echo "错误：$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "此脚本只用于 macOS。"
[[ "$(uname -m)" == "arm64" ]] || die "仓库的 macOS 产物仅支持 Apple Silicon（arm64），jpackage 也不能交叉打包。"

if [[ "$skip_env_check" != true ]]; then
    if [[ "$clone_sdk" == true ]]; then
        "$script_dir/check-env.sh" --fix --clone-sdk --quiet
    elif [[ "$check_only" == true ]]; then
        "$script_dir/check-env.sh" --quiet
    else
        "$script_dir/check-env.sh" --fix --quiet
    fi
fi

# 空白 Mac 上 PATH 里的 java 可能不存在或低于 17；Gradle 需要 17+。
if java_home="$(piko_gradle_java_home 2>/dev/null)"; then
    if [[ -n "$java_home" ]]; then
        export JAVA_HOME="$java_home"
    fi
else
    die "找不到 JDK 17+，Gradle 无法启动。先运行 scripts/macos/check-env.sh 查看缺什么。"
fi

if [[ "$build_type" == "release" ]]; then
    gradle_task=":desktopApp:createReleaseDistributable"
    app_image="desktopApp/build/compose/binaries/main-release/app/$app_name.app"
else
    gradle_task=":desktopApp:createDistributable"
    app_image="desktopApp/build/compose/binaries/main/app/$app_name.app"
fi

dest="$install_dir/$app_name.app"

# 判断目标位置上的包是不是本脚本部署的开发构建：启动配置里带 ~/.piko-dev。
is_dev_build() {
    local cfg="$1/Contents/app/$app_name.cfg"
    [[ -f "$cfg" ]] && grep -q -- '-Dpiko\.home=.*\.piko-dev' "$cfg"
}

if [[ -e "$dest" && "$force" != true ]] && ! is_dev_build "$dest"; then
    die "$dest 已存在，且不是开发构建（可能是正式安装版）。请先确认后加 --force，或改用 --install-dir 指定其他目录。"
fi

echo "==> 构建 $gradle_task"
./gradlew "$gradle_task"

[[ -d "$app_image" ]] || die "构建完成但没有找到 $app_image。"

# 结束目标路径上正在运行的实例，否则新拷贝的包不会生效（旧进程仍持有旧 inode）。
if pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1; then
    echo "==> 结束正在运行的 $dest"
    pkill -f "$dest/Contents/MacOS/" 2>/dev/null || true
    for _ in $(seq 1 40); do
        pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1 || break
        sleep 0.25
    done
    if pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1; then
        die "$dest 仍在运行，无法替换。请手动退出后重试。"
    fi
fi

mkdir -p "$install_dir"
# 在目标目录内暂存，保证随后的 mv 是同卷原子重命名。
staging="$(mktemp -d "$install_dir/.piko-deploy.XXXXXX")"
backup="$install_dir/.$app_name.app.backup.$$"
swap_state="idle"
cleanup() {
    rm -rf "$staging"
    # 中途被打断时把旧版本放回原位，避免目标位置空着。
    if [[ "$swap_state" == "moved-out" && -e "$backup" && ! -e "$dest" ]]; then
        mv "$backup" "$dest" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "==> 复制到 $dest"
/usr/bin/ditto "$app_image" "$staging/$app_name.app"

[[ -x "$staging/$app_name.app/Contents/MacOS/$app_name" ]] || die "拷贝后的应用缺少启动器。"

if [[ -e "$dest" ]]; then
    mv "$dest" "$backup"
    swap_state="moved-out"
fi
if ! mv "$staging/$app_name.app" "$dest"; then
    die "替换 $dest 失败，正在恢复旧版本。"
fi
swap_state="done"
rm -rf "$backup"

# 本机构建的包没有隔离属性，清一下防止从别处拷入的构建被 Gatekeeper 拦截。
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

# jpackage 默认做 ad-hoc 签名，校验失败只提示，不影响本机开发使用。
if ! /usr/bin/codesign --verify --deep --strict "$dest" >/dev/null 2>&1; then
    echo "提示：codesign 校验未通过（ad-hoc 签名的开发包可忽略）。" >&2
fi

echo "==> 已部署：$dest"
echo "    数据目录：~/.piko-dev（与正式版的 ~/.piko 隔离）"

if [[ "$launch" == true ]]; then
    open "$dest"
fi
