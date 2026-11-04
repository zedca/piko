#!/usr/bin/env bash
# 编译并启动桌面开发版（数据目录 ~/.piko-dev）。
# 直接跑 :desktopApp:run 即可：compileKotlinDesktop 会在编译前通过本机 socket 让已运行的开发版退出，
# 不需要先手动结束进程。额外参数原样透传，例如 `dev-run.sh --debug-jvm` 等待 5005 调试器接入。
#
# 启动前会运行 check-env.sh --fix --quiet，自动补全缺失的本机配置；环境不完整时按提示安装
# （见 scripts/macos/check-env.sh --help）。设 PIKO_SKIP_ENV_CHECK=1 可跳过检查。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env-lib.sh
source "$repo_root/scripts/macos/env-lib.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "此脚本只用于 macOS 桌面开发版。" >&2
    exit 1
fi

# VS Code 的 preLaunchTask 有 5 秒看门狗：任务启动后 5 秒内没有输出匹配 beginsPattern 的行，
# 就会报 "has not exited and doesn't have a 'problemMatcher' defined"。编译和 Gradle 配置远慢于
# 5 秒，所以 --debug-jvm 时先立刻输出哨兵行（.vscode/tasks.json 的 beginsPattern 匹配它），
# 让任务在编译开始前就标记为运行中，等 JVM 打印 dt_socket 行后再由 endsPattern 放行调试器。
debug_port=5005
debug_jvm=false
for arg in "$@"; do
    if [[ "$arg" == "--debug-jvm" ]]; then
        debug_jvm=true
        echo "[piko-debug] 开始编译，JVM 稍后将在 $debug_port 等待调试器接入"
        break
    fi
done

# 上一次调试被中断（关窗口、点停止或调试器没附加成功）时，JVM 可能已经挂在 5005 等待调试器
# （JDWP suspend=y），此时它还没运行到能响应 compileKotlinDesktop 的 --dev-quit socket，Gradle
# 无法结束它。下一次启动会先完整编译一遍，再以 "Address already in use" 失败。因此在编译前
# 回收端口：只结束本仓库开发版的 JVM；如果是别的进程占用，立刻报错，不要白等一次完整编译。
if [[ "$debug_jvm" == true ]]; then
    stale_pids=""
    for pid in $(lsof -nP -t -iTCP:"$debug_port" -sTCP:LISTEN 2>/dev/null || true); do
        cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        [[ -n "$cmd" ]] || continue
        case "$cmd" in
            *dev.piko.desktop.MainKt*|*-Dpiko.dev-run=true*)
                printf '[piko-debug] 结束遗留的调试进程 PID %s\n' "$pid" >&2
                stale_pids="$stale_pids $pid"
                kill "$pid" 2>/dev/null || true
                ;;
            *)
                printf '端口 %s 已被其他进程占用（PID %s）：\n  %s\n' "$debug_port" "$pid" "$cmd" >&2
                printf '请先结束该进程；若确需换端口，请同时修改 .vscode/launch.json 与 dev-run.sh。\n' >&2
                exit 1
                ;;
        esac
    done
    if [[ -n "$stale_pids" ]]; then
        for _ in $(seq 1 20); do
            lsof -nP -t -iTCP:"$debug_port" -sTCP:LISTEN >/dev/null 2>&1 || break
            sleep 0.25
        done
        if lsof -nP -t -iTCP:"$debug_port" -sTCP:LISTEN >/dev/null 2>&1; then
            for pid in $stale_pids; do
                kill -9 "$pid" 2>/dev/null || true
            done
        fi
    fi
fi

if [[ "${PIKO_SKIP_ENV_CHECK:-0}" != "1" ]]; then
    "$repo_root/scripts/macos/check-env.sh" --fix --quiet
fi

# 从 Finder / VS Code 图形界面启动时 PATH 上可能只有旧版 java；换成检测到的 JDK 21/25。
if java_home="$(piko_gradle_java_home 2>/dev/null)"; then
    if [[ -n "$java_home" ]]; then
        export JAVA_HOME="$java_home"
    fi
else
    echo "找不到 JDK 17+，无法启动 Gradle。先运行 scripts/macos/check-env.sh 查看缺什么。" >&2
    exit 1
fi

exec ./gradlew :desktopApp:run "$@"
