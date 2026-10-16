#!/usr/bin/env bash
# ARTEX 실습 랩 제어 스크립트
#   ./lab.sh up [--no-artex]   네트워크 생성 → Vulhub 타깃 기동 → ARTEX 기동 → ARTEX를 lab_dmz 에 연결
#   ./lab.sh down              전체 종료 + 타깃 초기화(볼륨 삭제). ARTEX pgdata 는 보존.
#   ./lab.sh status            컨테이너 / 네트워크 소속 확인
#
# Vulhub 원본 폴더는 수정하지 않는다. override 는 ./overrides/ 에 자동 생성된다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VULHUB_DIR="${VULHUB_DIR:-$SCRIPT_DIR/vulhub}"
ARTEX_DIR="${ARTEX_DIR:-$SCRIPT_DIR/ARTEX}"
OVERRIDE_DIR="$SCRIPT_DIR/overrides"
ARTEX_OVERRIDE="$SCRIPT_DIR/artex.lab.yml"

NETWORKS=(lab_dmz lab_internal lab_data)

# 각 줄: "<vulhub 상대경로>|<compose 서비스명>|<연결 네트워크 콤마구분>|<호스트명 alias>"
# RAM 부족 시 아래 줄을 주석(#) 처리하면 해당 서비스는 제외된다.
SERVICES=(
  "flask/ssti|web|lab_dmz,lab_internal|flask"
  "jenkins/CVE-2024-23897|jenkins|lab_internal,lab_data|jenkins"
  "grafana/CVE-2021-43798|web|lab_internal|grafana"
  "nexus/CVE-2019-7238|web|lab_internal|nexus"
  "nacos/CVE-2021-29441|web|lab_internal,lab_data|nacos"
  "mysql/CVE-2012-2122|mysql|lab_data|mysql"
  "redis/4-unacc|redis|lab_data|redis"
  "elasticsearch/CVE-2015-1427|es|lab_data|elasticsearch"
)

