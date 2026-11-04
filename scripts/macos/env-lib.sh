#!/usr/bin/env bash
# macOS 环境探测的公共函数，供 check-env.sh / dev-run.sh / deploy.sh 复用。
# 只做只读探测，不修改任何文件；写入配置由 check-env.sh --fix 负责。
# 兼容 macOS 自带的 bash 3.2：不使用关联数组与 ${var,,}。

# 规范化目录路径（解析符号链接）；目录不存在时原样返回。
piko_abspath() {
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# 列出本机可能的 JDK Home。去重后按优先级输出，调用方自行过滤版本。
piko_candidate_java_homes() {
    {
        [[ -n "${JAVA_HOME:-}" ]] && printf '%s\n' "$JAVA_HOME"

        # 系统注册表。Android Studio 自带的 JBR 不在这里，单独列出。
        local v
        for v in 25 21 17; do
            /usr/libexec/java_home -v "$v" 2>/dev/null || true
        done

        printf '%s\n' "$HOME"/Library/Java/JavaVirtualMachines/*/Contents/Home
        printf '%s\n' /Library/Java/JavaVirtualMachines/*/Contents/Home
        printf '%s\n' "/Applications/Android Studio.app/Contents/jbr/Contents/Home"

        # Homebrew（Apple Silicon / Intel）
        printf '%s\n' /opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home
        printf '%s\n' /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
        printf '%s\n' /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
        printf '%s\n' /opt/homebrew/opt/zulu@25/libexec/openjdk.jdk/Contents/Home
        printf '%s\n' /opt/homebrew/opt/zulu@21/libexec/openjdk.jdk/Contents/Home
        printf '%s\n' /usr/local/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home
        printf '%s\n' /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
    } | while IFS= read -r home; do
        [[ -n "$home" && -d "$home/bin" ]] && printf '%s\n' "$home"
    done | awk '!seen[$0]++'
}

# 从 java -version 的输出里取主版本号。
piko_java_major_from_output() {
    sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1
}

piko_java_major() {
    "$1/bin/java" -version 2>&1 | piko_java_major_from_output
}

piko_java_major_on_path() {
    java -version 2>&1 | piko_java_major_from_output
}

piko_java_is_zulu() {
    "$1/bin/java" -version 2>&1 | grep -qi zulu && return 0
    case "$1" in
        *[Zz]ulu*) return 0 ;;
    esac
    return 1
}

# jlink / jpackage 需要完整 JDK 的 jmods；Temurin 的 macOS 包不带。
# 标准 JDK 布局在 $JAVA_HOME/jmods，部分打包方式会放到 lib/jmods。
piko_java_has_jmods() {
    [[ -f "$1/jmods/java.base.jmod" || -f "$1/lib/jmods/java.base.jmod" ]]
}

# 按主版本号找 JDK；第二个参数为 true 时只接受 Azul Zulu。
piko_find_jdk() {
    local want="$1" require_zulu="${2:-false}" home major
    while IFS= read -r home; do
        major="$(piko_java_major "$home" 2>/dev/null || true)"
        [[ "$major" == "$want" ]] || continue
        if [[ "$require_zulu" == true ]] && ! piko_java_is_zulu "$home"; then
            continue
        fi
        printf '%s\n' "$home"
        return 0
    done < <(piko_candidate_java_homes)
    return 1
}

# 当前 PATH / JAVA_HOME 上的 java 若低于 17（Gradle 9 的最低要求），
# 输出一个可用的 JDK Home 供调用方 export JAVA_HOME；当前 java 可用时输出空并返回 0；
# 完全找不到可用 JDK 时返回 1。
piko_gradle_java_home() {
    local major home
    if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
        major="$(piko_java_major "$JAVA_HOME" 2>/dev/null || true)"
        [[ -n "$major" ]] && (( major >= 17 )) && return 0
    fi
    if command -v java >/dev/null 2>&1; then
        major="$(piko_java_major_on_path 2>/dev/null || true)"
        [[ -n "$major" ]] && (( major >= 17 )) && return 0
    fi
    if home="$(piko_find_jdk 21 false 2>/dev/null)"; then
        printf '%s\n' "$home"
        return 0
    fi
    if home="$(piko_find_jdk 25 false 2>/dev/null)"; then
        printf '%s\n' "$home"
        return 0
    fi
    return 1
}

# 找 Android SDK。输出规范化后的路径。
piko_find_android_sdk() {
    local dir
    for dir in "${PIKO_ANDROID_HOME:-}" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        piko_abspath "$dir"
        return 0
    done
    return 1
}

# 读 TOML 里 `key = "value"` 的 value。
piko_toml_version() {
    [[ -f "$1" ]] || return 1
    awk -F'"' -v k="$2" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" { print $2; exit }' "$1"
}

# pikpak-kotlin 的版本直接写在 build.gradle.kts 的 plugins 块里，没有 version catalog。
piko_sdk_kotlin_version() {
    [[ -f "$1/build.gradle.kts" ]] || return 1
    sed -n 's/.*kotlin("multiplatform") version "\([^"]*\)".*/\1/p' "$1/build.gradle.kts" | head -n 1
}

piko_sdk_agp_version() {
    [[ -f "$1/build.gradle.kts" ]] || return 1
    sed -n 's/.*id("com\.android\.kotlin\.multiplatform\.library") version "\([^"]*\)".*/\1/p' "$1/build.gradle.kts" | head -n 1
}

# 读 Gradle wrapper 的发行版版本号。
piko_gradle_version() {
    [[ -f "$1" ]] || return 1
    # BSD sed 的 BRE 不支持 \|，-bin/-all 分两条表达式。
    sed -n \
        -e 's/.*gradle-\([0-9][0-9.]*\)-bin\.zip.*/\1/p' \
        -e 's/.*gradle-\([0-9][0-9.]*\)-all\.zip.*/\1/p' \
        "$1" | head -n 1
}

# 读 properties 文件里某个键的值。
piko_property() {
    [[ -f "$1" ]] || return 1
    awk -v p="$2=" 'index($0, p) == 1 { sub(/^[^=]*=/, ""); print; exit }' "$1"
}
