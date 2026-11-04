#!/usr/bin/env bash
# 检查（并可选写入）macOS 桌面端的构建/部署环境。换到一台空白 Mac 时先跑这个。
#
#   scripts/macos/check-env.sh                  # 只检查，列出缺什么
#   scripts/macos/check-env.sh --fix            # 检查并写入本机配置（local.properties / ~/.gradle）
#   scripts/macos/check-env.sh --fix --clone-sdk  # 配置缺失时顺便把 pikpak-kotlin 克隆到约定路径
#   scripts/macos/check-env.sh --quiet          # 只输出问题与结论，供 dev-run.sh / deploy.sh 调用
#
# 检查项：Apple Silicon + macOS、Xcode 命令行工具、JDK 21 与 Azul Zulu 25（含 jmods）、
# Android SDK、pikpak-kotlin 源码检出、两仓库的 Kotlin/AGP/Gradle 版本一致性，
# 以及 local.properties 与 ~/.gradle/gradle.properties 里的必需配置。
#
# --fix 只写这三类本机配置，不安装任何软件：
#   <piko>/local.properties        pikpak.sdk.dir、sdk.dir
#   <sdk>/local.properties         sdk.dir（复合构建里的 Android 插件需要）
#   ~/.gradle/gradle.properties    org.gradle.java.installations.paths（绕开 foojay 崩溃）
#
# 环境变量：
#   PIKO_SDK_DIR      SDK 检出路径，默认 ~/DataSync/RemoteGHProject/pikpak-kotlin
#   PIKO_SDK_REPO     --clone-sdk 使用的仓库，默认 https://github.com/NihilDigit/pikpak-kotlin.git
#   PIKO_ANDROID_HOME 优先使用的 Android SDK 路径
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env-lib.sh
source "$script_dir/env-lib.sh"

fix=false
clone_sdk=false
quiet=false

usage() {
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix) fix=true ;;
        --clone-sdk) clone_sdk=true; fix=true ;;
        --quiet) quiet=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

