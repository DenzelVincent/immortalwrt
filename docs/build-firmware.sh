#!/usr/bin/env bash
# OpenWrt 系源码本地编译助手（交互式；在 opde 容器内执行）
# 适用于 ImmortalWrt / PonWrt / LEDE 等 OpenWrt 系源码树
# 脚本放在容器 /home/opde/opde（宿主机 ~/opde-docker/opde），日志与备份同目录，不写进源码树
#
# 启动:
#   ./build-firmware.sh
#   依次输入源码目录与配置文件路径，再选择编译场景
#
# 交互输入:
#   源码目录      必须是包含 Makefile 与 rules.mk 的 OpenWrt 源码树
#   配置文件路径  相对源码根目录或绝对路径；回车留空表示自动选择源码根目录唯一的 *.config
#
# 编译场景:
#   菜单 1-6 选中后展示执行计划并自动跑完清理/配置/编译，无需再手动执行队列
#   菜单 7 查看最近一次执行队列，菜单 8 查看状态与日志
#   菜单 9 维护第三方包清单，feeds install 后、make defconfig 前自动克隆
#   清单位于 <脚本目录>/third-party-packages.conf，目标目录已有 Makefile 时跳过
#
# 日志:
#   目录固定为 <脚本目录>/build-logs，日志文件固定为 build.log
#   每次执行前清空日志目录，不保留历史日志
#   .config 备份另存于 <脚本目录>/config-backups
set -euo pipefail

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS=12
NO_BUILD=0
DRY_RUN=0
PRESET_FILE=""
SRC_ARG=""

is_src_tree() {
    [ -f "$1/Makefile" ] && [ -f "$1/rules.mk" ]
}

# Tab 补全在唯一匹配后会自动追加空格；不清理会让路径校验失败。顺手去掉开头的 ./
normalize_input() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    while [ "${s#./}" != "$s" ]; do
        s="${s#./}"
    done
    printf '%s' "$s"
}

# 日志目录固定，不提供覆盖入口
LOG_DIR="$SCRIPT_DIR/build-logs"
LOG_FILE="$LOG_DIR/build.log"
BACKUP_DIR="$SCRIPT_DIR/config-backups"

START=0
TS=""
TASK_LABEL=""

init_log() {
    local cfg
    case "$LOG_DIR" in
        "$SCRIPT_DIR"/build-logs) ;;
        *) die "日志目录必须固定为 $SCRIPT_DIR/build-logs" ;;
    esac
    rm -rf "$LOG_DIR" || die "无法清理日志目录: $LOG_DIR"
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" || die "无法创建日志目录: $LOG_DIR"
    : > "$LOG_FILE" || die "无法写入日志文件: $LOG_FILE"
    START=$SECONDS
    TS="$(date +%Y%m%d-%H%M%S)-$$"
    cfg="$(preset_default)"
    say "== $(date '+%Y-%m-%d %H:%M:%S') 开始: ${TASK_LABEL:-编译} =="
    say "源码: $SRC"
    say "配置: ${cfg:-未指定}"
    say "日志: $LOG_FILE"
}

preset_default() {
    local p found=()
    if [ -n "$PRESET_FILE" ]; then
        printf '%s\n' "$PRESET_FILE"
        return 0
    fi
    while IFS= read -r p; do
        found+=("$p")
    done < <(find "$SRC" -maxdepth 1 -type f -name '*.config' ! -name '.config' | sort)
    if [ "${#found[@]}" -eq 1 ]; then
        printf '%s\n' "${found[0]}"
    fi
    return 0
}

prompt_source() {
    local input
    while true; do
        if is_src_tree "$PWD"; then
            printf '源码目录 [%s]: ' "$PWD"
        else
            printf '源码目录: '
        fi
        IFS= read -er input || die "未输入源码目录"
        input="$(normalize_input "$input")"
        if [ -z "$input" ] && is_src_tree "$PWD"; then
            input="$PWD"
        fi
        if [ -n "$input" ] && [ -d "$input" ] && is_src_tree "$input"; then
            SRC_ARG="$input"
            return 0
        fi
        printf '无效: %s（需包含 Makefile 和 rules.mk）\n' "${input:-空}" >&2
    done
}

prompt_config() {
    local input p default
    default="$(preset_default)"
    while true; do
        if [ -n "$default" ]; then
            printf '配置文件路径 [%s]（回车使用默认，输入 - 表示不指定）: ' "$default"
        else
            printf '配置文件路径（相对源码目录或绝对路径，回车表示不指定）: '
        fi
        IFS= read -er input || return 0
        input="$(normalize_input "$input")"
        input="${input:-$default}"
        if [ "$input" = "-" ]; then
            PRESET_FILE=""
            return 0
        fi
        [ -n "$input" ] || return 0
        p="$input"
        case "$p" in
            /*|[A-Za-z]:/*) ;;
            *) p="$SRC/$p" ;;
        esac
        if [ -f "$p" ]; then
            PRESET_FILE="$input"
            return 0
        fi
        printf '无效: %s 不存在\n' "$p" >&2
        default=""
    done
}

setup_environment() {
    prompt_source
    SRC="$(cd "$SRC_ARG" && pwd)"
    case "$SCRIPT_DIR" in
        "$SRC"|"$SRC"/*)
            die "脚本目录不能位于源码树内: $SCRIPT_DIR（日志/备份会写进源码）；请放到 /home/opde/opde"
            ;;
    esac
    cd "$SRC"
    prompt_config
    apply_ccache_dir
}

get_config() {
    sed -n "s/^$1=//p" .config 2>/dev/null | tr -d '"' | head -1
}

# 设备符号形如 CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m=y
device_name() {
    local sym
    sym="$(grep -m1 '^CONFIG_TARGET_[A-Za-z0-9_]*_DEVICE_[A-Za-z0-9_]*=y$' .config 2>/dev/null || true)"
    [ -n "$sym" ] || return 0
    sym="${sym#CONFIG_TARGET_}"
    sym="${sym%=y}"
    printf '%s' "${sym#*_DEVICE_}"
}

config_set() {
    local key=$1 val=$2
    if grep -q "^${key}=" .config 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" .config
    else
        printf '%s=%s\n' "$key" "$val" >> .config
    fi
}

feeds_file() {
    if [ -f feeds.conf ]; then
        echo feeds.conf
    else
        echo feeds.conf.default
    fi
}

read_pins() {
    local f line type name url
    f="$(feeds_file)"
    [ -f "$f" ] || return 0
    while IFS= read -r line; do
        line="${line%%#*}"
        read -r type name url _ <<< "$line" || continue
        case "$type" in
            src-git|src-git-full) ;;
            *) continue ;;
        esac
        case "$url" in
            *^*) printf '%s %s\n' "$name" "${url##*^}" ;;
        esac
    done < "$f"
}

check_pins() {
    local name pin head bad=0
    while read -r name pin; do
        [ -d "feeds/$name" ] || continue
        head="$(git -C "feeds/$name" rev-parse HEAD 2>/dev/null || true)"
        if [ "$head" != "$pin" ]; then
            printf '固定提交不一致: feeds/%s HEAD=%s 期望=%s\n' "$name" "${head:-未知}" "$pin" >&2
            bad=1
        fi
    done < <(read_pins)
    return "$bad"
}

resolve_pkg() {
    local q p
    q="$(normalize_input "$1")"
    case "$q" in
        ''|*..*)
            printf '错误: 非法路径: %s\n' "$q" >&2
            return 1
            ;;
    esac
    if [ -d "$q" ] && [ -f "$q/Makefile" ]; then
        printf '%s\n' "${q%/}"
        return 0
    fi

    local matches=()
    while IFS= read -r p; do
        matches+=("$p")
    done < <(
        find -L package -maxdepth 5 -type f -name Makefile -path "*/$q/Makefile" 2>/dev/null |
            sed 's#/Makefile$##' | sort -u
    )

    if [ "${#matches[@]}" -eq 0 ]; then
        printf '错误: 找不到包: %s（可传包名或 package/... 路径）\n' "$q" >&2
        return 1
    fi
    if [ "${#matches[@]}" -gt 1 ]; then
        printf '错误: 包名 %s 匹配到多个路径，请改用完整路径:\n' "$q" >&2
        printf '  %s\n' "${matches[@]}" >&2
        return 1
    fi
    printf '%s\n' "${matches[0]}"
}