say()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[lab]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[lab] %s\033[0m\n' "$*" >&2; exit 1; }

compose() { docker compose "$@"; }

project_name() { # alias -> lab-<alias>
  printf 'lab-%s' "$1"
}

ensure_tools() {
  command -v docker >/dev/null 2>&1 || die "docker 가 없습니다."
  docker compose version >/dev/null 2>&1 || die "docker compose(v2) 가 없습니다."
  [ -d "$VULHUB_DIR" ] || die "vulhub 디렉토리를 못 찾음: $VULHUB_DIR (VULHUB_DIR 로 지정 가능)"
}

create_networks() {
  for n in "${NETWORKS[@]}"; do
    if docker network inspect "$n" >/dev/null 2>&1; then
      say "네트워크 이미 있음: $n"
    else
      docker network create "$n" >/dev/null
      say "네트워크 생성: $n"
    fi
  done
}

# override yml 생성: 호스트 포트 제거 + 지정 네트워크에 alias 로 연결
gen_override() {
  local service="$1" nets_csv="$2" alias="$3" outfile="$4"
  local IFS=',' nets=()
  read -ra nets <<< "$nets_csv"

  {
    echo "# lab.sh 가 생성함. 직접 수정하지 말 것 (Vulhub 원본과 분리된 override)."
    echo "services:"
    echo "  ${service}:"
    echo "    ports: !reset []"
    echo "    networks:"
    for n in "${nets[@]}"; do
      echo "      ${n}:"
      echo "        aliases:"
      echo "          - ${alias}"
    done
    echo "networks:"
    for n in "${nets[@]}"; do
      echo "  ${n}:"
      echo "    external: true"
    done
  } > "$outfile"
}

up_targets() {
  mkdir -p "$OVERRIDE_DIR"
  for row in "${SERVICES[@]}"; do
    [[ "$row" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r relpath service nets alias <<< "$row"
    local dir="$VULHUB_DIR/$relpath"
    local base="$dir/docker-compose.yml"
    [ -f "$base" ] || base="$dir/compose.yml"
    [ -f "$base" ] || { warn "compose 파일 없음, 건너뜀: $relpath"; continue; }

    local ovr="$OVERRIDE_DIR/${alias}.yml"
    gen_override "$service" "$nets" "$alias" "$ovr"

    local proj; proj="$(project_name "$alias")"
    say "기동: $alias  ($relpath → $nets)"
    compose -p "$proj" -f "$base" -f "$ovr" up -d
  done
}

down_targets() {
  for row in "${SERVICES[@]}"; do
    [[ "$row" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r relpath service nets alias <<< "$row"
    local dir="$VULHUB_DIR/$relpath"
    local base="$dir/docker-compose.yml"
    [ -f "$base" ] || base="$dir/compose.yml"
    [ -f "$base" ] || continue
    local ovr="$OVERRIDE_DIR/${alias}.yml"
    [ -f "$ovr" ] || ovr="$base"   # override 없으면 base 만으로 down
    local proj; proj="$(project_name "$alias")"
    say "종료: $alias"
    compose -p "$proj" -f "$base" -f "$ovr" down -v --remove-orphans || true
  done
}

ensure_artex_env() {
  local env="$ARTEX_DIR/.env"
  if [ -f "$env" ]; then return 0; fi
  [ -f "$ARTEX_DIR/.env.example" ] || die "ARTEX/.env.example 가 없음: $ARTEX_DIR"
  local pw; pw="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
  sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${pw}/" "$ARTEX_DIR/.env.example" > "$env"
  warn "ARTEX/.env 를 새로 만들었습니다 (POSTGRES_PASSWORD 자동 생성)."
  warn "LLM 을 쓰려면 ARTEX/.env 의 ANTHROPIC_API_KEY 또는 OPENAI_API_KEY 를 채우거나 UI에서 설정하세요."
}

artex_container() {
  compose -p artex -f "$ARTEX_DIR/docker-compose.yml" -f "$ARTEX_OVERRIDE" ps -q artex 2>/dev/null || true
}

up_artex() {
  [ -f "$ARTEX_DIR/docker-compose.yml" ] || die "ARTEX docker-compose.yml 없음: $ARTEX_DIR"
  ensure_artex_env
  say "ARTEX 기동 (포트는 127.0.0.1 전용)"
  compose -p artex -f "$ARTEX_DIR/docker-compose.yml" -f "$ARTEX_OVERRIDE" up -d

  local cid; cid="$(artex_container)"
  [ -n "$cid" ] || die "ARTEX 컨테이너를 못 찾음."
  if docker inspect -f '{{json .NetworkSettings.Networks}}' "$cid" | grep -q '"lab_dmz"'; then
    say "ARTEX 는 이미 lab_dmz 에 연결됨."
  else
    docker network connect lab_dmz "$cid"
    say "ARTEX 를 lab_dmz 에 연결함. (내부/데이터망에는 연결하지 않음 — 피버팅 유지)"
  fi
}

down_artex() {
  [ -f "$ARTEX_DIR/docker-compose.yml" ] || return 0
  local cid; cid="$(artex_container)"
  if [ -n "$cid" ]; then docker network disconnect lab_dmz "$cid" 2>/dev/null || true; fi
  say "ARTEX 종료 (pgdata 볼륨은 보존)"
  compose -p artex -f "$ARTEX_DIR/docker-compose.yml" -f "$ARTEX_OVERRIDE" down || true
}

remove_networks() {
  for n in "${NETWORKS[@]}"; do
    docker network rm "$n" >/dev/null 2>&1 && say "네트워크 삭제: $n" || true
  done
}

cmd_up() {
  local with_artex=1
  for a in "$@"; do [ "$a" = "--no-artex" ] && with_artex=0; done
  ensure_tools
  create_networks
  up_targets
  if [ "$with_artex" -eq 1 ]; then up_artex; fi
  echo
  say "완료."
  say "ARTEX UI:  http://127.0.0.1:8787  (원격이면: ssh -L 8787:localhost:8787 user@서버)"
  say "ARTEX 작업 대상 주소:  http://flask:8000"
  say "상태 보기: ./lab.sh status"
}

cmd_down() {
  ensure_tools
  down_artex
  down_targets
  remove_networks
  say "전체 종료 완료."
}

cmd_status() {
  ensure_tools
  echo "== 랩 컨테이너 =="
  docker ps --filter "name=lab-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
  local cid; cid="$(artex_container)"
  [ -n "$cid" ] && { echo; echo "== ARTEX =="; docker ps --filter "id=$cid" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'; }
  echo
  echo "== 네트워크별 소속 =="
  for n in "${NETWORKS[@]}"; do
    docker network inspect "$n" >/dev/null 2>&1 || { echo "$n: (없음)"; continue; }
    printf '%s: ' "$n"
    docker network inspect "$n" -f '{{range .Containers}}{{.Name}} {{end}}'
    echo
  done
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    up)     cmd_up "$@" ;;
    down)   cmd_down ;;
    status|ps) cmd_status ;;
    *) cat <<EOF
사용법:
  ./lab.sh up [--no-artex]   랩 전체 기동 (ARTEX 포함 / --no-artex 면 타깃만)
  ./lab.sh down              전체 종료 + 타깃 초기화
  ./lab.sh status            상태 확인
EOF
      exit 1 ;;
  esac
}

main "$@"
