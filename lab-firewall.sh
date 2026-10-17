#!/usr/bin/env bash
# ARTEX 실습 랩 방화벽 (root 필요)
#   sudo ./lab-firewall.sh apply    규칙 적용 (여러 번 실행해도 됨)
#   sudo ./lab-firewall.sh remove   규칙 제거
#   sudo ./lab-firewall.sh status   현재 규칙 + 카운터
#
# 막는 것:
#   1) 랩 브리지 + ARTEX 브리지 → 호스트 자신(INPUT). 게이트웨이 IP로 호스트 서비스를 치는 탈출 차단.
#   2) 랩 브리지 → 외부/다른 Docker 네트워크(FORWARD). 장악한 타깃을 통한 egress 차단.
#   3) ARTEX 브리지 → 외부(FORWARD). LLM 엔드포인트만 허용.
# 같은 브리지 안의 통신(ARTEX↔flask, flask↔jenkins, ARTEX↔postgres)은 그대로 둔다.
#
# 브리지 이름은 lab.sh / artex.lab.yml 에서 고정한다 (br-lab-*, br-artex).
# LLM 허용 대상은 ARTEX/.env 의 ARTEX_LLM_BASE_URL 에서 읽는다. 직접 지정하려면:
#   sudo LLM_ALLOW="192.0.2.10:1232 192.0.2.20:8000" ./lab-firewall.sh apply
# 규칙은 재부팅하면 사라진다. 재부팅 후 lab.sh up 전에 다시 apply 할 것.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTEX_DIR="${ARTEX_DIR:-$SCRIPT_DIR/ARTEX}"

LAB_BRIDGES=(br-lab-dmz br-lab-int br-lab-data)
ARTEX_BRIDGE=br-artex
IN_CHAIN=LAB-INPUT
FWD_CHAIN=LAB-FWD

say()  { printf '\033[1;36m[fw]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fw] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 로 실행하세요: sudo $0 ${1:-}"

# ARTEX_LLM_BASE_URL → "ip:port"
llm_allow_from_env() {
  local env="$ARTEX_DIR/.env" url hostport host port
  [ -f "$env" ] || die "$env 없음. LLM_ALLOW=\"ip:port\" 로 직접 지정하세요."
  url="$(sed -n 's/^ARTEX_LLM_BASE_URL=//p' "$env" | tail -1 | tr -d "\"' \r")"
  [ -n "$url" ] || die "ARTEX/.env 에 ARTEX_LLM_BASE_URL 이 비어 있음. LLM_ALLOW=\"ip:port\" 로 직접 지정하세요."
  hostport="${url#*://}"; hostport="${hostport%%/*}"
  host="${hostport%%:*}"; port="${hostport##*:}"
  if [ "$host" = "$port" ]; then
    case "$url" in https://*) port=443 ;; *) port=80 ;; esac
  fi
  [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "LLM 주소가 IP가 아님($host). LLM_ALLOW=\"ip:port\" 로 직접 지정하세요."
  printf '%s:%s' "$host" "$port"
}

# chain 이 없으면 만들고, 있으면 비운다
reset_chain() { # tool chain
  "$1" -N "$2" 2>/dev/null || "$1" -F "$2"
}

# parent 맨 앞에 chain 으로 가는 jump 를 (없을 때만) 넣는다
ensure_jump() { # tool parent chain
  "$1" -C "$2" -j "$3" 2>/dev/null || "$1" -I "$2" 1 -j "$3"
}

# FORWARD 쪽 부모: Docker 가 만든 DOCKER-USER 가 있으면 거기, 없으면 FORWARD
fwd_parent() { # tool
  if "$1" -nL DOCKER-USER >/dev/null 2>&1; then echo DOCKER-USER; else echo FORWARD; fi
}

apply_tool() { # tool allow...
  local t="$1"; shift
  local b all=("${LAB_BRIDGES[@]}" "$ARTEX_BRIDGE")

  reset_chain "$t" "$IN_CHAIN"
  "$t" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for b in "${all[@]}"; do "$t" -A "$IN_CHAIN" -i "$b" -j DROP; done
  ensure_jump "$t" INPUT "$IN_CHAIN"

  reset_chain "$t" "$FWD_CHAIN"
  "$t" -A "$FWD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for b in "${all[@]}"; do "$t" -A "$FWD_CHAIN" -i "$b" -o "$b" -j RETURN; done
  local a
  for a in "$@"; do
    "$t" -A "$FWD_CHAIN" -i "$ARTEX_BRIDGE" -d "${a%%:*}" -p tcp --dport "${a##*:}" -j RETURN
  done
  for b in "${all[@]}"; do "$t" -A "$FWD_CHAIN" -i "$b" -j DROP; done
  ensure_jump "$t" "$(fwd_parent "$t")" "$FWD_CHAIN"
}

remove_tool() { # tool
  local t="$1" p
  for p in INPUT; do while "$t" -D "$p" -j "$IN_CHAIN" 2>/dev/null; do :; done; done
  for p in DOCKER-USER FORWARD; do while "$t" -D "$p" -j "$FWD_CHAIN" 2>/dev/null; do :; done; done
  "$t" -F "$IN_CHAIN" 2>/dev/null && "$t" -X "$IN_CHAIN" 2>/dev/null || true
  "$t" -F "$FWD_CHAIN" 2>/dev/null && "$t" -X "$FWD_CHAIN" 2>/dev/null || true
}

cmd_apply() {
  command -v iptables >/dev/null || die "iptables 가 없습니다."
  iptables -nL DOCKER-USER >/dev/null 2>&1 \
    || die "DOCKER-USER 체인이 없음. Docker 데몬이 iptables 모드로 실행 중인지 확인하세요."

  local allow=()
  if [ -n "${LLM_ALLOW:-}" ]; then read -ra allow <<< "$LLM_ALLOW"; else allow=("$(llm_allow_from_env)"); fi

  apply_tool iptables "${allow[@]}"
  # IPv6: 허용 대상 없이 전부 차단 (랩/ARTEX 는 v6 를 쓰지 않음)
  if command -v ip6tables >/dev/null && ip6tables -nL >/dev/null 2>&1; then
    apply_tool ip6tables
  fi

  say "적용 완료."
  say "  차단: ${LAB_BRIDGES[*]} $ARTEX_BRIDGE → 호스트 / 외부"
  say "  허용: $ARTEX_BRIDGE → ${allow[*]} (tcp)"
  say "확인: ./lab.sh check   (root 불필요)"
}

cmd_remove() {
  remove_tool iptables
  command -v ip6tables >/dev/null && remove_tool ip6tables || true
  say "제거 완료. 이 상태에서는 ARTEX 를 띄우지 마세요."
}

cmd_status() {
  local t
  for t in iptables ip6tables; do
    command -v "$t" >/dev/null || continue
    echo "== $t =="
    "$t" -nvL "$IN_CHAIN" 2>/dev/null || echo "($IN_CHAIN 없음)"
    "$t" -nvL "$FWD_CHAIN" 2>/dev/null || echo "($FWD_CHAIN 없음)"
    echo
  done
}

case "${1:-}" in
  apply)  cmd_apply ;;
  remove) cmd_remove ;;
  status) cmd_status ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