pkg_name() {
    local name
    name="$(sed -n 's/^PKG_NAME[[:space:]]*:=[[:space:]]*//p' "$1/Makefile" 2>/dev/null | head -1)"
    # LuCI 包常在 luci.mk 里按目录名推导 PKG_NAME，Makefile 本身不写
    if [ -z "$name" ]; then
        name="$(basename "$1")"
    fi
    printf '%s\n' "$name"
}

confirm() {
    [ "$DRY_RUN" = 1 ] && return 0
    local answer
    read -r -p "$1 [y/N] " answer || return 1
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_word() {
    local prompt=$1 want=$2 answer
    printf '%s' "$prompt"
    IFS= read -r answer || return 1
    [ "$answer" = "$want" ]
}

dedupe_list() {
    local -A seen=()
    local x
    for x in "$@"; do
        [ -n "$x" ] || continue
        if [ -n "${seen[$x]:-}" ]; then
            continue
        fi
        seen[$x]=1
        printf '%s\n' "$x"
    done
}

oneline() {
    printf '%s\n' "$1" | awk 'NF { if (sep) printf ", "; printf "%s", $0; sep=1 } END { print "" }'
}

say() {
    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s\n' "$*" | tee -a "$LOG_FILE"
    else
        printf '%s\n' "$*"
    fi
}

run() {
    printf '\n+ %s\n' "$*" | tee -a "${LOG_FILE:-/dev/null}"
    if [ "$DRY_RUN" = 1 ]; then
        return 0
    fi
    "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
}

finish() {
    local rc=$?
    local dur=$((SECONDS - START))
    if [ "$rc" -eq 0 ]; then
        say "== 完成: ${TASK_LABEL:-编译}，用时 ${dur}s =="
    elif [ "$rc" -eq 3 ]; then
        say "== 已取消: ${TASK_LABEL:-编译}，用时 ${dur}s =="
    else
        say "== 失败(rc=$rc): ${TASK_LABEL:-编译}，用时 ${dur}s =="
    fi
    if [ -n "${LOG_FILE:-}" ]; then
        say "日志: $LOG_FILE"
    fi
    if command -v ccache >/dev/null 2>&1 && [ -f .config ] && grep -q '^CONFIG_CCACHE=y' .config 2>/dev/null; then
        ccache -s 2>/dev/null | grep -E 'cache hit rate|cache size|max cache size' | sed 's/^/  /' | tee -a "${LOG_FILE:-/dev/null}" || true
    fi
    true
}

preflight() {
    [ "$(id -u)" -ne 0 ] || die "OpenWrt 不允许用 root 编译"
    command -v make >/dev/null 2>&1 || die "缺少 make"
    local avail
    avail="$(df -Pk . | awk 'NR==2 {print $4}')"
    if [ "${avail:-0}" -lt 20971520 ]; then
        say "警告: 当前分区可用空间不足 20 GiB，完整编译可能耗尽磁盘"
    fi
}

resolve_preset() {
    local p found=()
    p="$(normalize_input "${PRESET_FILE:-}")"
    if [ -n "$p" ]; then
        case "$p" in
            /*|[A-Za-z]:/*) ;;
            *) p="$SRC/$p" ;;
        esac
        if [ ! -f "$p" ]; then
            printf '错误: 找不到预设配置: %s\n' "$p" >&2
            return 1
        fi
        printf '%s\n' "$p"
        return 0
    fi
    while IFS= read -r p; do
        found+=("$p")
    done < <(find "$SRC" -maxdepth 1 -type f -name '*.config' ! -name '.config' | sort)
    case "${#found[@]}" in
        1) printf '%s\n' "${found[0]}" ;;
        0)
            printf '错误: 源码根目录没有 *.config 预设；请在启动时指定配置文件\n' >&2
            return 1
            ;;
        *)
            printf '错误: 源码根目录有多个 *.config，请在启动时指定配置文件:\n' >&2
            printf '  %s\n' "${found[@]}" >&2
            return 1
            ;;
    esac
}

ensure_config() {
    [ -f .config ] && return 0
    local p
    p="$(resolve_preset)"
    say "未找到 .config，套用预设 $(basename "$p")"
    run cp "$p" .config
}

warn_ccache() {
    grep -q '^CONFIG_CCACHE=y' .config 2>/dev/null ||
        say "提示: CONFIG_CCACHE 未启用，本次编译不会使用 ccache"
}

# rules.mk 只认 .config 里的 CONFIG_CCACHE_DIR，环境变量 CCACHE_DIR 会被它覆盖，
# 所以由 compose 声明 CCACHE_DIR，脚本负责写进 .config
apply_ccache_dir() {
    [ -n "${CCACHE_DIR:-}" ] || return 0
    [ -f .config ] || return 0
    if [ "$DRY_RUN" = 1 ]; then
        say "[预演] 将写入 CONFIG_DEVEL=y、CONFIG_CCACHE=y、CONFIG_CCACHE_DIR=$CCACHE_DIR"
        return 0
    fi
    say "ccache: CONFIG_CCACHE_DIR=$CCACHE_DIR"
    # CCACHE 在 Config-devel.in 里带 if DEVEL 依赖，不一起置 DEVEL=y 会被 defconfig 丢弃
    config_set CONFIG_DEVEL y
    config_set CONFIG_CCACHE y
    config_set CONFIG_CCACHE_DIR "\"$CCACHE_DIR\""
}

build_all() {
    if [ "$NO_BUILD" = 1 ]; then
        say "已跳过最终 make（选项：不生成完整镜像）"
        return 0
    fi
    say ""
    say "== 预下载源码 =="
    run make download -j"$JOBS"
    run make -j"$JOBS" V=s
}

status() {
    printf '源码: %s\n' "$SRC"
    printf '日志: %s\n' "$LOG_FILE"
    printf '分支: %s\n' "$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 未知)"
    printf '提交: %s\n' "$(git -C "$SRC" log -1 --format='%h %s' 2>/dev/null || echo 未知)"
    git -C "$SRC" status -sb 2>/dev/null | head -6 || true

    if [ -f .config ]; then
        printf '平台: %s/%s\n' "$(get_config CONFIG_TARGET_BOARD)" "$(get_config CONFIG_TARGET_SUBTARGET)"
        printf '设备: %s\n' "$(device_name)"
        if grep -q '^CONFIG_CCACHE=y' .config; then
            printf 'ccache: 已启用\n'
        else
            printf 'ccache: 未启用\n'
        fi
    else
        printf '配置: .config 不存在\n'
    fi

    printf 'feeds:\n'
    local f
    for f in feeds/*/; do
        [ -d "$f/.git" ] || continue
        printf '  %-14s %s\n' "$(basename "$f")" "$(git -C "$f" log -1 --format=%h 2>/dev/null || echo 未知)"
    done

    printf '固定提交检查:\n'
    if check_pins; then
        printf '  全部一致\n'
    fi

    if command -v ccache >/dev/null 2>&1; then
        ccache -s 2>/dev/null | grep -E 'cache hit rate|cache size|max cache size' | sed 's/^/  /' || true
    fi
    df -h "$SRC" | tail -1
}

# ---------------- 任务队列 ----------------

QTYPE=()
QDATA=()
QMODE=()
MENU_KEY=""
APP_PKGS=()
APP_NAMES=()
CLEAN_PKGS=()
COLLECTED=()
AUTO_ENABLE=1

q_has() {
    local t=$1 i
    for i in "${!QTYPE[@]}"; do
        if [ "${QTYPE[$i]}" = "$t" ]; then
            return 0
        fi
    done
    return 1
}

q_idx() {
    local t=$1 i
    for i in "${!QTYPE[@]}"; do
        if [ "${QTYPE[$i]}" = "$t" ]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}

q_summary() {
    if [ "${#QTYPE[@]}" -eq 0 ]; then
        printf '空'
        return 0
    fi
    local parts=() i
    for i in "${!QTYPE[@]}"; do
        case "${QTYPE[$i]}" in
            heavy) parts+=("清理") ;;
            feeds) parts+=("feeds") ;;
            config) parts+=("config") ;;
            pkgclean) parts+=("包清理") ;;
            kernel) parts+=("内核") ;;
            app) parts+=("APP") ;;
        esac
    done
    local IFS=', '
    printf '%s 步: %s' "${#QTYPE[@]}" "${parts[*]}"
}