sdk_dir="${PIKO_SDK_DIR:-$HOME/DataSync/RemoteGHProject/pikpak-kotlin}"
# 相对路径按仓库根目录解析，与 settings.gradle.kts 里的 includeBuild 行为一致。
[[ "$sdk_dir" = /* ]] || sdk_dir="$repo_root/$sdk_dir"
sdk_repo="${PIKO_SDK_REPO:-https://github.com/NihilDigit/pikpak-kotlin.git}"

errors=""
warnings=""

say() { [[ "$quiet" == true ]] || printf '%s\n' "$*"; }
ok() { say "✓ $*"; }
warn() { warnings="${warnings}$*"$'\n'; }
err() { errors="${errors}$*"$'\n'; }
fixed() { printf '写入：%s\n' "$*"; }

finish() {
    local status=0
    if [[ -n "$warnings" && "$quiet" != true ]]; then
        printf '\n注意：\n%s' "$warnings" >&2
    fi
    if [[ -n "$errors" ]]; then
        printf '\n环境检查失败：\n%s' "$errors" >&2
        printf '提示：运行 scripts/macos/check-env.sh --fix 写入可自动补全的本机配置；\n' >&2
        printf '      缺失的 SDK / JDK / 命令行工具按上面的提示安装后重新检查。\n' >&2
        status=1
    else
        say ""
        say "环境检查通过。"
    fi
    exit "$status"
}

# 写入或替换 properties 文件中的 key=value，保留其余行与文件权限。
set_property() {
    local file="$1" key="$2" value="$3" tmp mode=""
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] && mode="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
    tmp="$(mktemp "$file.tmp.XXXXXX")"
    if [[ -f "$file" ]]; then
        cat "$file" > "$tmp"
    fi
    awk -v k="$key" -v v="$value" '
        BEGIN { prefix = k "="; done = 0 }
        index($0, prefix) == 1 { if (!done) { print prefix v; done = 1 }; next }
        { print }
        END { if (!done) print prefix v }
    ' "$tmp" > "$tmp.new"
    mv "$tmp.new" "$tmp"
    mv "$tmp" "$file"
    [[ -n "$mode" ]] && chmod "$mode" "$file" 2>/dev/null || true
}

piko_merge_paths() {
    local out="$1" p
    shift
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        case ",$out," in
            *",$p,"*) ;;
            *) out="${out:+$out,}$p" ;;
        esac
    done
    printf '%s' "$out"
}

# 相对路径按仓库根目录解析。
resolve_repo_path() {
    if [[ "$1" = /* ]]; then
        piko_abspath "$1"
    else
        piko_abspath "$repo_root/$1"
    fi
}

check_same_version() {
    local name="$1" expected="$2" actual="$3" source="$4"
    if [[ -z "$actual" ]]; then
        warn "无法从 $source 读取 $name 版本，跳过一致性检查。"
    elif [[ "$expected" != "$actual" ]]; then
        err "$name 版本不一致：Piko $expected / SDK $actual。两仓库的 Kotlin、AGP 与 Gradle 必须保持一致，否则复合构建解析失败。"
    else
        ok "$name 版本一致：$expected"
    fi
}

# --- 系统 ---
if [[ "$(uname -s)" != "Darwin" ]]; then
    err "当前系统不是 macOS；仓库的桌面产物只能在 macOS 上构建（jpackage 不能交叉打包）。"
    finish
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    err "当前架构是 $(uname -m)，仓库的 macOS 产物只支持 Apple Silicon（arm64）。"
else
    ok "macOS $(sw_vers -productVersion) / arm64"
fi

# --- Xcode 命令行工具 ---
if xcode-select -p >/dev/null 2>&1 && xcrun --find codesign >/dev/null 2>&1; then
    ok "Xcode Command Line Tools：$(xcode-select -p)"
else
    err "缺少 Xcode Command Line Tools（jpackage 签名与打包需要）。安装：xcode-select --install"
fi

# --- JDK ---
jdk21="$(piko_find_jdk 21 false 2>/dev/null || true)"
jdk25_zulu="$(piko_find_jdk 25 true 2>/dev/null || true)"
jdk25_any="$(piko_find_jdk 25 false 2>/dev/null || true)"

if [[ -n "$jdk21" ]]; then
    ok "JDK 21：$jdk21"
else
    err "未找到 JDK 21（pikpak-kotlin 复合构建的 toolchain）。安装：brew install --cask temurin@21，或安装 Android Studio 使用其 JBR。"
fi

if [[ -n "$jdk25_zulu" ]]; then
    if piko_java_has_jmods "$jdk25_zulu"; then
        ok "JDK 25 (Zulu)：$jdk25_zulu"
    else
        err "JDK 25 缺少 jmods（$jdk25_zulu/jmods/java.base.jmod）。jlink/jpackage 需要完整 JDK，请安装 Azul Zulu 25。"
    fi
elif [[ -n "$jdk25_any" ]]; then
    err "找到 JDK 25（$jdk25_any），但它不是 Azul Zulu；打包任务固定按 AZUL 选择工具链。安装：brew install --cask zulu@25"
else
    err "未找到 JDK 25。安装 Azul Zulu 25（带 jmods）：brew install --cask zulu@25，或从 https://www.azul.com/downloads/ 下载。"
fi

auto_java=""
if auto_java="$(piko_gradle_java_home 2>/dev/null)"; then
    if [[ -n "$auto_java" ]]; then
        warn "PATH / JAVA_HOME 上的 java 低于 17；dev-run.sh 与 deploy.sh 会临时使用 JAVA_HOME=$auto_java。"
    else
        ok "Gradle 运行 JDK 可用（java 17+）"
    fi
else
    err "PATH 与 JAVA_HOME 上都没有 JDK 17+，Gradle 无法启动。安装 JDK 21 后重新检查。"
fi

# --- Android SDK ---
android_sdk="$(piko_find_android_sdk 2>/dev/null || true)"
if [[ -n "$android_sdk" ]]; then
    ok "Android SDK：$android_sdk"
    if ls -d "$android_sdk"/platforms/android-37* >/dev/null 2>&1; then
        ok "Android 平台：android-37.x"
    else
        warn "未找到 platforms/android-37.x（项目 compileSdk=37.1）。编译 Android 目标前需：sdkmanager \"platforms;android-37.1\""
    fi
    if ls -d "$android_sdk"/build-tools/* >/dev/null 2>&1; then
        ok "Android build-tools：$(find "$android_sdk/build-tools" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tail -n 1)"
    else
        warn "Android SDK 里没有 build-tools；编译 Android 目标前需通过 sdkmanager 安装。"
    fi
else
    err "未找到 Android SDK（复合构建里的 Android 插件配置时需要）。安装 Android Studio（brew install --cask android-studio），或安装 android-commandlinetools 后设置 ANDROID_HOME / PIKO_ANDROID_HOME。"
fi

# --- pikpak-kotlin 检出 ---
if [[ ! -d "$sdk_dir" ]]; then
    if [[ "$clone_sdk" == true ]]; then
        printf '克隆 %s 到 %s\n' "$sdk_repo" "$sdk_dir"
        mkdir -p "$(dirname "$sdk_dir")"
        if git clone "$sdk_repo" "$sdk_dir"; then
            printf '已克隆：%s\n' "$sdk_dir"
        else
            err "克隆 pikpak-kotlin 失败。请检查网络或手动克隆到 $sdk_dir。"
        fi
    else
        err "找不到 pikpak-kotlin：$sdk_dir。按约定只使用 RemoteGHProject 下的检出；运行本脚本加 --fix --clone-sdk 可自动克隆。"
    fi
fi

sdk_ready=false
if [[ -d "$sdk_dir" ]]; then
    sdk_dir="$(piko_abspath "$sdk_dir")"
    if [[ -f "$sdk_dir/settings.gradle.kts" || -f "$sdk_dir/settings.gradle" ]]; then
        sdk_ready=true
        ok "pikpak-kotlin：$sdk_dir"
    else
        err "$sdk_dir 不是 Gradle 工程（缺少 settings.gradle.kts）。请确认检出完整。"
    fi
fi

if [[ "$sdk_ready" == true ]]; then
    piko_catalog="$repo_root/gradle/libs.versions.toml"
    sdk_catalog="$sdk_dir/gradle/libs.versions.toml"
    piko_kotlin="$(piko_toml_version "$piko_catalog" kotlin || true)"
    sdk_kotlin="$(piko_toml_version "$sdk_catalog" kotlin || true)"
    [[ -n "$sdk_kotlin" ]] || sdk_kotlin="$(piko_sdk_kotlin_version "$sdk_dir" || true)"
    piko_agp="$(piko_toml_version "$piko_catalog" agp || true)"
    sdk_agp="$(piko_toml_version "$sdk_catalog" agp || true)"
    [[ -n "$sdk_agp" ]] || sdk_agp="$(piko_sdk_agp_version "$sdk_dir" || true)"
    piko_gradle="$(piko_gradle_version "$repo_root/gradle/wrapper/gradle-wrapper.properties" || true)"
    sdk_gradle="$(piko_gradle_version "$sdk_dir/gradle/wrapper/gradle-wrapper.properties" || true)"

    check_same_version "Kotlin" "$piko_kotlin" "$sdk_kotlin" "$sdk_dir/build.gradle.kts"
    check_same_version "AGP" "$piko_agp" "$sdk_agp" "$sdk_dir/build.gradle.kts"
    check_same_version "Gradle" "$piko_gradle" "$sdk_gradle" "$sdk_dir/gradle/wrapper/gradle-wrapper.properties"
fi

# --- local.properties ---
local_props="$repo_root/local.properties"
configured_sdk="$(piko_property "$local_props" pikpak.sdk.dir || true)"
if [[ "$fix" == true && "$sdk_ready" == true ]]; then
    if [[ "$configured_sdk" == "$sdk_dir" ]]; then
        ok "local.properties：pikpak.sdk.dir 指向 $sdk_dir"
    else
        if [[ -n "$configured_sdk" ]]; then
            fixed "$local_props：pikpak.sdk.dir $configured_sdk → $sdk_dir"
        else
            fixed "$local_props：pikpak.sdk.dir=$sdk_dir"
        fi
        set_property "$local_props" pikpak.sdk.dir "$sdk_dir"
    fi
elif [[ "$sdk_ready" != true ]]; then
    : # SDK 目录本身缺失或不可用，上面已经报错；没有可写入的值。
elif [[ -z "$configured_sdk" ]]; then
    err "$local_props 未配置 pikpak.sdk.dir。运行 --fix 自动写入，或手动写 pikpak.sdk.dir=$sdk_dir"
elif [[ "$(resolve_repo_path "$configured_sdk")" != "$sdk_dir" ]]; then
    err "pikpak.sdk.dir 指向 $(resolve_repo_path "$configured_sdk")，与约定的 RemoteGHProject 检出 $sdk_dir 不一致。运行 --fix 改写。"
else
    ok "local.properties：pikpak.sdk.dir 指向 $sdk_dir"
fi

configured_android="$(piko_property "$local_props" sdk.dir || true)"
if [[ -n "$android_sdk" ]]; then
    if [[ "$fix" == true ]]; then
        if [[ "$configured_android" == "$android_sdk" ]]; then
            ok "local.properties：sdk.dir 指向 $android_sdk"
        else
            set_property "$local_props" sdk.dir "$android_sdk"
            fixed "$local_props：sdk.dir=$android_sdk"
        fi
    elif [[ -z "$configured_android" ]]; then
        warn "$local_props 未写 sdk.dir，当前依赖 ANDROID_HOME=$android_sdk；--fix 可写入，避免从图形界面启动时读不到环境变量。"
    elif [[ "$(piko_abspath "$configured_android")" != "$android_sdk" ]]; then
        warn "$local_props 的 sdk.dir=$configured_android 与检测到的 Android SDK $android_sdk 不一致。"
    else
        ok "local.properties：sdk.dir 指向 $android_sdk"
    fi
fi

# --- SDK 仓库的 local.properties ---
if [[ "$sdk_ready" == true ]]; then
    sdk_local_props="$sdk_dir/local.properties"
    sdk_configured_android="$(piko_property "$sdk_local_props" sdk.dir || true)"
    if [[ -n "$android_sdk" && "$fix" == true ]]; then
        if [[ "$sdk_configured_android" == "$android_sdk" ]]; then
            ok "SDK local.properties：sdk.dir 指向 $android_sdk"
        else
            set_property "$sdk_local_props" sdk.dir "$android_sdk"
            fixed "$sdk_local_props：sdk.dir=$android_sdk"
        fi
    elif [[ -z "$sdk_configured_android" ]]; then
        err "$sdk_local_props 缺少 sdk.dir（复合构建里的 Android 插件需要）。运行 --fix 自动写入。"
    elif [[ -n "$android_sdk" && "$(piko_abspath "$sdk_configured_android")" != "$android_sdk" ]]; then
        warn "$sdk_local_props 的 sdk.dir=$sdk_configured_android 与检测到的 Android SDK $android_sdk 不一致。"
    else
        ok "SDK local.properties：sdk.dir 已配置"
    fi
fi

# --- Gradle 工具链路径 ---
if [[ -n "$jdk21" && -n "$jdk25_zulu" ]]; then
    gradle_props="${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties"
    current_paths="$(piko_property "$gradle_props" org.gradle.java.installations.paths || true)"
    needed=""
    for candidate in "$jdk21" "$jdk25_zulu"; do
        case ",$current_paths," in
            *",$candidate,"*) ;;
            *) needed="${needed}  $candidate"$'\n' ;;
        esac
    done
    if [[ "$fix" == true ]]; then
        merged="$(piko_merge_paths "$current_paths" "$jdk21" "$jdk25_zulu")"
        if [[ "$merged" != "$current_paths" ]]; then
            if [[ ! -f "$gradle_props" ]]; then
                mkdir -p "$(dirname "$gradle_props")"
                printf '# 由 Piko 的 scripts/macos/check-env.sh 写入：Gradle 9.6.1 + foojay 0.9.0 自动下载会崩溃，\n# 这里显式声明 composite build 需要的 JDK 21 与打包用的 Zulu 25。\n' > "$gradle_props"
            fi
            set_property "$gradle_props" org.gradle.java.installations.paths "$merged"
            fixed "$gradle_props：org.gradle.java.installations.paths=$merged"
        else
            ok "Gradle 工具链路径已包含 JDK 21 / Zulu 25"
        fi
    elif [[ -n "$needed" ]]; then
        err "Gradle 配置 $gradle_props 的 org.gradle.java.installations.paths 缺少：$needed（Gradle 9.6.1 下 foojay 0.9.0 自动下载会因 NoSuchFieldError: IBM_SEMERU 崩溃）。运行 --fix 写入。"
    else
        ok "Gradle 工具链路径已包含 JDK 21 / Zulu 25"
    fi
fi

# --- 其他 ---
if [[ -x "$repo_root/gradlew" ]]; then
    ok "gradlew 可执行"
else
    err "$repo_root/gradlew 不可执行：chmod +x gradlew"
fi

available_kb="$(df -Pk "$repo_root" 2>/dev/null | awk 'NR == 2 { print $4 }')"
if [[ -n "$available_kb" ]] && (( available_kb < 8 * 1024 * 1024 )); then
    warn "仓库所在磁盘仅剩 $(( available_kb / 1024 )) MiB；完整构建与 Gradle 缓存建议至少 8 GiB。"
fi

finish
