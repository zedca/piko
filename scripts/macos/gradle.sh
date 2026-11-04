#!/usr/bin/env bash
# 等价于 ./gradlew，但会先确认 macOS 构建环境并写入缺失的本机配置，在 PATH 上没有
# JDK 17+ 时自动选用检测到的 JDK 21/25。VS Code 的编译、测试、打包 DMG 任务都走这个入口，
# 避免从图形界面启动时读不到 shell 里的 JAVA_HOME。
#
# 额外参数原样透传给 Gradle。设 PIKO_SKIP_ENV_CHECK=1 可跳过环境检查。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env-lib.sh
source "$repo_root/scripts/macos/env-lib.sh"

if [[ "${PIKO_SKIP_ENV_CHECK:-0}" != "1" ]]; then
    "$repo_root/scripts/macos/check-env.sh" --fix --quiet
fi

if java_home="$(piko_gradle_java_home 2>/dev/null)"; then
    if [[ -n "$java_home" ]]; then
        export JAVA_HOME="$java_home"
    fi
else
    echo "找不到 JDK 17+，无法启动 Gradle。先运行 scripts/macos/check-env.sh 查看缺什么。" >&2
    exit 1
fi

exec ./gradlew "$@"