q_ordered() {
    local t i
    for t in heavy feeds config pkgclean kernel app; do
        for i in "${!QTYPE[@]}"; do
            if [ "${QTYPE[$i]}" = "$t" ]; then
                printf '%s\n' "$i"
            fi
        done
    done
}

q_add_app() {
    local mode=$1
    shift
    local data i
    data="$(printf '%s\n' "$@")"
    if i="$(q_idx app)"; then
        if [ -n "${QDATA[$i]}" ]; then
            QDATA[$i]="${QDATA[$i]}"$'\n'"$data"
        else
            QDATA[$i]="$data"
        fi
        if [ "$mode" = clean ]; then
            QMODE[$i]=clean
        fi
        printf '已合并到现有 APP 任务（%s）。\n' "${QMODE[$i]}"
    else
        QTYPE+=(app)
        QDATA+=("$data")
        QMODE+=("$mode")
    fi
}

q_add_kernel() {
    local mode=$1 i
    if i="$(q_idx kernel)"; then
        if [ "$mode" = standard ] && [ "${QDATA[$i]}" != standard ]; then
            QDATA[$i]=standard
            printf '内核任务已升级为标准模式（会清理内核构建）。\n'
        elif [ "${QDATA[$i]}" = standard ]; then
            printf '内核任务已是标准模式。\n'
        else
            printf '已有内核任务，保持当前模式。\n'
        fi
    else
        QTYPE+=(kernel)
        QDATA+=("$mode")
        QMODE+=("")
        printf '已加入内核任务: %s\n' "$mode"
    fi
}

q_add_feeds() {
    if q_has feeds; then
        printf 'feeds 任务已在队列中。\n'
        return 0
    fi
    QTYPE+=(feeds)
    QDATA+=("")
    QMODE+=("")
    printf '已加入 feeds 更新。\n'
}

q_add_config() {
    local mode=$1 i
    if i="$(q_idx config)"; then
        printf '已替换 .config 任务: %s → %s\n' "${QDATA[$i]}" "$mode"
        QDATA[$i]="$mode"
    else
        QTYPE+=(config)
        QDATA+=("$mode")
        QMODE+=("")
        printf '已加入 .config 任务: %s\n' "$(config_desc "$mode")"
    fi
}

q_add_pkgclean() {
    local data i
    data="$(printf '%s\n' "$@")"
    if i="$(q_idx pkgclean)"; then
        QDATA[$i]="${QDATA[$i]}"$'\n'"$data"
    else
        QTYPE+=(pkgclean)
        QDATA+=("$data")
        QMODE+=("")
    fi
    printf '已加入包清理任务。\n'
}

q_heavy_rank() {
    case "$1" in
        clean) printf '1\n' ;;
        dirclean) printf '2\n' ;;
        distclean) printf '3\n' ;;
        *) printf '0\n' ;;
    esac
}

