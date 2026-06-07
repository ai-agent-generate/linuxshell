#!/usr/bin/env bash
# lib/status-common.sh — HA 状态巡检共享库(只读)
# 被 PG/MySQL HA 巡检脚本 source（后者已先加载 lib/common.sh）。
# Task 2+ 的检查函数将直接调用 common.sh 的 command_exists/port_in_use 等工具。

# ---- 阈值默认值(可被环境变量覆盖) ----
STATUS_RECHECK_DELAY="${STATUS_RECHECK_DELAY:-3}"
STATUS_DISK_WARN_PCT="${STATUS_DISK_WARN_PCT:-80}"
STATUS_DISK_CRIT_PCT="${STATUS_DISK_CRIT_PCT:-90}"
STATUS_PG_LAG_CRIT_MB="${STATUS_PG_LAG_CRIT_MB:-512}"
STATUS_MYSQL_LAG_WARN_SEC="${STATUS_MYSQL_LAG_WARN_SEC:-30}"
STATUS_MYSQL_LAG_CRIT_SEC="${STATUS_MYSQL_LAG_CRIT_SEC:-300}"
STATUS_CONN_WARN_PCT="${STATUS_CONN_WARN_PCT:-80}"
STATUS_CONN_CRIT_PCT="${STATUS_CONN_CRIT_PCT:-95}"
STATUS_LOG_LINES="${STATUS_LOG_LINES:-20}"
STATUS_REDACT_IP="${STATUS_REDACT_IP:-0}"

# ---- 着色(非 tty 或 NO_COLOR 时禁用，便于重定向/cron) ----
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  STATUS_C_OK=$'\033[32m'; STATUS_C_WARN=$'\033[33m'; STATUS_C_CRIT=$'\033[31m'
  STATUS_C_INFO=$'\033[90m'; STATUS_C_RST=$'\033[0m'; STATUS_C_BOLD=$'\033[1m'
else
  STATUS_C_OK=""; STATUS_C_WARN=""; STATUS_C_CRIT=""; STATUS_C_INFO=""; STATUS_C_RST=""; STATUS_C_BOLD=""
fi

# ---- 计数器 / 问题清单 / 覆盖度 ----
STATUS_WARN_COUNT=0
STATUS_CRIT_COUNT=0
STATUS_ISSUES=()
STATUS_COVER_SEEN=0
STATUS_COVER_UNREACH=0

# 重置本次巡检会话的计数器与问题列表；着色变量由 source 时初始化，不在此重置。
status_reset() {
  STATUS_WARN_COUNT=0; STATUS_CRIT_COUNT=0; STATUS_ISSUES=()
  STATUS_COVER_SEEN=0; STATUS_COVER_UNREACH=0
}

status_section() { printf '\n%s== %s ==%s\n' "${STATUS_C_BOLD}" "$1" "${STATUS_C_RST}"; }
status_kv() { printf '  %-22s %s\n' "$1" "${2:-}"; }

# status_record <OK|WARN|CRIT|INFO> <title> [detail]
# 采集与渲染的接缝:检查函数只调它，未来加 --json 仅换此后端。
status_record() {
  local level="$1" title="$2" detail="${3:-}"
  local tag color
  case "$level" in
    OK)   tag="OK  "; color="${STATUS_C_OK}" ;;
    WARN) tag="WARN"; color="${STATUS_C_WARN}"; STATUS_WARN_COUNT=$((STATUS_WARN_COUNT+1)); STATUS_ISSUES+=("[WARN] ${title}${detail:+: $detail}") ;;
    CRIT) tag="CRIT"; color="${STATUS_C_CRIT}"; STATUS_CRIT_COUNT=$((STATUS_CRIT_COUNT+1)); STATUS_ISSUES+=("[CRIT] ${title}${detail:+: $detail}") ;;
    INFO) tag="INFO"; color="${STATUS_C_INFO}" ;;
    *)    tag="????"; color="" ;;
  esac
  printf '%s[%s]%s %s%s\n' "$color" "$tag" "${STATUS_C_RST}" "$title" "${detail:+ — $detail}"
}
status_ok()   { status_record OK   "$1" "${2:-}"; }
status_warn() { status_record WARN "$1" "${2:-}"; }
status_crit() { status_record CRIT "$1" "${2:-}"; }
status_info() { status_record INFO "$1" "${2:-}"; }

# 整体退出码:CRIT>0 -> 2; WARN>0 -> 1; else 0
status_final_code() {
  if [[ "${STATUS_CRIT_COUNT}" -gt 0 ]]; then return 2; fi
  if [[ "${STATUS_WARN_COUNT}" -gt 0 ]]; then return 1; fi
  return 0
}

status_cover_seen() { STATUS_COVER_SEEN=$((STATUS_COVER_SEEN+1)); }
status_cover_unreachable() { STATUS_COVER_UNREACH=$((STATUS_COVER_UNREACH+1)); }

status_summary() {
  local total=$((STATUS_COVER_SEEN+STATUS_COVER_UNREACH)) issue
  status_section "巡检结论"
  if [[ "$total" -gt 0 ]]; then
    printf '  跨节点覆盖: %d/%d 可达' "${STATUS_COVER_SEEN}" "$total"
    [[ "${STATUS_COVER_UNREACH}" -gt 0 ]] && printf ' (部分不可达，防脑裂/入口一致性结论可能不完整)'
    printf '\n'
  fi
  if [[ "${STATUS_CRIT_COUNT}" -gt 0 ]]; then
    printf '  %s整体: CRITICAL%s (%d CRIT, %d WARN)\n' "${STATUS_C_CRIT}" "${STATUS_C_RST}" "${STATUS_CRIT_COUNT}" "${STATUS_WARN_COUNT}"
  elif [[ "${STATUS_WARN_COUNT}" -gt 0 ]]; then
    printf '  %s整体: WARNING%s (%d WARN)\n' "${STATUS_C_WARN}" "${STATUS_C_RST}" "${STATUS_WARN_COUNT}"
  else
    printf '  %s整体: OK%s\n' "${STATUS_C_OK}" "${STATUS_C_RST}"
  fi
  for issue in "${STATUS_ISSUES[@]:-}"; do
    [[ -n "$issue" ]] && printf '   - %s\n' "$issue"
  done
  return 0
}