q_add_heavy() {
    local level=$1 rank i old oldrank
    rank="$(q_heavy_rank "$level")"
    if i="$(q_idx heavy)"; then
        old="${QDATA[$i]}"
        oldrank="$(q_heavy_rank "$old")"
        if [ "$rank" -gt "$oldrank" ]; then
            QDATA[$i]=$level
            printf '已升级清理任务: make %s → make %s\n' "$old" "$level"
        else
            printf '已有更强或相同的清理任务（make %s），忽略 make %s。\n' "$old" "$level"
            return 0
        fi
    else
        QTYPE+=(heavy)
        QDATA+=("$level")
        QMODE+=("")
        printf '已加入清理任务: make %s\n' "$level"
    fi
}

q_clear() {
    QTYPE=()
    QDATA=()
    QMODE=()
}

eff_level() {
    local i
    if i="$(q_idx heavy)"; then
        q_heavy_rank "${QDATA[$i]}"
    else
        printf '0\n'
    fi
}

# ---------------- 交互界面 ----------------

read_menu() {
    MENU_KEY=""
    IFS= read -rsn1 MENU_KEY || exit 0
    printf '%s\n' "$MENU_KEY"
}

ask_yn() {
    local prompt=$1 def=$2 hint ans
    if [ "$def" = y ]; then
        hint='[Y/n]'
    else
        hint='[y/N]'
    fi
    IFS= read -rp "$prompt $hint " ans || return 1
    ans="${ans:-$def}"
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

ask_line() {
    local ans
    IFS= read -erp "$1" ans || return 1
    printf '%s' "${ans:-$2}"
}

config_desc() {
    case "$1" in
        preset)
            if [ -n "$PRESET_FILE" ]; then
                printf '套用预设 %s' "$PRESET_FILE"
            else
                printf '套用预设（自动选择源码根目录唯一的 *.config）'
            fi
            ;;
        defconfig) printf '重新 make defconfig' ;;
        menuconfig) printf 'make menuconfig（退出后继续）' ;;
        *) printf '%s' "$1" ;;
    esac
}

build_desc() {
    if [ "$NO_BUILD" = 1 ]; then
        printf '跳过最终 make（不生成完整镜像）'
    else
        printf 'make download -j%s → make -j%s V=s' "$JOBS" "$JOBS"
    fi
}

ui_require_tty() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '本脚本只有交互模式，请在终端中运行（容器内使用 docker exec -it）。\n' >&2
        exit 1
    fi
}

ui_header() {
    local br cm dev cc pins avail_kb avail_gb cfg
    br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 未知)"
    cm="$(git log -1 --format='%h %s' 2>/dev/null || echo 未知)"
    dev="$(device_name)"
    if [ -z "$dev" ]; then
        dev="未配置"
    fi
    if [ -f .config ] && grep -q '^CONFIG_CCACHE=y' .config 2>/dev/null; then
        cc="已启用"
    else
        cc="未启用"
    fi
    if [ -d feeds ] && [ -n "$(ls -A feeds 2>/dev/null)" ]; then
        if check_pins >/dev/null 2>&1; then
            pins="一致"
        else
            pins="不一致"
        fi
    else
        pins="未安装"
    fi
    avail_kb="$(df -Pk . | awk 'NR==2 {print $4}')"
    avail_gb=$(( ${avail_kb:-0} / 1048576 ))
    cfg="$(preset_default)"

    printf '\nOpenWrt 本地编译\n'
    printf '源码 %s\n' "$SRC"
    if [ -n "$cfg" ]; then
        printf '配置 %s\n' "$cfg"
    else
        printf '配置 未指定\n'
    fi
    printf '源码版本 %s @ %s\n' "$br" "$cm"
    printf '平台 %s/%s  |  设备 %s  |  ccache %s  |  磁盘 %sG  |  feeds %s\n' \
        "$(get_config CONFIG_TARGET_BOARD)" "$(get_config CONFIG_TARGET_SUBTARGET)" \
        "$dev" "$cc" "$avail_gb" "$pins"
    printf '最近队列: %s\n' "$(q_summary)"
    printf '────────────────────────────────────────────\n'
}

collect_inputs() {
    local label=$1 q p n
    COLLECTED=()
    while true; do
        printf '%s %d: ' "$label" "$(( ${#COLLECTED[@]} + 1 ))"
        IFS= read -er q || return 1
        case "${q:-}" in
            '') break ;;
            b|B) return 2 ;;
        esac
        if p="$(resolve_pkg "$q")"; then
            n="$(pkg_name "$p")"
            printf '  → %s (PKG_NAME=%s)\n' "$p" "$n"
            COLLECTED+=("$q")
        else
            if ask_yn "  解析失败，仍然加入（执行时重试）" n; then
                COLLECTED+=("$q")
            fi
        fi
    done
    return 0
}

run_queue() {
    printf '\n'
    print_plan
    printf '\n'
    ui_execute
}

queue_fresh() {
    local p
    if ! p="$(resolve_preset)"; then
        printf '全新编译需要可用配置：请重新启动脚本并指定配置文件。\n' >&2
        return 0
    fi
    printf '使用配置: %s\n' "$p"
    q_clear
    q_add_heavy distclean
    q_add_feeds
    q_add_config preset
    run_queue
}

ui_flow_fresh() {
    printf '\n== 执行全新编译流程 ==\n'
    printf '动作: make distclean → feeds update/install → 套用配置 → 全量编译\n'
    queue_fresh
}

ui_flow_app() {
    printf '\n== 新增、修改 APP 后编译 ==\n'
    printf '动作: 清理所选包 → 编译所选包 → 全量编译\n'
    printf '输入包名或路径，空行结束，b 返回\n'
    if ! collect_inputs "包名/路径"; then
        return 0
    fi
    if [ "${#COLLECTED[@]}" -eq 0 ]; then
        printf '未添加。\n'
        return 0
    fi
    q_clear
    q_add_app clean "${COLLECTED[@]}"
    run_queue
}

ui_flow_kernel() {
    printf '\n== 修改内核后编译 ==\n'
    printf '动作: 清理内核 → 全量编译\n'
    printf ' 1) 标准：target/linux/clean 后全量编译（改了补丁/DTS，推荐）\n'
    printf ' 2) 快速：跳过内核清理，直接全量增量编译（仅改 build_dir 内源码）\n'
    printf ' b) 返回\n选择: '
    read_menu
    case "$MENU_KEY" in
        1) q_clear; q_add_kernel standard ;;
        2) q_clear; q_add_kernel fast ;;
        *) return 0 ;;
    esac
    run_queue
}

ui_flow_feeds() {
    printf '\n== 新增、修改 feeds 后编译 ==\n'
    printf '动作: feeds update -a → install -a → defconfig → 全量编译\n'
    q_clear
    q_add_feeds
    run_queue
}

ui_flow_config() {
    local p
    printf '\n== 修改 config 后编译 ==\n'
    printf '动作: 备份 .config → 套用/defconfig/menuconfig → 全量编译\n'
    printf ' 1) 套用配置文件 %s\n' "${PRESET_FILE:-（自动选择唯一的 *.config）}"
    printf ' 2) 基于现有 .config 重新 defconfig（补齐/清理依赖）\n'
    printf ' 3) 打开 menuconfig 手动调整，退出后继续\n'
    printf ' b) 返回\n选择: '
    read_menu
    case "$MENU_KEY" in
        1)
            if ! p="$(resolve_preset)"; then
                return 0
            fi
            q_clear
            q_add_config preset
            ;;
        2)
            q_clear
            q_add_config defconfig
            ;;
        3)
            q_clear
            q_add_config menuconfig
            ;;
        *) return 0 ;;
    esac
    run_queue
}

ui_flow_clean() {
    printf '\n== 强制清理 ==\n'
    printf '动作: 自选清理级别 → 清理 → 全量编译\n'
    printf ' 1) 清理指定包后编译（只清这些包的 build_dir）\n'
    printf ' 2) 清理内核构建后编译（target/linux/clean）\n'
    printf ' 3) make clean 后编译（删除 bin/build_dir/staging_dir）\n'
    printf ' 4) make dirclean 后编译（额外删除 toolchain/host/tmp）\n'
    printf ' 5) make distclean 后编译（等同全新编译）\n'
    printf ' b) 返回\n选择: '
    read_menu
    case "$MENU_KEY" in
        1)
            printf '输入要清理的包名或路径，空行结束，b 返回\n'
            if ! collect_inputs "包名/路径"; then
                return 0
            fi
            if [ "${#COLLECTED[@]}" -eq 0 ]; then
                printf '未添加。\n'
                return 0
            fi
            q_clear
            q_add_pkgclean "${COLLECTED[@]}"
            ;;
        2) q_clear; q_add_kernel standard ;;
        3) q_clear; q_add_heavy clean ;;
        4) q_clear; q_add_heavy dirclean ;;
        5) queue_fresh; return 0 ;;
        *) return 0 ;;
    esac
    run_queue
}

ui_options() {
    local ans
    while true; do
        printf '\n== 选项 ==\n'
        printf '输入编号修改对应项，b 返回（并发数回车确认，其余直接切换）\n'
        printf '1) 并发数: %s\n' "$JOBS"
        if [ "$NO_BUILD" = 1 ]; then
            printf '2) 最终生成完整镜像: 否\n'
        else
            printf '2) 最终生成完整镜像: 是\n'
        fi
        if [ "$AUTO_ENABLE" = 1 ]; then
            printf '3) APP 未选中时自动写入 .config: 是\n'
        else
            printf '3) APP 未选中时自动写入 .config: 否\n'
        fi
        if [ "$DRY_RUN" = 1 ]; then
            printf '4) 预演（只打印命令）: 是\n'
        else
            printf '4) 预演（只打印命令）: 否\n'
        fi
        printf 'b) 返回\n选择: '
        read_menu
        case "$MENU_KEY" in
            1)
                if ! ans="$(ask_line "并发数 [${JOBS}]: " "$JOBS")"; then
                    return 0
                fi
                case "$ans" in
                    ''|*[!0-9]*) printf '必须是正整数。\n' ;;
                    *) if [ "$ans" -gt 0 ]; then JOBS=$ans; else printf '必须大于 0。\n'; fi ;;
                esac
                ;;
            2) if [ "$NO_BUILD" = 1 ]; then NO_BUILD=0; else NO_BUILD=1; fi ;;
            3) if [ "$AUTO_ENABLE" = 1 ]; then AUTO_ENABLE=0; else AUTO_ENABLE=1; fi ;;
            4) if [ "$DRY_RUN" = 1 ]; then DRY_RUN=0; else DRY_RUN=1; fi ;;
            b|B|q|Q) return 0 ;;
        esac
    done
}

ui_third_party() {
    local f i target url ref
    while true; do
        f="$(third_party_file)"
        i=0
        printf '\n== 第三方包 ==\n'
        printf '清单: %s\n' "$f"
        if [ -f "$f" ] && [ -n "$(read_third_party)" ]; then
            while read -r target url ref; do
                i=$((i + 1))
                if [ -f "$target/Makefile" ]; then
                    printf ' %d) %s ← %s%s [已就位]\n' "$i" "$target" "$url" "${ref:+ ($ref)}"
                else
                    printf ' %d) %s ← %s%s\n' "$i" "$target" "$url" "${ref:+ ($ref)}"
                fi
            done < <(read_third_party)
        else
            printf '  （空）\n'
        fi
        printf '执行时机: feeds install 之后、make defconfig 之前；目标已有 Makefile 时跳过\n'
        printf ' 1) 添加  2) 删除  b) 返回\n选择: '
        read_menu
        case "$MENU_KEY" in
            1) third_party_add ;;
            2) third_party_delete ;;
            b|B|q|Q) return 0 ;;
        esac
    done
}

print_plan() {
    local n=0 lvl i t data appclean=0 tp
    lvl="$(eff_level)"

    if q_has app; then
        i="$(q_idx app)"
        if [ "${QMODE[$i]}" = clean ]; then
            appclean=1
        fi
    fi

    printf '执行计划:\n'

    while IFS= read -r i; do
        [ -n "$i" ] || continue
        t="${QTYPE[$i]}"
        data="${QDATA[$i]}"
        n=$((n + 1))
        case "$t" in
            heavy)
                printf '  %d) [清理] make %s' "$n" "$data"
                if [ "$data" = distclean ]; then
                    printf '（需输入 DISTCLEAN）'
                elif [ "$data" = dirclean ]; then
                    printf '（需输入 yes）'
                fi
                printf '\n'
                ;;
            feeds)
                printf '  %d) [feeds] update -a / install -a（已有 .config 时 defconfig）\n' "$n"
                ;;
            config)
                printf '  %d) [config] %s\n' "$n" "$(config_desc "$data")"
                ;;
            pkgclean)
                if [ "$lvl" -ge 1 ]; then
                    printf '  %d) [跳过] 包清理（被整体清理覆盖）\n' "$n"
                else
                    if [ "$appclean" = 1 ]; then
                        printf '  %d) [清理] 包: %s + APP 自动清理\n' "$n" "$(oneline "$data")"
                    else
                        printf '  %d) [清理] 包: %s\n' "$n" "$(oneline "$data")"
                    fi
                fi
                ;;
            kernel)
                if [ "$data" = fast ]; then
                    printf '  %d) [内核] 快速（不清理）\n' "$n"
                elif [ "$lvl" -ge 1 ]; then
                    printf '  %d) [跳过] 内核清理（被整体清理覆盖）\n' "$n"
                else
                    printf '  %d) [内核] target/linux/clean\n' "$n"
                fi
                ;;
            app)
                if [ "${QMODE[$i]}" = clean ] && [ "$lvl" -eq 0 ]; then
                    printf '  %d) [APP] %s（clean + compile）\n' "$n" "$(oneline "$data")"
                elif [ "${QMODE[$i]}" = clean ]; then
                    printf '  %d) [APP] %s（compile，清理被整体清理覆盖）\n' "$n" "$(oneline "$data")"
                else
                    printf '  %d) [APP] %s（增量 compile）\n' "$n" "$(oneline "$data")"
                fi
                ;;
        esac
    done < <(q_ordered)

    tp="$(read_third_party | wc -l | tr -d ' ')"
    if [ "$tp" -gt 0 ]; then
        printf '  - [第三方包] %s 项（feeds 后按清单检查/克隆）\n' "$tp"
    fi
    printf '  - [编译] %s\n' "$(build_desc)"
    printf '选项: 并发 %s | APP自动选中 %s | 预演 %s\n' \
        "$JOBS" \
        "$(if [ "$AUTO_ENABLE" = 1 ]; then printf '是'; else printf '否'; fi)" \
        "$(if [ "$DRY_RUN" = 1 ]; then printf '是'; else printf '否'; fi)"
}

ui_queue_view() {
    printf '\n== 执行队列 ==\n'
    if [ "${#QTYPE[@]}" -eq 0 ]; then
        printf '队列为空（选择 1-6 会自动执行对应流程）\n'
    else
        print_plan
        printf '\n（最近一次执行计划，仅查看）\n'
    fi
    printf 'e 修改选项 | 回车返回: '
    read_menu
    if [ "$MENU_KEY" = e ] || [ "$MENU_KEY" = E ]; then
        ui_options
    fi
}

ui_status_logs() {
    printf '\n== 状态 ==\n'
    status

    printf '\n日志末尾 50 行: %s\n' "$LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        tail -n 50 "$LOG_FILE"
    else
        printf '  （尚未生成日志）\n'
    fi
    printf '\n回车返回'
    read_menu >/dev/null || true
}

ui_failure() {
    local rc=$1
    printf '\n执行失败（rc=%s）\n' "$rc"
    if [ -n "${LOG_FILE:-}" ]; then
        printf '日志: %s\n' "$LOG_FILE"
    fi
    while true; do
        printf '1) 查看日志末尾 50 行\n2) 返回主菜单\n0) 退出\n选择: '
        read_menu
        case "$MENU_KEY" in
            1)
                if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
                    tail -n 50 "$LOG_FILE"
                fi
                printf '\n回车返回'
                read_menu >/dev/null || true
                ;;
            2|b|B) return 0 ;;
            0|q|Q) exit 0 ;;
        esac
    done
}

disp_width() {
    local plain="${1//[[:ascii:]]/}"
    printf '%s\n' "$(( ${#1} + ${#plain} ))"
}

menu_item() {
    local label=$1 desc=$2 pad
    pad=$(( 30 - $(disp_width "$label") ))
    [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s%s\n' "$label" "$pad" '' "$desc"
}

ui_main() {
    while true; do
        ui_header
        menu_item '1、执行全新编译流程' 'make distclean → 更新 feeds → 套用配置 → 全量编译'
        menu_item '2、新增、修改 APP 后编译' '清理所选包 → 编译所选包 → 全量编译'
        menu_item '3、修改内核后编译' '清理内核 → 全量编译（可选快速模式）'
        menu_item '4、新增、修改 feeds 后编译' 'feeds update/install → defconfig → 全量编译'
        menu_item '5、修改 config 后编译' '备份 .config → 套用/defconfig/menuconfig → 全量编译'
        menu_item '6、强制清理' '选包/内核/clean/dirclean/distclean → 清理后全量编译'
        menu_item '7、查看执行队列' '查看最近一次执行计划；可修改并发/预演等选项'
        menu_item '8、查看当前编译状态和日志' '源码/配置/feeds/磁盘状态 + 日志末尾'
        menu_item '9、第三方包' '维护 feeds 安装后要克隆的第三方包清单'
        printf '0、退出\n'
        printf '选择: '
        read_menu
        case "$MENU_KEY" in
            1) ui_flow_fresh ;;
            2) ui_flow_app ;;
            3) ui_flow_kernel ;;
            4) ui_flow_feeds ;;
            5) ui_flow_config ;;
            6) ui_flow_clean ;;
            7) ui_queue_view ;;
            8) ui_status_logs ;;
            9) ui_third_party ;;
            0|q|Q) return 0 ;;
        esac
    done
}

# ---------------- 队列执行 ----------------

resolve_app_inputs() {
    local data=$1 q p
    local -a paths=()
    APP_PKGS=()
    APP_NAMES=()
    while IFS= read -r q; do
        [ -n "$q" ] || continue
        if ! p="$(resolve_pkg "$q" 2>&1)"; then
            say "$p"
            return 1
        fi
        paths+=("$p")
    done <<< "$data"
    mapfile -t paths < <(dedupe_list "${paths[@]}")
    for p in "${paths[@]}"; do
        APP_PKGS+=("$p")
        APP_NAMES+=("$(pkg_name "$p")")
    done
    say "解析 APP:"
    local i
    for i in "${!APP_PKGS[@]}"; do
        say "  ${APP_PKGS[$i]} (PKG_NAME=${APP_NAMES[$i]})"
    done
}

resolve_clean_inputs() {
    local data=$1 q p
    local -a paths=()
    CLEAN_PKGS=()
    while IFS= read -r q; do
        [ -n "$q" ] || continue
        if ! p="$(resolve_pkg "$q" 2>&1)"; then
            say "$p"
            return 1
        fi
        paths+=("$p")
    done <<< "$data"
    mapfile -t paths < <(dedupe_list "${paths[@]}")
    for p in "${paths[@]}"; do
        CLEAN_PKGS+=("$p")
    done
    say "解析清理包:"
    for p in "${CLEAN_PKGS[@]}"; do
        say "  $p"
    done
}

enable_app_packages() {
    local n
    local -a missing=()
    for n in "${APP_NAMES[@]}"; do
        if ! grep -q "^CONFIG_PACKAGE_${n}=y" .config 2>/dev/null; then
            missing+=("$n")
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        say "APP 包均已选中。"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        say "[预演] 将写入配置: ${missing[*]}"
        return 0
    fi
    for n in "${missing[@]}"; do
        config_set "CONFIG_PACKAGE_${n}" y
    done
    run make defconfig
    say "已写入配置: ${missing[*]}"
}

confirm_heavy() {
    local what=$1
    case "$what" in
        distclean)
            say "make distclean 将删除: bin build_dir staging_dir tmp .config* dl feeds package/feeds target/linux/feeds logs"
            if [ "$DRY_RUN" = 1 ]; then
                say "[预演] 跳过确认"
                return 0
            fi
            if ! confirm_word "确认请输入 DISTCLEAN: " DISTCLEAN; then
                say "已取消"
                exit 3
            fi
            ;;
        dirclean)
            say "make dirclean 将删除: bin build_dir staging_dir tmp toolchain/host 等"
            if [ "$DRY_RUN" = 1 ]; then
                say "[预演] 跳过确认"
                return 0
            fi
            if ! confirm_word "确认请输入 yes: " yes; then
                say "已取消"
                exit 3
            fi
            ;;
        clean)
            if ! confirm "make clean 将删除 bin、build_dir、staging_dir，继续？"; then
                say "已取消"
                exit 3
            fi
            ;;
    esac
}

feeds_update_task() {
    local name pin head mismatch=0
    while read -r name pin; do
        [ -d "feeds/$name" ] || continue
        head="$(git -C "feeds/$name" rev-parse HEAD 2>/dev/null || true)"
        if [ "$head" != "$pin" ]; then
            say "固定提交不一致: feeds/$name HEAD=${head:-未知} 期望=$pin"
            mismatch=1
        fi
    done < <(read_pins)

    if [ "$mismatch" = 1 ]; then
        if [ "$DRY_RUN" = 1 ]; then
            say "[预演] 固定提交不一致，将询问是否删除对应 feed"
        elif ask_yn "删除不一致的 feed 并按固定提交重拉" n; then
            while read -r name pin; do
                [ -d "feeds/$name" ] || continue
                head="$(git -C "feeds/$name" rev-parse HEAD 2>/dev/null || true)"
                if [ "$head" != "$pin" ]; then
                    say "删除 feeds/$name"
                    run rm -rf "feeds/$name"
                fi
            done < <(read_pins)
        else
            say "已取消"
            exit 3
        fi
    fi

    run ./scripts/feeds update -a
    run ./scripts/feeds install -a
    if [ -f .config ]; then
        run make defconfig
    fi
    if [ "$DRY_RUN" != 1 ] && ! check_pins; then
        die "feeds 更新后仍有固定提交不一致"
    fi
}

config_task() {
    local mode=$1 p
    case "$mode" in
        preset)
            p="$(resolve_preset)"
            run cp "$p" .config
            run make defconfig
            ;;
        defconfig)
            ensure_config
            run make defconfig
            ;;
        menuconfig)
            ensure_config
            run make menuconfig
            ;;
        *)
            die "未知 .config 操作: $mode"
            ;;
    esac
}

# ---------------- 第三方包 ----------------

# 清单与脚本同目录，每行「目标目录 仓库地址 [分支/标签]」；空行和 # 注释忽略
third_party_file() {
    printf '%s/third-party-packages.conf\n' "$SCRIPT_DIR"
}

read_third_party() {
    local f
    f="$(third_party_file)"
    [ -f "$f" ] || return 0
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        NF >= 2 { if ($3 != "") print $1, $2, $3; else print $1, $2 }
    ' "$f"
}

third_party_valid_target() {
    case "$1" in
        package/*) ;;
        *) printf '目标目录必须以 package/ 开头: %s\n' "$1" >&2; return 1 ;;
    esac
    case "/$1/" in
        */../*|*/./*) printf '目标目录不能包含 . 或 .. 路径段: %s\n' "$1" >&2; return 1 ;;
    esac
    return 0
}

third_party_valid_url() {
    case "$1" in
        http://*|https://*|git://*|ssh://*|file://*|git@*) return 0 ;;
    esac
    printf '仓库地址需以 http://、https://、git://、ssh://、file:// 或 git@ 开头: %s\n' "$1" >&2
    return 1
}

# 在 feeds install 之后、make defconfig 之前执行：缺失就克隆，目录已有 Makefile 则跳过
third_party_ensure() {
    local entries target url ref
    entries="$(read_third_party)"
    [ -n "$entries" ] || return 0
    say ""
    say "== 第三方包 =="
    while read -r target url ref; do
        if ! third_party_valid_target "$target" || ! third_party_valid_url "$url"; then
            die "清单条目无效，请用主菜单 9 修正"
        fi
        if [ -f "$target/Makefile" ]; then
            say "已就位: $target"
            continue
        fi
        if [ -e "$target" ]; then
            die "第三方包目录已存在但没有 Makefile: $target（请检查后手动删除）"
        fi
        if [ -n "$ref" ]; then
            run git clone --depth 1 --branch="$ref" "$url" "$target"
        else
            run git clone --depth 1 "$url" "$target"
        fi
        if [ "$DRY_RUN" = 1 ]; then
            continue
        fi
        if [ ! -f "$target/Makefile" ]; then
            die "克隆后未找到 $target/Makefile，请检查仓库地址与分支"
        fi
        say "已克隆: $target"
    done <<< "$entries"
}

third_party_add() {
    local f target url ref
    f="$(third_party_file)"
    printf '目标目录相对源码根，须以 package/ 开头（如 package/luci-app-airoha-npu）\n'
    target="$(ask_line '目标目录: ' '')" || return 0
    target="$(normalize_input "$target")"
    while [ "${target%/}" != "$target" ]; do
        target="${target%/}"
    done
    if [ -z "$target" ]; then
        printf '已取消。\n'
        return 0
    fi
    if ! third_party_valid_target "$target"; then
        return 0
    fi
    url="$(ask_line '仓库地址: ' '')" || return 0
    if ! third_party_valid_url "$url"; then
        return 0
    fi
    ref="$(ask_line '分支/标签（回车用默认分支）: ' '')" || return 0
    case "$ref" in
        -*) printf '分支/标签不能以 - 开头。\n'; return 0 ;;
    esac
    if [ -f "$f" ] && awk -v t="$target" '$1 == t { found = 1 } END { exit !found }' "$f"; then
        printf '清单里已有该目标目录，先删除再添加。\n'
        return 0
    fi
    if [ ! -f "$f" ]; then
        printf '%s\n' \
            '# 第三方包清单：每行「目标目录 仓库地址 [分支/标签]」' \
            '# feeds 安装后、make defconfig 前自动克隆；目录已有 Makefile 时跳过' > "$f" ||
            die "无法写入 $f"
    fi
    if [ -n "$ref" ]; then
        printf '%s %s %s\n' "$target" "$url" "$ref" >> "$f"
    else
        printf '%s %s\n' "$target" "$url" >> "$f"
    fi
    printf '已添加: %s ← %s%s\n' "$target" "$url" "${ref:+ ($ref)}"
}

third_party_delete() {
    local f n i target
    local -a targets=()
    f="$(third_party_file)"
    mapfile -t targets < <(read_third_party | awk '{ print $1 }')
    if [ "${#targets[@]}" -eq 0 ]; then
        printf '清单为空。\n'
        return 0
    fi
    for i in "${!targets[@]}"; do
        printf ' %d) %s\n' "$((i + 1))" "${targets[$i]}"
    done
    n="$(ask_line '要删除的编号（回车取消）: ' '')" || return 0
    case "$n" in
        ''|*[!0-9]*) printf '已取消。\n'; return 0 ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "${#targets[@]}" ]; then
        printf '编号超出范围。\n'
        return 0
    fi
    target="${targets[$((n - 1))]}"
    awk -v t="$target" '!/^[[:space:]]*#/ && $1 == t { next } { print }' "$f" > "$f.tmp" ||
        die "无法写入 $f.tmp"
    mv "$f.tmp" "$f" || die "无法更新 $f"
    printf '已删除: %s\n' "$target"
}

execute_queue_body() {
    preflight
    say "== 队列开始: $(q_summary) =="
    local lvl i ki ai app_mode="" p n
    lvl="$(eff_level)"

    for i in "${!QTYPE[@]}"; do
        say "  - ${QTYPE[$i]}: $(oneline "${QDATA[$i]}")"
    done
    say "并发=$JOBS 完整镜像=$(if [ "$NO_BUILD" = 1 ]; then printf '否'; else printf '是'; fi) 预演=$(if [ "$DRY_RUN" = 1 ]; then printf '是'; else printf '否'; fi)"

    if [ -f .config ]; then
        if [ "$DRY_RUN" = 1 ]; then
            say "[预演] 将备份 .config 到 $BACKUP_DIR/config-${TS}.bak"
        else
            cp .config "$BACKUP_DIR/config-${TS}.bak"
            say "已备份 .config 到 $BACKUP_DIR/config-${TS}.bak"
        fi
    fi

    if [ "$lvl" -ge 1 ]; then
        if i="$(q_idx heavy)"; then
            p="${QDATA[$i]}"
        else
            p=clean
        fi
        confirm_heavy "$p"
        run make "$p"
    fi

    if q_has feeds; then
        say ""
        say "== feeds 更新 =="
        feeds_update_task
    fi

    third_party_ensure

    if q_has config; then
        i="$(q_idx config)"
        say ""
        say "== .config: $(config_desc "${QDATA[$i]}") =="
        config_task "${QDATA[$i]}"
    fi

    if [ ! -f .config ]; then
        ensure_config
    fi
    apply_ccache_dir
    warn_ccache

    APP_PKGS=()
    APP_NAMES=()
    CLEAN_PKGS=()
    if q_has app; then
        ai="$(q_idx app)"
        app_mode="${QMODE[$ai]}"
        resolve_app_inputs "${QDATA[$ai]}"
        if [ "$AUTO_ENABLE" = 1 ]; then
            say ""
            say "== APP 配置检查 =="
            enable_app_packages
        fi
    fi

    local -a clean_paths=()
    if q_has pkgclean; then
        i="$(q_idx pkgclean)"
        resolve_clean_inputs "${QDATA[$i]}"
        clean_paths=("${CLEAN_PKGS[@]}")
    fi
    if [ "$app_mode" = clean ]; then
        clean_paths+=("${APP_PKGS[@]}")
    fi

    if [ "${#clean_paths[@]}" -gt 0 ]; then
        if [ "$lvl" -eq 0 ]; then
            mapfile -t clean_paths < <(dedupe_list "${clean_paths[@]}")
            say ""
            say "== 清理包 =="
            for p in "${clean_paths[@]}"; do
                run make "$p/clean"
            done
        else
            say "整体清理已覆盖包清理，跳过"
        fi
    fi

    if q_has kernel; then
        ki="$(q_idx kernel)"
        if [ "${QDATA[$ki]}" = standard ]; then
            if [ "$lvl" -eq 0 ]; then
                say ""
                say "== 清理内核构建 =="
                run make target/linux/clean
            else
                say "整体清理已覆盖内核清理，跳过"
            fi
        else
            say "内核快速模式: 跳过 target/linux/clean"
        fi
    fi

    if q_has app; then
        say ""
        say "== 编译 APP =="
        for p in "${APP_PKGS[@]}"; do
            run make "$p/compile" V=s
        done
        if [ "$DRY_RUN" != 1 ]; then
            for n in "${APP_NAMES[@]}"; do
                if ! grep -q "^CONFIG_PACKAGE_${n}=y" .config 2>/dev/null; then
                    say "提示: CONFIG_PACKAGE_${n} 未选中，最终镜像不会包含它"
                fi
            done
        fi
    fi

    say ""
    say "== 最终编译 =="
    build_all
}

ui_execute() {
    local rc=0

    TASK_LABEL="编译"
    init_log

    # 注意: 放在 if 条件或 || 左侧会禁用子 shell 的 errexit，这里必须单独调用
    set +e
    ( set -e; trap finish EXIT; execute_queue_body )
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        printf '\n执行完成，可在主菜单 7 查看执行计划。回车返回主菜单'
        read_menu >/dev/null || true
    elif [ "$rc" -eq 3 ]; then
        printf '\n已取消，未继续执行。\n'
    else
        ui_failure "$rc"
    fi
}

# ---------------- 入口 ----------------

ui_require_tty
setup_environment
ui_main
