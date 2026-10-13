#!/usr/bin/env bash
# =============================================================================
# setup-tproxy.sh — установка и обслуживание Telegram WEB proxy
#                   (telegramdesktop/tproxy-server + официальный MTProxy)
#
# Запускать на целевом сервере от root.
#
#   ./setup-tproxy.sh                  интерактивное меню
#   ./setup-tproxy.sh install   ...    установить (идемпотентно)
#   ./setup-tproxy.sh uninstall ...    удалить всё, что добавил скрипт
#   ./setup-tproxy.sh restore   ...    удалить и вернуть конфиги из бэкапов
#   ./setup-tproxy.sh reinstall ...    переустановить (секрет, сайт, сертификат сохраняются)
#   ./setup-tproxy.sh show             показать конфиг веб-прокси
#   ./setup-tproxy.sh users ...        пользователи: по одному секрету на человека
#   ./setup-tproxy.sh refresh          поставить таймер и обновить адреса серверов Telegram сейчас
#                                      (list|add|disable|enable|delete|limit|limits|apply)
#   (вызов с --domain без команды = install, как в прежних версиях)
#
# Два режима установки (--mode auto|remnawave|standalone):
#
#   remnawave   Найден nginx-контейнер Remnawave (self-steal: Xray на :443,
#               nginx за unix-сокетом с proxy_protocol). Добавляется новый
#               server-блок, сертификат и volume в docker-compose.
#               Контейнеры пересоздаются (VPN моргнёт на несколько секунд).
#
#   standalone  Nginx Remnawave нет. Ставится Caddy (он берёт :80/:443 и сам
#               выпускает сертификат), relay отдаёт сайт-заглушку: ваш
#               (--site-dir/--site-archive/--site-git) или сгенерированный.
#
# Что скрипт запоминает: /var/lib/tproxy-setup/state.env (режим, домен, пути
# «исходных» бэкапов *.pre-tproxy, что было поставлено им самим).
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/usr/local/go/bin"

exec 3>&1                         # fd 3 — только терминал (меню, секрет — мимо лога)
LOG_FILE=/var/log/tproxy-setup.log

# ------------------------------------------------------------------ значения по умолчанию
CMD=""
DOMAIN=""
EMAIL=""
SITE_DIR_ARG=""
SITE_ARCHIVE=""
SITE_GIT=""
SITE_AUTO=0
MODE="auto"
REMNA_DIR="/opt/remnanode"
NGINX_CTR="remnawave-nginx"
REPO_URL="https://github.com/telegramdesktop/tproxy-server"
REPO_REF=""
SECRET=""
ASSUME_YES=0
DNS_WAIT=0
RUN_TESTS=0
SKIP_NGINX_TEST=0
PURGE=0
BACKUP_NGINX=""
BACKUP_COMPOSE=""
BACKUP_CADDY=""
RESTORE_MODE=0
LAST_RC=0
USER_SESSIONS=6          # одновременных сессий на пользователя (--user-sessions)
USER_ARGS=()
MT_ENV_CHANGED=0

SRC=/opt/tproxy-server
CONF_DIR=/etc/tproxy-server
SITE_DST=/srv/tproxy-site
STATE_DIR=/var/lib/tproxy-setup
STATE_FILE="$STATE_DIR/state.env"
USERS_FILE="$CONF_DIR/users.json"
SITE_SRC=""
TMPDIRS=()
PUBLIC_IP=""
LOCAL4=()
CHANGED_BIN=0
RESOLVED_MODE=""
COMPOSE=""

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] ВНИМАНИЕ: %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ОШИБКА: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

# apt с видимой ошибкой: вывод собирается, при сбое показывается хвост, затем одна попытка
# починки (dpkg --configure -a, apt-get -f install, ожидание блокировки) и повтор.
apt_run() {
  local out rc=0 attempt
  out=$(mktemp)
  for attempt in 1 2; do
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" >"$out" 2>&1 && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then rm -f "$out"; return 0; fi
    warn "apt-get $* завершился с кодом $rc (попытка $attempt/2). Последние строки:"
    tail -n 25 "$out" >&2
    if [[ $attempt -eq 1 ]]; then
      warn "Пробую починить dpkg: dpkg --configure -a; apt-get -f install; apt-get update"
      DEBIAN_FRONTEND=noninteractive dpkg --configure -a >"$out" 2>&1 || tail -n 15 "$out" >&2
      DEBIAN_FRONTEND=noninteractive apt-get -y -f install >"$out" 2>&1 || tail -n 15 "$out" >&2
      apt-get update -qq >/dev/null 2>&1 || true
    fi
  done
  rm -f "$out"
  die "Не удалось выполнить apt-get $*. Выполните вручную: dpkg --audit; dpkg --configure -a; apt-get -f install; tail -n 60 /var/log/apt/term.log — и запустите скрипт снова."
}

cleanup() { local d; for d in "${TMPDIRS[@]:-}"; do if [[ -n $d && -e $d ]]; then rm -rf "$d"; fi; done; return 0; }
trap cleanup EXIT
trap 'rc=$?; printf "ОШИБКА: код %s, строка %s (лог: %s)\n" "$rc" "$LINENO" "$LOG_FILE" >&2' ERR

# ------------------------------------------------------------------ состояние
state_get() {
  [[ -f $STATE_FILE ]] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}
state_set() {
  install -d -m 0700 "$STATE_DIR"
  touch "$STATE_FILE"; chmod 0600 "$STATE_FILE"
  sed -i "/^$1=/d" "$STATE_FILE"
  printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"
}

load_state_defaults() {
  local v
  v=$(state_get REMNA_DIR); if [[ -n $v ]]; then REMNA_DIR=$v; fi
  v=$(state_get NGINX_CTR); if [[ -n $v ]]; then NGINX_CTR=$v; fi
  v=$(state_get EMAIL);     if [[ -n $v ]]; then EMAIL=$v; fi
  return 0
}
load_state_defaults

usage() {
  cat <<'EOF'
Использование:
  setup-tproxy.sh                         интерактивное меню
  setup-tproxy.sh КОМАНДА [опции]

Команды:
  install      установить WEB-прокси (по умолчанию, если есть --domain)
  uninstall    удалить всё, что добавил скрипт (чужие правки в конфигах не трогаются)
  restore      удалить и вернуть nginx.conf/compose/Caddyfile из бэкапов
  reinstall    переустановить; секрет, сайт и сертификат сохраняются
  show         показать конфиг веб-прокси (секрет, ссылка, сервисы, фронтенд)
  users        пользователи (секреты): users list | add ИМЯ | disable ИМЯ | enable ИМЯ |
               delete ИМЯ | limit ИМЯ N | limits | apply
  refresh      обновить proxy-multi.conf (адреса серверов Telegram) сейчас и поставить
               ежедневный таймер (при install ставится автоматически)
  menu         меню (то же, что запуск без аргументов)

Для install:
  --domain NAME          hostname для WEB-прокси (отдельный от основного сайта)
  --email ADDR           e-mail для Let's Encrypt (рекомендуется)
  --mode MODE            auto (по умолчанию) | remnawave | standalone
  --remnanode-dir DIR    каталог с docker-compose.yml Remnawave (/opt/remnanode)
  --nginx-container N    имя nginx-контейнера (remnawave-nginx)
  --secret HEX32         свой секрет (32 hex); иначе генерируется
  --dns-wait SEC         ждать появления A-записи до SEC секунд (по умолчанию 0)
  --repo-ref REF         ветка/тег/коммит tproxy-server
  --run-tests            прогнать go test перед сборкой (на 1 ядре долго)
  --skip-nginx-test      не проверять nginx.conf временным контейнером

  Сайт-заглушка для relay (не более одного источника):
  --site-dir DIR         каталог с index.html
  --site-archive SRC     .tar.gz/.tgz/.tar.xz/.zip: локальный путь или https-URL
  --site-git URL         git-репозиторий (клонируется с --depth 1)
  --site-auto            сгенерировать уникальный сайт-заглушку (по случайному seed)
  Без этих опций: повторный запуск оставляет уже установленный сайт;
  режим remnawave копирует /var/www/html, если он есть;
  иначе (в т.ч. standalone) сайт генерируется автоматически.

Для uninstall / restore / reinstall:
  --domain NAME          если не указан — берётся из установленной конфигурации
  --purge                при удалении также убрать сертификат, а также Go/Caddy/swap,
                         если их поставил сам скрипт (без флага — спросит)
  --backup-nginx FILE    какой бэкап nginx.conf использовать при restore
  --backup-compose FILE  какой бэкап docker-compose использовать при restore
  --backup-caddy FILE    какой бэкап Caddyfile использовать при restore

Для users:
  users list             список пользователей со ссылками
  users add ИМЯ          добавить (--secret HEX32 — свой секрет, иначе генерируется)
  users disable ИМЯ      отключить (relay перестанет принимать его секрет)
  users enable ИМЯ       включить обратно (секрет тот же)
  users delete ИМЯ       удалить безвозвратно
  users limit ИМЯ N      лимит одновременных сессий пользователя
  users limits           подобрать глобальные лимиты relay по памяти сервера
  users apply            пересоздать profiles.json/секреты MTProxy и перезапустить
  --user-sessions N      лимит сессий для нового пользователя (по умолчанию 6)
  Лимит по IP не используется (много людей могут быть за одним NAT оператора).

Общее:
  -y, --yes              не задавать вопросов (опасные «purge»-шаги — только с --purge)
  -h, --help             эта справка
EOF
}

# ------------------------------------------------------------------ аргументы
if [[ $# -gt 0 ]]; then
  case "$1" in
    install|uninstall|restore|reinstall|show|menu|users|refresh) CMD="$1"; shift ;;
  esac
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)           DOMAIN="${2:-}"; shift 2 ;;
    --email)            EMAIL="${2:-}"; shift 2 ;;
    --site-dir)         SITE_DIR_ARG="${2:-}"; shift 2 ;;
    --site-archive)     SITE_ARCHIVE="${2:-}"; shift 2 ;;
    --site-git)         SITE_GIT="${2:-}"; shift 2 ;;
    --site-auto)        SITE_AUTO=1; shift ;;
    --mode)             MODE="${2:-}"; shift 2 ;;
    --remnanode-dir)    REMNA_DIR="${2:-}"; shift 2 ;;
    --nginx-container)  NGINX_CTR="${2:-}"; shift 2 ;;
    --secret)           SECRET="${2:-}"; shift 2 ;;
    --dns-wait)         DNS_WAIT="${2:-0}"; shift 2 ;;
    --repo-ref)         REPO_REF="${2:-}"; shift 2 ;;
    --run-tests)        RUN_TESTS=1; shift ;;
    --skip-nginx-test)  SKIP_NGINX_TEST=1; shift ;;
    --purge)            PURGE=1; shift ;;
    --user-sessions)    USER_SESSIONS="${2:-}"; shift 2 ;;
    --backup-nginx)     BACKUP_NGINX="${2:-}"; shift 2 ;;
    --backup-compose)   BACKUP_COMPOSE="${2:-}"; shift 2 ;;
    --backup-caddy)     BACKUP_CADDY="${2:-}"; shift 2 ;;
    -y|--yes)           ASSUME_YES=1; shift ;;
    -h|--help)          usage >&3; exit 0 ;;
    -*) usage >&3; die "Неизвестный параметр: $1" ;;
    *) if [[ $CMD == users ]]; then USER_ARGS+=("$1"); shift
       else usage >&3; die "Неизвестный параметр: $1"; fi ;;
  esac
done
if [[ ! $USER_SESSIONS =~ ^[0-9]+$ ]] || (( USER_SESSIONS < 1 || USER_SESSIONS > 1000 )); then
  die "--user-sessions: число от 1 до 1000"
fi
if [[ -z $CMD ]]; then
  if [[ -n $DOMAIN ]]; then CMD=install; else CMD=menu; fi
fi

# ------------------------------------------------------------------ интерактив (через fd 3 / tty)
have_tty() { { : </dev/tty; } 2>/dev/null; }
ask() {   # ask "вопрос" ИМЯ_ПЕРЕМЕННОЙ
  local __v=""
  # логи идут через tee асинхронно: даём им сброситься, чтобы вопрос не оказался раньше строк лога
  if have_tty; then sleep 0.2; fi
  printf '%s' "$1" >&3
  have_tty && { read -r __v </dev/tty || __v=""; }
  printf -v "$2" '%s' "$__v"
}
confirm() {
  if (( ASSUME_YES )); then return 0; fi
  local a=""
  ask "$1 [y/N] " a
  [[ $a =~ ^[yYдД]$ ]]
}
purge_ask() {   # для необязательных «purge»-шагов
  if (( PURGE )); then return 0; fi
  if (( ASSUME_YES )); then return 1; fi
  confirm "$1"
}

# ------------------------------------------------------------------ проверки
require_root() { [[ $EUID -eq 0 ]] || die "Запустите от root (sudo)."; }
valid_domain() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }

setup_logging() {
  exec > >(tee -a "$LOG_FILE") 2>&1
  exec 9>/var/lock/tproxy-setup.lock
  flock -n 9 || die "Скрипт уже запущен"
}

validate_install_args() {
  [[ -n $DOMAIN ]] || die "Не указан --domain."
  DOMAIN="${DOMAIN,,}"
  valid_domain "$DOMAIN" \
    || die "Некорректный hostname: $DOMAIN (без https://, порта и пути; для IDN используйте xn--...)."
  [[ $MODE =~ ^(auto|remnawave|standalone)$ ]] || die "--mode: auto|remnawave|standalone"
  [[ $DNS_WAIT =~ ^[0-9]+$ ]] || die "--dns-wait должен быть числом"
  if [[ -n $SECRET ]]; then
    [[ $SECRET =~ ^[0-9a-f]{32}$ ]] || die "--secret: ровно 32 символа [0-9a-f]"
  fi
  local n=0
  if [[ -n $SITE_DIR_ARG ]]; then n=$((n+1)); fi
  if [[ -n $SITE_ARCHIVE ]]; then n=$((n+1)); fi
  if [[ -n $SITE_GIT ]]; then n=$((n+1)); fi
  [[ $n -le 1 ]] || die "Укажите не более одного источника сайта."
  [[ $(uname -m) == x86_64 ]] || die "Официальный MTProxy собирается только на x86_64."
  [[ -r /etc/os-release ]] || die "Нет /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu) dpkg --compare-versions "${VERSION_ID:-0}" ge 22.04 || die "Нужна Ubuntu 22.04+" ;;
    debian) dpkg --compare-versions "${VERSION_ID:-0}" ge 12 || die "Нужен Debian 12+" ;;
    *) die "Поддерживаются только Ubuntu 22.04+ и Debian 12+ (найдено: ${ID:-?})." ;;
  esac
}

ensure_tools() {
  step "Базовые пакеты"
  apt-get update -qq || warn "apt-get update завершился с ошибкой — продолжаю"
  apt_run install -y ca-certificates curl dnsutils iproute2 openssl python3 git iptables unzip
}

# ------------------------------------------------------------------ DNS
local_v4() { ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}'; }
local_v6() { ip -6 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}'; }

public_v4() {
  local u ip
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

DNS_SEEN=""
dns_matches() {
  local r out a ok=0 bad=0
  DNS_SEEN=""
  for r in 1.1.1.1 8.8.8.8 9.9.9.9; do
    out=$(dig +short +time=3 +tries=1 A "$DOMAIN" @"$r" 2>/dev/null \
          | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)
    [[ -n $out ]] || continue
    DNS_SEEN+="$r -> $(echo $out | tr '\n' ' '); "
    for a in $out; do
      if [[ $a == "$PUBLIC_IP" ]] || grep -qx "$a" <<<"$(printf '%s\n' "${LOCAL4[@]}")"; then
        ok=1
      else
        bad=1
      fi
    done
  done
  [[ $ok -eq 1 && $bad -eq 0 ]]
}

check_dns() {
  step "Проверка DNS: $DOMAIN"
  PUBLIC_IP=$(public_v4 || true)
  mapfile -t LOCAL4 < <(local_v4)
  if [[ -z $PUBLIC_IP ]]; then
    PUBLIC_IP="${LOCAL4[0]:-}"
    warn "Не удалось определить внешний IP через интернет, использую локальный: ${PUBLIC_IP:-нет}"
  fi
  [[ -n $PUBLIC_IP ]] || die "Не удалось определить IPv4 этого сервера."
  log "IPv4 сервера: $PUBLIC_IP"

  local deadline=$((SECONDS + DNS_WAIT))
  while ! dns_matches; do
    if (( SECONDS >= deadline )); then
      die "A-запись $DOMAIN не указывает на этот сервер ($PUBLIC_IP). Видно: ${DNS_SEEN:-ничего}. Создайте A-запись (без CDN/проксирования) и повторите, либо используйте --dns-wait 300."
    fi
    log "A-запись пока не совпадает (${DNS_SEEN:-пусто}); повтор через 15 с..."
    sleep 15
  done
  log "A-запись в порядке: $DNS_SEEN"

  local aaaa a
  aaaa=$(dig +short +time=3 +tries=1 AAAA "$DOMAIN" @1.1.1.1 2>/dev/null | grep ':' || true)
  if [[ -n $aaaa ]]; then
    mapfile -t L6 < <(local_v6)
    for a in $aaaa; do
      grep -qix "$a" <<<"$(printf '%s\n' "${L6[@]:-}")" \
        || die "У $DOMAIN есть AAAA-запись ($a), которой нет на этом сервере. Удалите AAAA — иначе Let's Encrypt и клиенты пойдут по сломанному IPv6."
    done
    warn "У $DOMAIN есть AAAA, совпадающая с адресом сервера — убедитесь, что IPv6 реально работает."
  fi
}

# ------------------------------------------------------------------ ресурсы
check_ports() {
  step "Проверка портов"
  local p
  for p in 8080 8081 2398 8888; do
    if [[ -n $(ss -H -ltnp "sport = :$p" 2>/dev/null) ]]; then
      if systemctl is-active --quiet tproxy-server || systemctl is-active --quiet mtproxy; then
        continue   # повторный запуск: порты держат наши же сервисы
      fi
      die "Порт $p занят: $(ss -H -ltnp "sport = :$p")"
    fi
  done
}

ensure_swap() {
  step "Память и swap"
  local mem swap total free_mb
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
  total=$((mem + swap))
  log "RAM ${mem} МБ, swap ${swap} МБ"
  if (( total >= 2900 )); then return 0; fi
  free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if (( free_mb < 4096 )); then
    warn "Мало памяти (RAM+swap=${total} МБ) и мало диска (${free_mb} МБ) — сборка MTProxy/Go может упасть по OOM."
    return 0
  fi
  if [[ ! -e /swapfile.tproxy ]]; then
    log "Создаю swap 2 ГБ: /swapfile.tproxy"
    fallocate -l 2G /swapfile.tproxy
    chmod 600 /swapfile.tproxy
    mkswap /swapfile.tproxy >/dev/null
    state_set SWAP_BY_US 1
  fi
  swapon /swapfile.tproxy 2>/dev/null || true
  grep -q '^/swapfile.tproxy ' /etc/fstab || echo '/swapfile.tproxy none swap sw 0 0' >> /etc/fstab
  return 0
}

# ------------------------------------------------------------------ Go + сборка
go_ok() {
  command -v go >/dev/null 2>&1 || return 1
  local v; v=$(go env GOVERSION 2>/dev/null | sed 's/^go//')
  [[ -n $v ]] && [[ $(printf '%s\n1.20\n' "$v" | sort -V | head -1) == "1.20" ]]
}

install_go() {
  step "Go"
  if go_ok; then log "Go уже установлен: $(go version)"; return 0; fi
  local file sha tmp
  read -r file sha < <(python3 - <<'PY'
import json, urllib.request
d = json.load(urllib.request.urlopen("https://go.dev/dl/?mode=json", timeout=30))
for r in d:
    if not r.get("stable"):
        continue
    for f in r["files"]:
        if f["os"] == "linux" and f["arch"] == "amd64" and f["kind"] == "archive":
            print(f["filename"], f["sha256"])
            raise SystemExit
PY
)
  [[ -n $file && -n $sha ]] || die "Не удалось получить информацию о последней версии Go"
  tmp=$(mktemp -d); TMPDIRS+=("$tmp")
  if [[ -f /root/$file && $(sha256sum "/root/$file" | awk '{print $1}') == "$sha" ]]; then
    log "Использую локальный /root/$file"
    cp "/root/$file" "$tmp/$file"
  else
  log "Скачиваю $file"
  # go.dev редиректит на dl.google.com; у некоторых хостеров соединение сбрасывается —
  # пробуем по очереди несколько зеркал (целостность в любом случае проверяется по sha256).
  local url ok=0
  for url in "https://go.dev/dl/$file" "https://dl.google.com/go/$file" \
             "https://golang.google.cn/dl/$file" "https://mirrors.aliyun.com/golang/$file"; do
    log "  источник: ${url%%/dl/*}"
    rm -f "$tmp/$file"
    if curl -fsSL --proto '=https' --retry 3 --retry-delay 3 --retry-all-errors \
         --connect-timeout 20 --max-time 600 -o "$tmp/$file" "$url" \
       && [[ $(sha256sum "$tmp/$file" | awk '{print $1}') == "$sha" ]]; then
      ok=1; break
    fi
    warn "не удалось скачать с этого источника, пробую следующий"
  done
  [[ $ok -eq 1 ]] || die "Не удалось скачать Go ни с одного источника (или не совпала контрольная сумма). Скачайте $file вручную на сервер в /root/ и запустите скрипт снова: он подхватит файл."
  fi
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/$file"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  state_set GO_BY_US 1
  log "$(go version)"
}

build_relay() {
  step "Сборка tproxy-server"
  apt_run install -y build-essential libssl-dev zlib1g-dev
  if [[ -d $SRC/.git ]]; then
    git -C "$SRC" fetch --all -q
    if [[ -n $REPO_REF ]]; then git -C "$SRC" checkout -q "$REPO_REF"; else git -C "$SRC" pull -q --ff-only || warn "git pull не удался, использую текущую версию"; fi
  else
    if [[ -e $SRC ]]; then die "$SRC существует, но это не git-репозиторий"; fi
    git clone -q "$REPO_URL" "$SRC"
    if [[ -n $REPO_REF ]]; then git -C "$SRC" checkout -q "$REPO_REF"; fi
  fi
  local head; head=$(git -C "$SRC" rev-parse HEAD)
  if [[ ! -x $SRC/tproxy-server || $(cat "$SRC/.built-commit" 2>/dev/null || true) != "$head" ]]; then
    ( cd "$SRC"
      if (( RUN_TESTS )); then go test ./... 2>&1 | tail -15; fi
      log "go build (на 1 ядре это несколько минут)"
      go build -trimpath -o tproxy-server ./cmd/tproxy-server )
    echo "$head" > "$SRC/.built-commit"
  else
    log "Бинарник уже собран из $head"
  fi
  id tproxy >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin tproxy
  install -d -m 0755 "$CONF_DIR"
  if ! cmp -s "$SRC/tproxy-server" /usr/local/bin/tproxy-server; then
    install -m 0755 "$SRC/tproxy-server" /usr/local/bin/tproxy-server
    CHANGED_BIN=1
  fi
  "$SRC/deploy/ensure-token-key.sh" "$CONF_DIR/token.key"
}

# ------------------------------------------------------------------ сайт
# Генератор сайта-заглушки. Результат зависит от seed (хранится в
# /etc/tproxy-server/site.seed), поэтому у каждого сервера он свой, а при
# повторном запуске остаётся прежним. Соответствует CSP relay: только
# внешний CSS и SVG с того же домена, без inline-кода, форм и внешних ресурсов.
generate_site() {
  local out=$1 seedfile="$CONF_DIR/site.seed"
  install -d -m 0755 "$CONF_DIR"
  if [[ ! -s $seedfile ]]; then
    openssl rand -hex 16 > "$seedfile"
    chmod 0600 "$seedfile"
  fi
  mkdir -p "$out"
  python3 -I - "$out" "$(cat "$seedfile")" "$DOMAIN" <<'PY'
import colorsys, datetime, hashlib, html, os, random, sys

out, seed, domain = sys.argv[1], sys.argv[2], sys.argv[3]
rnd = random.Random(int(hashlib.sha256(f"{seed}|{domain}".encode()).hexdigest(), 16))
esc = html.escape

KINDS = [
    dict(suffix=["Studio", "Ceramics", "Atelier"],
         tagline="Hand-built ceramics and small-batch homeware.",
         intro="We make everyday tableware, planters and lamps in small runs, shaped by hand and fired in our own kiln.",
         services=[("Tableware", "Mugs, bowls and plates glazed in a limited palette that changes with the seasons."),
                   ("Planters", "Frost-resistant stoneware planters in three sizes, with or without drainage."),
                   ("Commissions", "Matching sets and one-off pieces made to your measurements.")],
         about="The studio began as a shared kiln and a handful of evening classes. It is still a small team, and every piece passes through the same few hands from clay to glaze.",
         work=["Spring tableware collection", "Stoneware planter series", "Cafe cup commission", "Glaze test archive"]),
    dict(suffix=["Cycles", "Workshop", "Bike Works"],
         tagline="Repairs, rebuilds and honest advice for everyday bicycles.",
         intro="From a quick brake adjustment to a full drivetrain rebuild, we keep commuter and touring bikes on the road.",
         services=[("Repairs", "Same-week turnaround on punctures, gears, brakes and wheel truing."),
                   ("Rebuilds", "Strip-down and rebuild of older frames with new bearings and cables."),
                   ("Fitting", "Saddle, bar and cleat setup so a long ride stays comfortable.")],
         about="We started by fixing friends' bikes in a garage. The workshop is bigger now, but we still write down what we did on every job and explain it when you collect.",
         work=["Steel touring frame rebuild", "Commuter hub conversion", "Wheelbuilding notes", "Winter maintenance guide"]),
    dict(suffix=["Photo", "Studio", "Images"],
         tagline="Portrait, product and architectural photography.",
         intro="We photograph people, objects and buildings in natural light wherever possible, and deliver tidy, well-labelled files.",
         services=[("Portraits", "Relaxed sessions for teams, families and individuals, on location or in the studio."),
                   ("Product", "Clean, consistent images for catalogues and online shops."),
                   ("Architecture", "Interiors and exteriors shot at the right hour for the light.")],
         about="Our work grew out of documenting local buildings. Today the studio is two photographers and an editor who cares a great deal about colour.",
         work=["Riverside housing study", "Ceramics catalogue", "Team portraits", "Interior series"]),
    dict(suffix=["Press", "Bindery", "Paperworks"],
         tagline="Letterpress printing and traditional bookbinding.",
         intro="Small editions, notebooks and invitations, printed on a restored platen press and sewn by hand.",
         services=[("Printing", "Letterpress cards, posters and stationery in short runs."),
                   ("Binding", "Hand-sewn notebooks, journals and photo albums."),
                   ("Restoration", "Careful repair of cloth and leather bindings.")],
         about="The press came to us in pieces and took a winter to restore. Everything we print is set, inked and pulled in the same room.",
         work=["Poetry pamphlet edition", "Wedding stationery", "Linen-bound journals", "Repair of a family bible"]),
    dict(suffix=["Gardens", "Landscapes", "Garden Design"],
         tagline="Planting plans and small-scale landscape design.",
         intro="We design courtyards, allotments and urban gardens that look good in winter and need little watering in summer.",
         services=[("Design", "Measured plans, plant lists and a clear schedule of work."),
                   ("Planting", "Seasonal planting with locally grown stock."),
                   ("Care", "Regular visits, pruning and soil care for established gardens.")],
         about="We are a small office of designers and growers. Our plans are drawn by hand first, then tidied, and always include a planting calendar.",
         work=["Courtyard in raised beds", "Dry garden planting", "Allotment layout", "Hedgerow restoration"]),
    dict(suffix=["Joinery", "Woodworks", "Carpentry"],
         tagline="Furniture and fitted joinery made to measure.",
         intro="Tables, shelves and built-in storage, cut from responsibly sourced timber and finished with natural oils.",
         services=[("Furniture", "Dining tables, benches and shelving in oak, ash and walnut."),
                   ("Fitted work", "Alcove shelving, wardrobes and kitchen details."),
                   ("Repairs", "Re-gluing, re-veneering and refinishing of older pieces.")],
         about="Our workshop is a converted barn with more clamps than chairs. We draw every piece to scale before cutting a single board.",
         work=["Oak refectory table", "Alcove bookcase", "Ash stools", "Pine kitchen refit"]),
]
FIRST = ["Alder", "Birch", "Cobalt", "Harbor", "Juniper", "Larch", "Marlow", "North", "Oak", "Pine",
         "Quill", "Rowan", "Slate", "Tern", "Willow", "Ember", "Fern", "Linden", "Moss", "Sable"]

k = rnd.choice(KINDS)
brand = f"{rnd.choice(FIRST)} {rnd.choice(k['suffix'])}"
year = datetime.date.today().year

hue = rnd.random()
def hsl(h, s, l):
    r, g, b = colorsys.hls_to_rgb(h % 1.0, l, s)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))
bg, panel = hsl(hue, 0.25, 0.97), hsl(hue, 0.25, 0.93)
accent, accent_dark = hsl(hue, 0.55, 0.33), hsl(hue, 0.55, 0.22)
text, muted, line = hsl(hue, 0.20, 0.14), hsl(hue, 0.10, 0.38), hsl(hue, 0.18, 0.84)
font = rnd.choice([
    'Georgia, "Times New Roman", serif',
    '-apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
    '"Iowan Old Style", "Palatino Linotype", Palatino, serif',
    'system-ui, "Segoe UI", Helvetica, Arial, sans-serif'])
width = rnd.choice([880, 960, 1040])
radius = rnd.choice([0, 4, 10])
layout = rnd.choice(["grid", "list"])
centered = rnd.choice([True, False])

hero_align = "center" if centered else "left"
hero_margin = "margin:0 auto;" if centered else "margin:0;"
if layout == "grid":
    cards_css = "display:grid; grid-template-columns:repeat(auto-fit,minmax(230px,1fr)); gap:18px;"
    card_css = f"border:1px solid var(--line); border-radius:{radius}px;"
else:
    cards_css = "display:block;"
    card_css = f"margin-bottom:14px; border-left:4px solid var(--accent); border-radius:{radius}px;"

css = f""":root {{ --bg:{bg}; --panel:{panel}; --accent:{accent}; --accent-dark:{accent_dark};
  --text:{text}; --muted:{muted}; --line:{line}; }}
* {{ box-sizing: border-box; }}
body {{ margin:0; background:var(--bg); color:var(--text); font-family:{font}; line-height:1.65; }}
.wrap {{ max-width:{width}px; margin:0 auto; padding:0 20px; }}
header {{ border-bottom:1px solid var(--line); }}
header .wrap {{ display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:12px; padding-top:18px; padding-bottom:18px; }}
.brand {{ font-size:1.25rem; font-weight:700; color:var(--accent-dark); text-decoration:none; letter-spacing:.01em; }}
nav a {{ margin-left:18px; color:var(--muted); text-decoration:none; }}
nav a:hover, nav a.on {{ color:var(--accent); }}
.hero {{ padding:64px 0 40px; text-align:{hero_align}; }}
.hero h1 {{ font-size:2.2rem; line-height:1.2; margin:0 0 12px; color:var(--accent-dark); }}
.hero p {{ font-size:1.1rem; color:var(--muted); max-width:640px; {hero_margin} }}
h2 {{ font-size:1.35rem; margin:36px 0 12px; color:var(--accent-dark); }}
.cards {{ {cards_css} }}
.card {{ background:var(--panel); padding:18px 20px; {card_css} }}
.card h3 {{ margin:0 0 6px; font-size:1.05rem; }}
.card p {{ margin:0; color:var(--muted); }}
ul.plain {{ padding-left:20px; }}
a {{ color:var(--accent); }}
footer {{ margin-top:56px; border-top:1px solid var(--line); color:var(--muted); font-size:.9rem; }}
footer .wrap {{ padding-top:20px; padding-bottom:28px; }}
main {{ min-height:50vh; }}
"""

shapes = [
    f'<circle cx="32" cy="32" r="26" fill="{accent}"/><circle cx="32" cy="32" r="11" fill="{bg}"/>',
    f'<rect x="8" y="8" width="48" height="48" rx="{radius + 4}" fill="{accent}"/><rect x="22" y="22" width="20" height="20" fill="{bg}"/>',
    f'<path d="M32 6 58 56H6Z" fill="{accent}"/><path d="M32 26 44 50H20Z" fill="{bg}"/>',
]
favicon = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">{rnd.choice(shapes)}</svg>\n'

NAV = [("/", "Home"), ("/work", "Work"), ("/about", "About"), ("/privacy", "Privacy")]

def page(title, active, body):
    links = []
    for href, label in NAV:
        cls = ' class="on"' if href == active else ""
        links.append(f'<a href="{href}"{cls}>{label}</a>')
    nav = "".join(links)
    return (f'<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            f'<title>{esc(title)}</title>\n'
            f'<meta name="description" content="{esc(k["tagline"])}">\n'
            f'<link rel="icon" href="/favicon.svg" type="image/svg+xml">\n'
            f'<link rel="stylesheet" href="/styles.css">\n</head>\n<body>\n'
            f'<header><div class="wrap"><a class="brand" href="/">{esc(brand)}</a>'
            f'<nav>{nav}</nav></div></header>\n<main>\n{body}\n</main>\n'
            f'<footer><div class="wrap">&copy; {year} {esc(brand)}. All rights reserved.</div></footer>\n'
            f'</body>\n</html>\n')

cards = "".join(f'<div class="card"><h3>{esc(t)}</h3><p>{esc(d)}</p></div>' for t, d in k["services"])
tagline_plain = k["tagline"].rstrip(".")
index = page(f"{brand} - {tagline_plain}", "/",
    f'<div class="wrap"><section class="hero"><h1>{esc(k["tagline"])}</h1><p>{esc(k["intro"])}</p></section>'
    f'<h2>What we do</h2><div class="cards">{cards}</div></div>')

NOTES = ["Completed this year.", "An ongoing series.", "Documented in our notes.", "Made in small numbers."]
work_items = rnd.sample(k["work"], len(k["work"]))
work_cards = "".join(
    f'<div class="card"><h3>{esc(w)}</h3><p>{esc(rnd.choice(NOTES))}</p></div>' for w in work_items)
work = page(f"Work - {brand}", "/work",
    f'<div class="wrap"><section class="hero"><h1>Selected work</h1><p>A few recent projects from the {esc(brand)} archive.</p></section>'
    f'<div class="cards">{work_cards}</div></div>')

about = page(f"About - {brand}", "/about",
    f'<div class="wrap"><section class="hero"><h1>About us</h1><p>{esc(k["about"])}</p></section>'
    f'<h2>How we work</h2><ul class="plain"><li>We agree scope and price before we start.</li>'
    f'<li>We keep you informed at every stage.</li><li>We stand behind what we make.</li></ul></div>')

privacy = page(f"Privacy - {brand}", "/privacy",
    '<div class="wrap"><section class="hero"><h1>Privacy</h1>'
    '<p>This website does not use cookies, analytics or third-party services, and it does not collect personal data.</p></section></div>')

notfound = page(f"Page not found - {brand}", "",
    '<div class="wrap"><section class="hero"><h1>Page not found</h1>'
    '<p>The page you were looking for does not exist. <a href="/">Return to the home page</a>.</p></section></div>')

files = {"index.html": index, "work.html": work, "about.html": about, "privacy.html": privacy,
         "404.html": notfound, "styles.css": css, "favicon.svg": favicon,
         "robots.txt": "User-agent: *\nAllow: /\n"}
for name, content in files.items():
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        fh.write(content)
print(brand)
PY
}

resolve_site_source() {
  local tmp f
  if [[ -n $SITE_DIR_ARG ]]; then
    [[ -d $SITE_DIR_ARG ]] || die "--site-dir: нет каталога $SITE_DIR_ARG"
    SITE_SRC="$SITE_DIR_ARG"
  elif [[ -n $SITE_ARCHIVE ]]; then
    tmp=$(mktemp -d); TMPDIRS+=("$tmp"); f="$tmp/archive"
    if [[ $SITE_ARCHIVE =~ ^https:// ]]; then
      curl -fsSL --proto '=https' --proto-redir '=https' -o "$f" "$SITE_ARCHIVE"
    elif [[ $SITE_ARCHIVE =~ ^http:// ]]; then
      die "--site-archive: только https:// или локальный путь"
    else
      [[ -f $SITE_ARCHIVE ]] || die "--site-archive: нет файла $SITE_ARCHIVE"
      cp "$SITE_ARCHIVE" "$f"
    fi
    mkdir "$tmp/x"
    case "$SITE_ARCHIVE" in
      *.zip) unzip -q "$f" -d "$tmp/x" ;;
      *)     tar -xf "$f" -C "$tmp/x" ;;
    esac
    SITE_SRC="$tmp/x"
  elif [[ -n $SITE_GIT ]]; then
    tmp=$(mktemp -d); TMPDIRS+=("$tmp")
    git clone -q --depth 1 "$SITE_GIT" "$tmp/x"
    SITE_SRC="$tmp/x"
  elif (( SITE_AUTO )); then
    tmp=$(mktemp -d); TMPDIRS+=("$tmp")
    log "Генерирую сайт-заглушку: $(generate_site "$tmp/x")"
    SITE_SRC="$tmp/x"
  elif [[ -f $SITE_DST/index.html ]]; then
    SITE_SRC=""            # повторный запуск: оставляем уже установленный сайт
    return 0
  elif [[ $RESOLVED_MODE == remnawave && -f /var/www/html/index.html ]]; then
    warn "Источник сайта не указан — копирую /var/www/html. Релей отдаёт сайт с жёсткой политикой CSP (без inline-скриптов/стилей и внешних ресурсов); при необходимости передайте --site-dir."
    SITE_SRC=/var/www/html
  else
    tmp=$(mktemp -d); TMPDIRS+=("$tmp")
    log "Источник сайта не указан — генерирую заглушку: $(generate_site "$tmp/x")"
    warn "Сгенерированный сайт уникален для этого сервера, но структура у всех установок общая; для лучшей маскировки передайте свой --site-dir."
    SITE_SRC="$tmp/x"
  fi
  # если index.html лежит уровнем ниже (типичный архив с одной папкой)
  if [[ ! -f $SITE_SRC/index.html ]]; then
    local subs; mapfile -t subs < <(find "$SITE_SRC" -mindepth 1 -maxdepth 1 -type d ! -name '.git')
    if [[ ${#subs[@]} -eq 1 && -f ${subs[0]}/index.html ]]; then SITE_SRC="${subs[0]}"; fi
  fi
  [[ -f $SITE_SRC/index.html ]] || die "В источнике сайта нет index.html ($SITE_SRC)"
}

lint_site() {
  local d=$1 out
  check() {  # описание, regex, include
    out=$(grep -rIlP --include="$3" -e "$2" "$d" 2>/dev/null | head -5 || true)
    if [[ -n $out ]]; then warn "CSP relay заблокирует: $1 — $(echo "$out" | tr '\n' ' ')"; fi
  }
  check "inline <style>"                '<style'                                       '*.html'
  check "inline <script>"               '<script(?![^>]*\bsrc\s*=)'                    '*.html'
  check "inline style=\"...\""          '\sstyle\s*='                                  '*.html'
  check "inline-обработчики on*="       '\son[a-z]+\s*='                               '*.html'
  check "внешние стили/скрипты/картинки" '<link[^>]*href\s*=\s*["'"'"']?https?://|<(script|img|iframe|source)[^>]*src\s*=\s*["'"'"']?(https?:)?//' '*.html'
  check "внешние ресурсы в CSS"         '@import\s+(url\()?["'"'"']?https?://|url\(\s*["'"'"']?https?://' '*.css'
  check "формы (form-action none)"      '<form'                                        '*.html'
  return 0
}

install_site() {
  step "Сайт-заглушка для relay"
  resolve_site_source
  if [[ -z $SITE_SRC ]]; then log "Оставляю существующий $SITE_DST"; return 0; fi
  rm -rf "$SITE_DST.new"; mkdir -p "$SITE_DST.new"
  cp -rL "$SITE_SRC"/. "$SITE_DST.new"/
  rm -rf "$SITE_DST.new/.git"
  [[ -f $SITE_DST.new/index.html ]] || die "После копирования нет index.html"
  chmod -R a+rX "$SITE_DST.new"
  lint_site "$SITE_DST.new"
  if [[ -d $SITE_DST ]]; then rm -rf "$SITE_DST.old"; mv "$SITE_DST" "$SITE_DST.old"; fi
  mv "$SITE_DST.new" "$SITE_DST"
  CHANGED_BIN=1   # relay читает сайт только при старте
  log "Сайт установлен в $SITE_DST"
}

# ------------------------------------------------------------------ конфиги relay
# --- пользователи: users.json — источник правды; из него генерируются profiles.json
#     (relay) и список -S для официального MTProxy. Один общий бэкенд 127.0.0.1:2398.
users_py() {   # users_py ДЕЙСТВИЕ ФАЙЛ [аргументы...]
  python3 -I - "$@" <<'PY'
import datetime, json, os, re, sys

a = sys.argv[1:]
act, path = a[0], a[1]
NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
HEX = re.compile(r"^[0-9a-f]{32}$")
MAX_ENABLED, MAX_TOTAL = 16, 32     # 16 — предел числа -S у официального MTProxy; 32 — max_profiles relay


def fail(msg, code=1):
    print("ОШИБКА: " + msg, file=sys.stderr)
    sys.exit(code)


def load():
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        fail(f"не удалось прочитать {path}: {e}")


def save(d, p=None, mode=0o600):
    p = p or path
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, p)


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def enabled(d):
    return [u for u in d["users"] if u.get("enabled", True)]


def find(d, name):
    for u in d["users"]:
        if u["name"] == name:
            return u
    fail(f"пользователь «{name}» не найден")


def main():
    if act == "init":
        secret, sessions = a[2], int(a[3])
        if os.path.exists(path):
            return
        if not HEX.match(secret):
            fail("секрет: ровно 32 символа [0-9a-f]")
        save({"default_max_sessions": sessions,
              "users": [{"name": "default", "secret": secret, "enabled": True,
                         "created": now(), "max_sessions": sessions}]})
    elif act == "migrate":
        prof, sessions = a[2], int(a[3])
        try:
            with open(prof, encoding="utf-8") as f:
                ps = json.load(f)["profiles"]
        except Exception as e:
            fail(f"не удалось прочитать {prof}: {e}")
        users, seen = [], set()
        for pr in ps:
            n = re.sub(r"[^a-z0-9_-]", "-", str(pr.get("name", "user")).lower()).strip("-_")[:32] or "user"
            base, i = n, 2
            while n in seen:
                n = f"{base[:28]}-{i}"
                i += 1
            seen.add(n)
            ms = int(pr.get("limits", {}).get("max_sessions", sessions))
            users.append({"name": n, "secret": pr["secret"], "enabled": True,
                          "created": now(), "max_sessions": ms})
        if not users:
            fail("в profiles.json нет профилей")
        save({"default_max_sessions": sessions, "users": users})
    elif act == "first":
        e = enabled(load())
        if not e:
            sys.exit(3)
        print(e[0]["secret"])
    elif act == "args":
        print(" ".join("-S " + u["secret"] for u in enabled(load())))
    elif act == "has-secret":
        sys.exit(0 if any(u["secret"] == a[2] for u in load()["users"]) else 1)
    elif act == "list":
        d = load()
        dm = d.get("default_max_sessions", 6)
        for u in d["users"]:
            print("\t".join([u["name"], "1" if u.get("enabled", True) else "0", u["secret"],
                             u.get("created", "-"), str(u.get("max_sessions", dm))]))
    elif act == "add":
        name, secret, sessions = a[2], a[3], int(a[4])
        if not NAME.match(name):
            fail("имя: строчные латинские буквы, цифры, - и _ (до 32 символов, начинается с буквы/цифры)")
        if not HEX.match(secret):
            fail("секрет: ровно 32 символа [0-9a-f]")
        d = load()
        if any(u["name"] == name for u in d["users"]):
            fail(f"пользователь «{name}» уже существует")
        if any(u["secret"] == secret for u in d["users"]):
            fail("такой секрет уже используется")
        if len(d["users"]) >= MAX_TOTAL:
            fail(f"не более {MAX_TOTAL} пользователей (max_profiles relay)")
        if len(enabled(d)) >= MAX_ENABLED:
            fail(f"не более {MAX_ENABLED} активных пользователей (предел числа секретов -S у MTProxy); отключите или удалите кого-то")
        d["users"].append({"name": name, "secret": secret, "enabled": True,
                           "created": now(), "max_sessions": sessions})
        save(d)
    elif act == "set":
        name, state = a[2], a[3]
        d = load()
        u = find(d, name)
        if state == "disabled":
            if u.get("enabled", True) and len(enabled(d)) <= 1:
                fail("нельзя отключить последнего активного пользователя (relay без профилей не запустится)", 4)
            u["enabled"] = False
        elif state == "enabled":
            if not u.get("enabled", True) and len(enabled(d)) >= MAX_ENABLED:
                fail(f"не более {MAX_ENABLED} активных пользователей")
            u["enabled"] = True
        else:
            fail("состояние: enabled|disabled")
        save(d)
    elif act == "delete":
        name = a[2]
        d = load()
        u = find(d, name)
        if u.get("enabled", True) and len(enabled(d)) <= 1:
            fail("нельзя удалить последнего активного пользователя", 4)
        d["users"] = [x for x in d["users"] if x["name"] != name]
        save(d)
    elif act == "limit":
        name, n = a[2], int(a[3])
        if not 1 <= n <= 1000:
            fail("лимит сессий: число от 1 до 1000")
        d = load()
        find(d, name)["max_sessions"] = n
        save(d)
    elif act == "gen":
        out = a[2]
        d = load()
        dm = d.get("default_max_sessions", 6)
        profs = [{"name": u["name"], "secret": u["secret"], "backend": "127.0.0.1:2398",
                  "carrier_mode": "https",
                  "limits": {"max_sessions": int(u.get("max_sessions", dm))}} for u in enabled(d)]
        if not profs:
            fail("нет активных пользователей", 3)
        save({"profiles": profs}, out, 0o400)
    else:
        fail(f"неизвестное действие: {act}")


try:
    main()
except (ValueError, IndexError, KeyError) as e:
    fail(f"некорректные аргументы/данные ({type(e).__name__}: {e})")
PY
}

# Подбор глобальных лимитов relay под ресурсы сервера. Лимиты НЕ считают и не мониторят
# ничего: это потолки, лишние подключения просто отклоняются. По IP не лимитируем.
tune_config() {   # tune_config config.json
  local ram; ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  RAM_MB=$ram python3 -I - "$1" <<'PY'
import json, os, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    c = json.load(f)
l = c.setdefault("limits", {})
l["max_sessions_per_ip"] = 0          # без лимита по IP (CGNAT операторов)
l["max_bootstraps_per_ip"] = 0
if int(os.environ["RAM_MB"]) <= 2048:  # слабый сервер: не даём relay съесть память рядом с Xray/docker
    l["max_sessions_global"] = 64
    l["max_streams_global"] = 1024
    l["max_pending_global"] = 134217728       # 128 МиБ (по умолчанию 512)
    l["max_pending_per_session"] = 8388608    # 8 МиБ (по умолчанию 32)
with open(p, "w", encoding="utf-8") as f:
    json.dump(c, f, indent=2)
PY
}

gen_relay_config() {   # gen_relay_config 0|1   (1 — подобрать лимиты по ресурсам)
  DOMAIN="$DOMAIN" SRC="$SRC" CONF_DIR="$CONF_DIR" SITE_DST="$SITE_DST" python3 -I - <<'PY'
import json, os
src, conf = os.environ["SRC"], os.environ["CONF_DIR"]
with open(f"{src}/config.example.json", encoding="utf-8") as f:
    c = json.load(f)
c["public_hostname"] = os.environ["DOMAIN"]
c.pop("public_upstream", None)
c["public_dir"] = os.environ["SITE_DST"]
with open(f"{conf}/config.json", "w", encoding="utf-8") as f:
    json.dump(c, f, indent=2)
PY
  chmod 0644 "$CONF_DIR/config.json"
  if [[ $1 == 1 ]]; then tune_config "$CONF_DIR/config.json"; fi
  return 0
}

relay_check() {   # relay_check [profiles-файл]
  /usr/local/bin/tproxy-server -config "$CONF_DIR/config.json" -profiles-file "${1:-$CONF_DIR/profiles.json}" -check
}

wait_ready() {
  local i code=""
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/readyz || true)
    if [[ $code == 200 ]]; then return 0; fi
    sleep 1
  done
  journalctl -u mtproxy -u tproxy-server --since '3 min ago' --no-pager 2>/dev/null | tail -20 || true
  return 1
}

# Секреты MTProxy: -S <секрет> на каждого активного пользователя. Штатный юнит содержит
# один "-S ${MTPROXY_SECRET}" (в фигурных скобках — одним аргументом), поэтому ExecStart
# переопределяется drop-in'ом на "$MTPROXY_SECRET_ARGS" (без скобок — делится по пробелам).
write_mtproxy_env() {
  local unit=/etc/systemd/system/mtproxy.service envf=/etc/mtproxy/mtproxy.env
  local dropdir=/etc/systemd/system/mtproxy.service.d args first tmp execline
  [[ -f $unit ]] || { warn "Нет $unit"; return 1; }
  grep -q '^ExecStart=.*-S \${MTPROXY_SECRET}' "$unit" \
    || { warn "В $unit не найден '-S \${MTPROXY_SECRET}' — формат юнита изменился"; return 1; }
  args=$(users_py args "$USERS_FILE") || return 1
  first=$(users_py first "$USERS_FILE") || return 1
  tmp=$(mktemp)
  printf 'MTPROXY_SECRET=%s\nMTPROXY_SECRET_ARGS="%s"\n' "$first" "$args" > "$tmp"
  MT_ENV_CHANGED=0
  cmp -s "$tmp" "$envf" 2>/dev/null || MT_ENV_CHANGED=1
  install -m 0600 -o root -g root "$tmp" "$envf"
  rm -f "$tmp"
  execline=$(grep -m1 '^ExecStart=' "$unit" | sed 's/-S \${MTPROXY_SECRET}/$MTPROXY_SECRET_ARGS/')
  mkdir -p "$dropdir"
  printf '[Service]\nExecStart=\n%s\n' "$execline" > "$dropdir/secrets.conf"
  return 0
}

# Применить users.json: сгенерировать profiles.json, проверить, обновить секреты MTProxy
# (перезапуск mtproxy только если список -S изменился) и перезапустить relay.
users_apply() {
  local newp="$CONF_DIR/profiles.json.new"
  users_py gen "$USERS_FILE" "$newp" || return 1
  if ! relay_check "$newp"; then rm -f "$newp"; return 1; fi
  write_mtproxy_env || { rm -f "$newp"; return 1; }
  mv -f "$newp" "$CONF_DIR/profiles.json"
  systemctl daemon-reload
  if (( MT_ENV_CHANGED )); then
    log "Список секретов MTProxy изменился — перезапускаю mtproxy"
    systemctl restart mtproxy
    sleep 2
  fi
  systemctl restart tproxy-server
  wait_ready || warn "relay не отвечает на /readyz — проверьте: journalctl -u tproxy-server -u mtproxy"
  return 0
}

# Изменение users.json с откатом, если новая конфигурация не прошла проверку relay.
users_mutate() {   # users_mutate ДЕЙСТВИЕ аргументы...   (файл подставляется)
  cp -a "$USERS_FILE" "$USERS_FILE.prev"
  if ! users_py "$1" "$USERS_FILE" "${@:2}"; then rm -f "$USERS_FILE.prev"; return 1; fi
  if ! users_apply; then
    mv -f "$USERS_FILE.prev" "$USERS_FILE"
    warn "Изменение отменено: новая конфигурация не прошла проверку relay."
    return 1
  fi
  rm -f "$USERS_FILE.prev"
  return 0
}

write_configs() {
  step "Секрет, пользователи и конфиги relay"
  install -d -m 0755 "$CONF_DIR"
  if [[ -f $USERS_FILE ]]; then
    log "Использую существующий список пользователей"
  elif [[ -f $CONF_DIR/profiles.json ]]; then
    users_py migrate "$USERS_FILE" "$CONF_DIR/profiles.json" "$USER_SESSIONS" || die "Не удалось перенести профили в $USERS_FILE"
    log "Профили из profiles.json перенесены в $USERS_FILE"
  else
    if [[ -z $SECRET ]]; then SECRET=$(openssl rand -hex 16); fi
    users_py init "$USERS_FILE" "$SECRET" "$USER_SESSIONS" || die "Не удалось создать $USERS_FILE"
  fi
  chmod 0600 "$USERS_FILE"
  if [[ -n $SECRET ]] && ! users_py has-secret "$USERS_FILE" "$SECRET"; then
    die "Пользователи уже существуют, а указанного --secret среди них нет. Добавьте его: setup-tproxy.sh users add ИМЯ --secret ..."
  fi
  if [[ -f $CONF_DIR/config.json ]]; then
    local oh; oh=$(python3 -c "import json;print(json.load(open('$CONF_DIR/config.json')).get('public_hostname',''))")
    [[ $oh == "$DOMAIN" ]] || die "relay уже настроен для другого hostname ($oh). Один relay обслуживает один hostname — сначала удалите его (команда uninstall)."
  fi
  gen_relay_config 1
  users_py gen "$USERS_FILE" "$CONF_DIR/profiles.json" || die "Не удалось сгенерировать profiles.json"
  if ! relay_check; then
    warn "Проверка с подобранными лимитами не прошла — использую лимиты по умолчанию."
    gen_relay_config 0
    relay_check || die "Проверка конфигурации relay (-check) не прошла"
  fi
  SECRET=$(users_py first "$USERS_FILE")
}

# ------------------------------------------------------------------ обновление конфига MTProxy
# MTProxy читает proxy-multi.conf (адреса дата-центров Telegram) только при запуске, а Telegram
# время от времени их меняет — поэтому раз в сутки файл скачивается заново. Новый файл проверяется
# (размер, строки default/proxy_for), подменяется атомарно, MTProxy перезапускается ТОЛЬКО если
# файл изменился; если после перезапуска relay перестал быть готовым — возвращается прежний файл.
REFRESH_BIN=/usr/local/sbin/tproxy-refresh-mtproxy.sh
REFRESH_UNIT=tproxy-mtproxy-refresh

install_refresh_timer() {
  step "Таймер обновления конфига MTProxy"
  install -d -m 0755 "$(dirname "$REFRESH_BIN")"
  cat > "$REFRESH_BIN" <<'EOF'
#!/bin/sh
# Обновление proxy-multi.conf официального MTProxy (устанавливается setup-tproxy.sh).
set -eu
cfg=/etc/mtproxy/proxy-multi.conf
url=https://core.telegram.org/getProxyConfig
[ -f "$cfg" ] || { echo "нет $cfg"; exit 1; }
tmp=$(mktemp /etc/mtproxy/proxy-multi.conf.XXXXXX)
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
     --tlsv1.2 --max-time 60 --output "$tmp" "$url"
[ "$(wc -c < "$tmp")" -ge 100 ] || { echo "скачанный файл слишком мал — отбрасываю"; exit 1; }
grep -q '^default ' "$tmp"   || { echo "в файле нет строки 'default' — отбрасываю"; exit 1; }
grep -q '^proxy_for ' "$tmp" || { echo "в файле нет строк 'proxy_for' — отбрасываю"; exit 1; }
if cmp -s "$tmp" "$cfg"; then
  echo "proxy-multi.conf не изменился"
  exit 0
fi
chown --reference="$cfg" "$tmp"
chmod --reference="$cfg" "$tmp"
ready() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8081/readyz 2>/dev/null || true; }
before=$(ready)
cp -p "$cfg" "$cfg.prev"
mv -f "$tmp" "$cfg"
trap - EXIT
echo "proxy-multi.conf изменился — перезапускаю mtproxy"
systemctl restart mtproxy
if [ "$before" = 200 ]; then
  i=0
  while [ "$i" -lt 30 ]; do
    [ "$(ready)" = 200 ] && { rm -f "$cfg.prev"; echo "готово: relay снова готов"; exit 0; }
    i=$((i + 1)); sleep 1
  done
  echo "после обновления relay не стал готовым — возвращаю прежний proxy-multi.conf"
  mv -f "$cfg.prev" "$cfg"
  systemctl restart mtproxy
  exit 1
fi
rm -f "$cfg.prev"
echo "готово (relay до обновления не был готов — откат не требуется)"
EOF
  chmod 0755 "$REFRESH_BIN"
  cat > "/etc/systemd/system/$REFRESH_UNIT.service" <<EOF
[Unit]
Description=Refresh Telegram MTProxy routing config (proxy-multi.conf)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$REFRESH_BIN
ProtectSystem=strict
ReadWritePaths=/etc/mtproxy
ProtectHome=true
PrivateTmp=true
EOF
  cat > "/etc/systemd/system/$REFRESH_UNIT.timer" <<'EOF'
[Unit]
Description=Daily refresh of Telegram MTProxy routing config

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$REFRESH_UNIT.timer" >/dev/null 2>&1 || systemctl enable "$REFRESH_UNIT.timer" || true
  log "Таймер $REFRESH_UNIT.timer включён (раз в сутки, со случайной задержкой до часа)"
  return 0
}

do_refresh() {
  [[ -f /etc/systemd/system/mtproxy.service && -f /etc/mtproxy/proxy-multi.conf ]] \
    || die "MTProxy не установлен (нет mtproxy.service или /etc/mtproxy/proxy-multi.conf)."
  install_refresh_timer
  log "Обновляю proxy-multi.conf прямо сейчас..."
  if systemctl start "$REFRESH_UNIT.service"; then
    journalctl -u "$REFRESH_UNIT.service" -n 4 --no-pager -o cat 2>/dev/null >&3 || true
    log "Готово."
  else
    journalctl -u "$REFRESH_UNIT.service" -n 8 --no-pager -o cat 2>/dev/null >&3 || true
    die "Обновление не удалось (подробности выше). Прежний proxy-multi.conf сохранён."
  fi
}

# ------------------------------------------------------------------ КОМАНДА: users
users_ensure_file() {
  if [[ ! -f $USERS_FILE ]]; then
    [[ -f $CONF_DIR/profiles.json ]] || die "Нет $USERS_FILE и $CONF_DIR/profiles.json — веб-прокси не установлен."
    users_py migrate "$USERS_FILE" "$CONF_DIR/profiles.json" "$USER_SESSIONS" || die "Не удалось создать $USERS_FILE"
    chmod 0600 "$USERS_FILE"
    log "Создан $USERS_FILE из существующих профилей relay"
  fi
  return 0
}

users_load_ctx() {
  load_context
  [[ -n $DOMAIN && -f $CONF_DIR/config.json ]] || die "Веб-прокси не установлен (нет $CONF_DIR/config.json)."
  users_ensure_file
}

# Таблица пользователей (в stdout). Ссылки показываются только для активных.
users_list_body() {
  local n en sec cr ms tmp
  echo
  printf '%-16s %-6s %-9s %s\n' "NAME" "STATE" "SESSIONS" "LINK"
  while IFS=$'\t' read -r n en sec cr ms; do
    if [[ $en == 1 ]]; then
      printf '%-16s %-6s %-9s %s\n' "$n" "on" "$ms" "https://t.me/webproxy?server=$DOMAIN&secret=$sec"
    else
      printf '%-16s %-6s %-9s %s\n' "$n" "off" "$ms" "-"
    fi
  done < <(users_py list "$USERS_FILE")
  # профили relay должны соответствовать users.json (например, после миграции)
  tmp=$(mktemp -u "$CONF_DIR/.gen.XXXXXX")
  if users_py gen "$USERS_FILE" "$tmp" 2>/dev/null; then
    if ! cmp -s "$tmp" "$CONF_DIR/profiles.json" 2>/dev/null; then
      echo
      echo "ВНИМАНИЕ: profiles.json не соответствует users.json (лимиты/секреты не применены)."
      echo "          Выполните: setup-tproxy.sh users apply"
    fi
  fi
  rm -f "$tmp"
  return 0
}
users_list() { { users_list_body; } >&3; }

users_add() {
  local name=${1:-} sec=$SECRET
  [[ -n $name ]] || die "Укажите имя: users add ИМЯ"
  name=${name,,}
  if [[ -z $sec ]]; then sec=$(openssl rand -hex 16); fi
  users_mutate add "$name" "$sec" "$USER_SESSIONS" || die "Не удалось добавить пользователя"
  {
    echo
    echo "Пользователь $name добавлен (одновременных сессий: $USER_SESSIONS)."
    echo "Ссылка: https://t.me/webproxy?server=$DOMAIN&secret=$sec"
  } >&3
}

users_set() {   # users_set ИМЯ enabled|disabled
  local name=${1:-} st=$2
  [[ -n $name ]] || die "Укажите имя пользователя"
  name=${name,,}
  users_mutate set "$name" "$st" || die "Не удалось изменить пользователя $name"
  if [[ $st == disabled ]]; then
    log "Пользователь $name отключён: relay больше не принимает его секрет (его сессии оборваны)."
  else
    log "Пользователь $name включён (секрет прежний)."
  fi
}

users_delete() {
  local name=${1:-}
  [[ -n $name ]] || die "Укажите имя пользователя"
  name=${name,,}
  confirm "Удалить пользователя $name безвозвратно (секрет будет потерян)?" || { log "Отменено."; return 0; }
  users_mutate delete "$name" || die "Не удалось удалить пользователя $name"
  log "Пользователь $name удалён."
}

users_limit() {
  local name=${1:-} n=${2:-}
  [[ -n $name && $n =~ ^[0-9]+$ ]] || die "Использование: users limit ИМЯ N"
  users_mutate limit "${name,,}" "$n" || die "Не удалось изменить лимит"
  log "Лимит сессий пользователя ${name,,}: $n"
}

users_tune_limits() {
  local cfg=$CONF_DIR/config.json
  cp -a "$cfg" "$cfg.prev"
  tune_config "$cfg"
  if ! relay_check; then
    mv -f "$cfg.prev" "$cfg"
    die "Новые лимиты не прошли проверку relay — config.json возвращён."
  fi
  rm -f "$cfg.prev"
  systemctl restart tproxy-server
  wait_ready || warn "relay не отвечает на /readyz после смены лимитов"
  log "Глобальные лимиты relay обновлены (см. 'show'); лимит по IP отключён."
}

users_apply_cmd() {
  users_apply || die "Не удалось применить конфигурацию (проверка relay не прошла)."
  log "Конфигурация пользователей применена."
}

do_users() {
  users_load_ctx
  local sub=${USER_ARGS[0]:-list} name=${USER_ARGS[1]:-} arg3=${USER_ARGS[2]:-}
  case "$sub" in
    list)    users_list ;;
    add)     users_add "$name" ;;
    disable) users_set "$name" disabled ;;
    enable)  users_set "$name" enabled ;;
    delete)  users_delete "$name" ;;
    limit)   users_limit "$name" "$arg3" ;;
    limits)  users_tune_limits ;;
    apply)   users_apply_cmd ;;
    *) die "Неизвестная подкоманда users: $sub (list|add|disable|enable|delete|limit|limits|apply)" ;;
  esac
}

# ------------------------------------------------------------------ MTProxy + systemd
install_backend() {
  step "MTProxy и systemd-юниты"
  "$SRC/deploy/install-mtproxy.sh"
  local u
  for u in mtproxy tproxy-server; do
    sed -e '/^Requires=tproxy-firewall.service$/d' \
        -e 's/ tproxy-firewall.service//' \
        "$SRC/deploy/$u.service" > "/etc/systemd/system/$u.service"
  done

  # Закрываем 2398/8888 (MTProxy слушает 0.0.0.0) обычными iptables-правилами.
  # Родной tproxy-firewall не ставим: его nftables.service делает "flush ruleset"
  # и сносит правила Docker.
  cat > /etc/systemd/system/backend-firewall.service <<'EOF'
[Unit]
Description=Drop external access to MTProxy ports
After=network-pre.target docker.service
Before=mtproxy.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -C INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP 2>/dev/null || iptables -I INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP'
ExecStart=-/bin/sh -c 'ip6tables -C INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP 2>/dev/null || ip6tables -I INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP'
ExecStop=-/bin/sh -c 'iptables -D INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP; ip6tables -D INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP; true'

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p /etc/systemd/system/mtproxy.service.d
  cat > /etc/systemd/system/mtproxy.service.d/firewall.conf <<'EOF'
[Unit]
Requires=backend-firewall.service
After=backend-firewall.service
EOF

  # За NAT MTProxy нужен --nat-info, иначе молча не отвечает клиентам.
  if ! grep -qx "$PUBLIC_IP" <<<"$(printf '%s\n' "${LOCAL4[@]}")"; then
    local lip="${LOCAL4[0]:-}"
    warn "Публичный IP не висит на интерфейсе (NAT) — добавляю --nat-info $lip:$PUBLIC_IP"
    printf '[Service]\nEnvironment="MTPROXY_NAT_ARGS=--nat-info %s:%s"\n' "$lip" "$PUBLIC_IP" \
      > /etc/systemd/system/mtproxy.service.d/nat.conf
  else
    rm -f /etc/systemd/system/mtproxy.service.d/nat.conf
  fi

  write_mtproxy_env || die "Не удалось подготовить секреты MTProxy"
  systemctl daemon-reload
  systemctl enable --now backend-firewall.service
  iptables -C INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP \
    || die "Правило iptables для 2398/8888 не установилось — MTProxy не запускаю"
  systemctl enable --now mtproxy.service
  sleep 2
  systemctl enable tproxy-server.service
  systemctl restart tproxy-server.service

  local i code=""
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/readyz || true)
    [[ $code == 200 ]] && break
    sleep 1
  done
  [[ $code == 200 ]] || {
    journalctl -u mtproxy -u tproxy-server --since '3 min ago' --no-pager | tail -30
    die "relay не готов (/readyz = $code)"
  }
  log "relay и MTProxy запущены, /readyz = 200"
  install_refresh_timer
}

# ------------------------------------------------------------------ Docker / nginx / compose (общие функции)
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
  else return 1; fi
}
init_compose() { COMPOSE=$(compose_cmd) || die "Не найден docker compose"; }

find_compose_file() {
  local f
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f $REMNA_DIR/$f ]]; then echo "$REMNA_DIR/$f"; return 0; fi
  done
  return 1
}

all_running() {
  local id ok=1
  for id in $(cd "$REMNA_DIR" && $COMPOSE ps -q); do
    [[ $(docker inspect -f '{{.State.Running}}' "$id") == true ]] || ok=0
  done
  [[ $ok -eq 1 ]]
}

recreate_stack() {
  ( cd "$REMNA_DIR" && $COMPOSE up -d )
  sleep 8
  all_running
}

# Проверка nginx.conf временным контейнером (боевой не трогаем).
# Пути сертификатов подменяются на /etc/letsencrypt/live/<домен>/.
nginx_test() {
  local conf=$1 img tmpc out
  if (( SKIP_NGINX_TEST )); then return 0; fi
  img=$(docker inspect -f '{{.Config.Image}}' "$NGINX_CTR")
  tmpc=$(mktemp); TMPDIRS+=("$tmpc")
  sed 's#/etc/nginx/ssl/\([^/"]*\)/#/etc/letsencrypt/live/\1/#g' "$conf" > "$tmpc"
  if out=$(docker run --rm -v "$tmpc:/etc/nginx/conf.d/default.conf:ro" -v /etc/letsencrypt:/etc/letsencrypt:ro \
       "$img" nginx -t 2>&1); then
    log "nginx -t: ok"
    return 0
  fi
  printf '%s\n' "$out" | tail -8
  return 1
}

# Работа с server-блоком домена в nginx.conf (брейс-матчинг, маркеры не обязательны):
#   exists  — есть ли server-блок с server_name <домен>
#   extract — вывести его
#   remove  — удалить блок (и map $tp_connection, если на него больше никто не ссылается)
ngx_edit() {   # ngx_edit действие файл домен
  python3 -I - "$@" <<'PY'
import re, sys
action, path, domain = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")

def strip_comment(l):
    out, q = [], None
    for ch in l:
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#":
            break
        out.append(ch)
    return "".join(out)

def find_blocks(ls):
    blocks, depth, start = [], 0, None
    for i, l in enumerate(ls):
        c = strip_comment(l)
        if depth == 0 and re.match(r"\s*(server|map\s+\S+\s+\S+)\s*\{", c):
            start = i
        depth += c.count("{") - c.count("}")
        if depth == 0 and start is not None:
            blocks.append((start, i))
            start = None
    return blocks

dom = r"(?<![\w.-])" + re.escape(domain) + r"(?![\w.-])"
def is_ours(b):
    s, e = b
    if not re.match(r"\s*server\b", lines[s]):
        return False
    body = "\n".join(strip_comment(x) for x in lines[s:e + 1])
    return re.search(r"server_name\s+[^;]*" + dom + r"[^;]*;", body) is not None

ours = [b for b in find_blocks(lines) if is_ours(b)]
if action == "exists":
    sys.exit(0 if ours else 1)
if action == "extract":
    print("\n\n".join("\n".join(lines[s:e + 1]) for s, e in ours))
    sys.exit(0 if ours else 1)
if action == "remove":
    if not ours:
        sys.exit(0)
    kill = set()
    for s, e in ours:
        a = s
        while a - 1 >= 0 and lines[a - 1].lstrip().startswith("# >>> tproxy-web-proxy"):
            a -= 1
        if a - 1 >= 0 and lines[a - 1].strip() == "":
            a -= 1
        kill.update(range(a, e + 1))
        if e + 1 < len(lines) and lines[e + 1].lstrip().startswith("# <<< tproxy-web-proxy"):
            kill.add(e + 1)
    new = [l for i, l in enumerate(lines) if i not in kill]
    rest = "\n".join(new)
    rest_wo_map = re.sub(r"map\s+\$http_upgrade\s+\$tp_connection\s*\{[^}]*\}", "", rest)
    if "$tp_connection" not in rest_wo_map:
        kill2 = set()
        for s, e in find_blocks(new):
            if re.match(r"\s*map\s+\$http_upgrade\s+\$tp_connection\b", new[s]):
                a = s - 1 if s - 1 >= 0 and new[s - 1].strip() == "" else s
                kill2.update(range(a, e + 1))
        new = [l for i, l in enumerate(new) if i not in kill2]
    open(path, "w", encoding="utf-8").write("\n".join(new))
    sys.exit(0)
sys.exit(2)
PY
}

# Выбор бэкапа: .pre-tproxy (оригинал до установки) и *.bak*; печатает путь.
pick_backup() {   # pick_backup целевой_файл [явно_указанный_бэкап]
  local target=$1 preset=${2:-} cands=() all=() c i n
  if [[ -n $preset ]]; then
    [[ -f $preset ]] || die "Нет файла бэкапа: $preset"
    if [[ -n $DOMAIN ]] && grep -qF "$DOMAIN" "$preset"; then
      echo "ВНИМАНИЕ: в $preset уже упоминается $DOMAIN — возможно, это бэкап после установки, а не до неё." >&3
    fi
    echo "$preset"; return 0
  fi
  if [[ -e $target.pre-tproxy ]]; then cands+=("$target.pre-tproxy"); fi
  mapfile -t all < <(ls -1t "$target".bak* 2>/dev/null || true)
  for c in "${all[@]}"; do
    # бэкап, где уже есть наш домен, сделан после установки — для restore не подходит
    if [[ -n $DOMAIN ]] && grep -qF "$DOMAIN" "$c"; then continue; fi
    cands+=("$c")
  done
  if [[ ${#cands[@]} -eq 0 && ${#all[@]} -gt 0 ]]; then
    echo "ВНИМАНИЕ: во всех найденных бэкапах $target уже есть $DOMAIN — возможно, они сделаны после установки." >&3
    cands=("${all[@]}")
  fi
  [[ ${#cands[@]} -gt 0 ]] || die "Не найдено бэкапов для $target (ожидались $target.pre-tproxy или $target.bak*). Укажите файл через --backup-nginx/--backup-compose/--backup-caddy."
  if [[ ${#cands[@]} -eq 1 ]] || (( ASSUME_YES )) || ! have_tty; then
    echo "${cands[0]}"; return 0
  fi
  printf '\nБэкапы для %s:\n' "$target" >&3
  i=1
  for c in "${cands[@]}"; do
    printf '  %d) %s   (%s)\n' "$i" "$c" "$(stat -c '%y' "$c" | cut -d. -f1)" >&3
    i=$((i+1))
  done
  ask "Выберите номер [1]: " n
  n=${n:-1}
  [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#cands[@]} )) || die "Неверный выбор: $n"
  echo "${cands[$((n-1))]}"
}

# ------------------------------------------------------------------ фронтенд: режим remnawave
# ------------------------------------------------------------------ порт 80 для выпуска/продления сертификата
# Let's Encrypt (certbot --standalone) должен достучаться до порта 80. При ufw/DROP-политике он
# закрыт, поэтому на время выпуска и каждого продления порт открывается, а потом закрывается.
ACME_PORT_BIN=/usr/local/sbin/tproxy-acme-port.sh
ACME_PRE_HOOK=/etc/letsencrypt/renewal-hooks/pre/tproxy-acme-open.sh
ACME_POST_HOOK=/etc/letsencrypt/renewal-hooks/post/tproxy-acme-close.sh

install_acme_port_helper() {
  install -d -m 0755 "$(dirname "$ACME_PORT_BIN")" "$(dirname "$ACME_PRE_HOOK")" "$(dirname "$ACME_POST_HOOK")"
  cat > "$ACME_PORT_BIN" <<'EOF'
#!/bin/sh
# open — открыть входящий 80/tcp (если закрыт); close — закрыть то, что открыли мы; keep — открыть насовсем.
M=/run/tproxy-acme-opened
ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }
case "${1:-}" in
  open|keep)
    if ufw_active; then
      if ufw status 2>/dev/null | grep -Eq '^80(/tcp)?[[:space:]]+ALLOW'; then exit 0; fi
      ufw allow 80/tcp comment tproxy-acme >/dev/null 2>&1 || exit 1
      [ "$1" = open ] && echo ufw >> "$M"
    else
      for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        "$t" -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null && continue
        "$t" -I INPUT 1 -p tcp --dport 80 -j ACCEPT 2>/dev/null || continue
        [ "$1" = open ] && echo "$t" >> "$M"
      done
    fi
    ;;
  close)
    [ -f "$M" ] || exit 0
    while read -r w; do
      case "$w" in
        ufw) ufw delete allow 80/tcp >/dev/null 2>&1 || true ;;
        iptables|ip6tables) "$w" -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true ;;
      esac
    done < "$M"
    rm -f "$M"
    ;;
  *) echo "usage: $0 open|close|keep" >&2; exit 2 ;;
esac
exit 0
EOF
  chmod 0755 "$ACME_PORT_BIN"
  printf '#!/bin/sh\n%s open\n' "$ACME_PORT_BIN" > "$ACME_PRE_HOOK"
  printf '#!/bin/sh\n%s close\n' "$ACME_PORT_BIN" > "$ACME_POST_HOOK"
  chmod 0755 "$ACME_PRE_HOOK" "$ACME_POST_HOOK"
}

front_remnawave() {
  step "Интеграция с nginx Remnawave"
  local compose NGCONF SOCK need=0
  compose=$(find_compose_file) || die "Не найден docker-compose в $REMNA_DIR"
  NGCONF="$REMNA_DIR/nginx.conf"
  [[ -f $NGCONF ]] || die "Не найден $NGCONF"
  init_compose
  [[ $(docker inspect -f '{{.HostConfig.NetworkMode}}' "$NGINX_CTR") == host ]] \
    || die "$NGINX_CTR не в network_mode: host — он не увидит relay на 127.0.0.1:8080"
  SOCK=$(grep -oP 'listen\s+unix:\K[^ ;]+' "$NGCONF" | head -1 || true)
  [[ -n $SOCK ]] || die "В $NGCONF нет 'listen unix:...' — схема self-steal не обнаружена"
  grep -q 'proxy_protocol' "$NGCONF" || die "В $NGCONF нет proxy_protocol — схема отличается от ожидаемой"
  grep -q 'nginx.conf:/etc/nginx/conf.d/default.conf' "$compose" \
    || warn "В compose не найден монтаж ./nginx.conf в conf.d/default.conf — проверьте вручную"

  # --- сертификат
  if [[ ! -s /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]]; then
    [[ -z $(ss -H -ltn 'sport = :80') ]] \
      || die "Порт 80 занят ($(ss -H -ltnp 'sport = :80')) — certbot --standalone не сработает."
    apt_run install -y certbot
    local em=(--register-unsafely-without-email)
    if [[ -n $EMAIL ]]; then em=(-m "$EMAIL"); fi
    install_acme_port_helper
    "$ACME_PORT_BIN" open && log "Порт 80 временно открыт для проверки Let's Encrypt (если был закрыт)"
    local cb_rc=0
    certbot certonly --standalone -d "$DOMAIN" --key-type ecdsa --elliptic-curve secp384r1 \
      --non-interactive --agree-tos "${em[@]}" || cb_rc=$?
    "$ACME_PORT_BIN" close
    if [[ $cb_rc -ne 0 ]]; then
      warn "Let's Encrypt не смог подключиться к порту 80 этого сервера. Проверьте:"
      warn "  1) файрвол провайдера (панель хостинга: Security group / Firewall) — откройте входящие 80/tcp и 443/tcp;"
      warn "  2) локальный файрвол: ufw status; iptables -S INPUT | head; nft list ruleset | head -40;"
      warn "  3) что A-запись $DOMAIN указывает именно на этот сервер, а не на его внутренний/другой адрес (NAT)."
      if command -v ufw >/dev/null 2>&1; then warn "  ufw: $(ufw status 2>&1 | head -1)"; fi
      die "Выпуск сертификата не удался. Исправьте доступность порта 80 и запустите «Установить» ещё раз — уже сделанные шаги пропустятся."
    fi
    state_set CERT_BY_US 1
  else
    install_acme_port_helper     # продление тоже идёт через порт 80
    log "Сертификат для $DOMAIN уже есть"
  fi
  # Docker монтирует файл, а не симлинк: после продления контейнер видит старый
  # сертификат, пока его не перезапустить. Без этого хука сертификат протухнет.
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  if ! grep -rqs "docker restart $NGINX_CTR" /etc/letsencrypt/renewal-hooks/deploy/; then
    printf '#!/bin/sh\ndocker restart %s\n' "$NGINX_CTR" > /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh
    log "Создан deploy-hook для перезапуска $NGINX_CTR после продления"
  fi

  grep -qF "/etc/nginx/ssl/$DOMAIN/" "$compose" || need=1
  ngx_edit exists "$NGCONF" "$DOMAIN" || need=1
  if (( ! need )); then
    log "nginx.conf и compose уже содержат $DOMAIN — изменений не требуется"
    all_running || warn "Не все контейнеры Remnawave запущены: проверьте 'docker ps'"
    return 0
  fi

  confirm "Будут пересозданы $NGINX_CTR и remnanode — VPN прервётся на несколько секунд. Продолжить?" \
    || die "Отменено пользователем (relay и MTProxy уже установлены и работают)."

  # --- бэкапы: «исходный» (один раз, для restore) и откатный на этот запуск
  local ts; ts=$(date +%Y%m%d%H%M%S)
  if [[ ! -e $compose.pre-tproxy ]]; then cp -a "$compose" "$compose.pre-tproxy"; fi
  if [[ ! -e $NGCONF.pre-tproxy ]]; then cp -a "$NGCONF" "$NGCONF.pre-tproxy"; fi
  state_set ORIG_COMPOSE "$compose.pre-tproxy"
  state_set ORIG_NGCONF "$NGCONF.pre-tproxy"
  cp -a "$compose" "$compose.bak.$ts"
  cp -a "$NGCONF" "$NGCONF.bak.$ts"
  rollback() {
    warn "Откат nginx.conf и compose из бэкапов"
    cp -a "$compose.bak.$ts" "$compose"; cp -a "$NGCONF.bak.$ts" "$NGCONF"
  }

  python3 - "$compose" "$DOMAIN" <<'PY' || { rollback; die "Не удалось добавить volumes в compose — добавьте вручную две строки с сертификатом $DOMAIN"; }
import re, sys
path, domain = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
if any(f'/etc/nginx/ssl/{domain}/' in l for l in lines):
    sys.exit(0)
idx = None
for i, l in enumerate(lines):
    if '/etc/nginx/ssl/' in l:
        idx = i
if idx is None:
    for i, l in enumerate(lines):
        if re.search(r'nginx\.conf:/etc/nginx/conf\.d/default\.conf', l):
            idx = i
if idx is None:
    sys.exit(3)
m = re.match(r'^(\s*-\s*)', lines[idx])
pre = m.group(1) if m else '      - '
new = [
    f'{pre}/etc/letsencrypt/live/{domain}/fullchain.pem:/etc/nginx/ssl/{domain}/fullchain.pem:ro',
    f'{pre}/etc/letsencrypt/live/{domain}/privkey.pem:/etc/nginx/ssl/{domain}/privkey.pem:ro',
]
lines[idx+1:idx+1] = new
open(path, 'w').write('\n'.join(lines))
PY

  if ! ngx_edit exists "$NGCONF" "$DOMAIN"; then
    local h2l="" h2d=""
    if grep -q 'http2 on' "$NGCONF"; then h2d="http2 on;"; else h2l="http2 "; fi
    if ! grep -q 'map \$http_upgrade \$tp_connection' "$NGCONF"; then
      cat >> "$NGCONF" <<'EOF'

map $http_upgrade $tp_connection {
    default upgrade;
    ""      "";
}
EOF
    fi
    cat >> "$NGCONF" <<'EOF'

# >>> tproxy-web-proxy: __DOMAIN__ (добавлено setup-tproxy.sh)
server {
    server_name __DOMAIN__;
    listen unix:__SOCK__ ssl __H2L__proxy_protocol;
    __H2D__

    ssl_certificate         "/etc/nginx/ssl/__DOMAIN__/fullchain.pem";
    ssl_certificate_key     "/etc/nginx/ssl/__DOMAIN__/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/__DOMAIN__/fullchain.pem";

    access_log off;   # в URI лежит bridge-capability — логировать нельзя

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        # relay требует РОВНО один IP в X-Forwarded-For
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $tp_connection;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        client_body_timeout 5m;
        proxy_read_timeout 120s;
        proxy_send_timeout 5m;
    }
}
# <<< tproxy-web-proxy: __DOMAIN__
EOF
    # подстановка плейсхолдеров только в добавленном хвосте
    sed -i -e "s#__DOMAIN__#$DOMAIN#g" -e "s#__SOCK__#$SOCK#g" \
           -e "s#__H2L__#$h2l#g" -e "s#__H2D__#$h2d#g" "$NGCONF"
  fi

  if ! nginx_test "$NGCONF"; then
    rollback
    die "nginx -t не прошёл (вывод выше). Файлы возвращены. Если уверены в конфиге — запустите с --skip-nginx-test."
  fi

  log "Пересоздаю контейнеры"
  if ! recreate_stack; then
    docker logs --tail 20 "$NGINX_CTR" || true
    rollback
    ( cd "$REMNA_DIR" && $COMPOSE up -d --force-recreate ) || true
    die "Контейнеры не поднялись после изменений — выполнен откат конфигов."
  fi
  log "Контейнеры работают"
}

# ------------------------------------------------------------------ фронтенд: режим standalone (Caddy)
front_standalone() {
  step "Caddy (standalone)"
  local p
  for p in 80 443; do
    if [[ -n $(ss -H -ltnp "sport = :$p") ]] && ! grep -q caddy <<<"$(ss -H -ltnp "sport = :$p")"; then
      die "Порт $p занят: $(ss -H -ltnp "sport = :$p"). Если это Xray/Reality без nginx, этот режим не подходит — нужна схема self-steal (nginx за unix-сокетом)."
    fi
  done
  if ! command -v caddy >/dev/null 2>&1; then
    apt_run install -y debian-keyring debian-archive-keyring apt-transport-https gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list
    chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq || true
    apt_run install -y caddy
    state_set CADDY_BY_US 1
  fi
  install_acme_port_helper
  "$ACME_PORT_BIN" keep || warn "Не удалось открыть 80/tcp — откройте вручную (он нужен Caddy для сертификата)"
  local cf=/etc/caddy/Caddyfile
  # «исходный» бэкап: один раз и только если там лежит не наш файл
  if [[ -f $cf && ! -e $cf.pre-tproxy ]] && ! grep -q 'managed by setup-tproxy.sh' "$cf"; then
    cp -a "$cf" "$cf.pre-tproxy"
    state_set ORIG_CADDYFILE "$cf.pre-tproxy"
  fi
  if [[ -f $cf ]]; then cp -a "$cf" "$cf.bak.$(date +%Y%m%d%H%M%S)"; fi
  local emailline=""
  if [[ -n $EMAIL ]]; then emailline="email $EMAIL"; fi
  cat > "$cf" <<EOF
# managed by setup-tproxy.sh
{
	$emailline
	admin off
	servers {
		protocols h1 h2
		timeouts {
			read_header 10s
			read_body 60s
		}
	}
}

$DOMAIN {
	encode zstd gzip
	header Strict-Transport-Security "max-age=31536000; includeSubDomains"
	reverse_proxy 127.0.0.1:8080 {
		transport http {
			response_header_timeout 40s
		}
	}
	handle_errors {
		header {
			Cache-Control "no-store"
			Content-Security-Policy "default-src 'self'; style-src 'self'; img-src 'self'; worker-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
			X-Content-Type-Options "nosniff"
			X-Frame-Options "DENY"
		}
		respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
	}
}
EOF
  caddy validate --config "$cf" --adapter caddyfile >/dev/null \
    || die "Caddyfile не прошёл проверку"
  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl restart caddy      # admin off => reload недоступен
  if command -v ufw >/dev/null 2>&1 && grep -q 'Status: active' <<<"$(ufw status)"; then
    warn "ufw активен: убедитесь, что разрешены 80/tcp и 443/tcp (ufw allow 80/tcp; ufw allow 443/tcp)"
  fi
  return 0
}

# ------------------------------------------------------------------ итоговая проверка
final_check() {
  step "Итоговая проверка"
  local i c1="" c2="" tries=15
  if [[ $RESOLVED_MODE == standalone ]]; then tries=60; fi     # Caddy выпускает сертификат при первом запросе
  for i in $(seq 1 "$tries"); do
    c1=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || true)
    c2=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/?bridge=wrong" || true)
    [[ $c1 == 200 && $c2 == 200 ]] && break
    sleep 2
  done
  [[ $c1 == 200 && $c2 == 200 ]] || die "https://$DOMAIN/ отвечает $c1 / $c2 (ожидалось 200/200). Проверьте: journalctl -u tproxy-server -u caddy; docker logs $NGINX_CTR"
  log "https://$DOMAIN/ -> 200, ?bridge=wrong -> 200 (одинаковый ответ, как и должно быть)"
  iptables -C INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP && log "2398/8888 закрыты снаружи"
  systemctl is-enabled backend-firewall mtproxy tproxy-server | tr '\n' ' '; echo
}

# ------------------------------------------------------------------ КОМАНДА: install
do_install() {
  validate_install_args
  log "Установка WEB-прокси, домен: $DOMAIN (лог: $LOG_FILE)"
  ensure_tools

  check_dns

  RESOLVED_MODE="$MODE"
  if [[ $MODE == auto ]]; then
    if command -v docker >/dev/null 2>&1 \
       && docker inspect "$NGINX_CTR" >/dev/null 2>&1 \
       && [[ -f $REMNA_DIR/nginx.conf ]]; then
      RESOLVED_MODE=remnawave
    else
      RESOLVED_MODE=standalone
    fi
  fi
  log "Режим: $RESOLVED_MODE"
  if [[ $RESOLVED_MODE == remnawave ]]; then
    command -v docker >/dev/null 2>&1 || die "Docker не найден"
    docker inspect "$NGINX_CTR" >/dev/null 2>&1 || die "Контейнер $NGINX_CTR не найден (--nginx-container)"
  fi
  # запоминаем параметры сразу: даже неудачную установку можно будет удалить
  state_set DOMAIN "$DOMAIN"
  state_set MODE "$RESOLVED_MODE"
  state_set EMAIL "$EMAIL"
  state_set REMNA_DIR "$REMNA_DIR"
  state_set NGINX_CTR "$NGINX_CTR"

  check_ports
  ensure_swap
  install_go
  build_relay
  install_site
  write_configs
  install_backend

  if [[ $RESOLVED_MODE == remnawave ]]; then front_remnawave; else front_standalone; fi
  final_check
  state_set INSTALLED_AT "$(date -Is)"

  {
    printf '\n==================== ГОТОВО ====================\n'
    printf 'Hostname: %s\n' "$DOMAIN"
    printf 'Secret:   %s\n' "$SECRET"
    printf 'Ссылка:   https://t.me/webproxy?server=%s&secret=%s\n' "$DOMAIN" "$SECRET"
    printf 'Секрет также лежит в %s/profiles.json (root, 0400); показать: setup-tproxy.sh show\n' "$CONF_DIR"
    printf 'Лог установки (без секрета): %s\n' "$LOG_FILE"
    printf 'Не забудьте: порты 80/443 открыты у хостера; 2398/8888/8080/8081 — нет.\n'
    printf '================================================\n'
  } >&3
}

# ------------------------------------------------------------------ контекст для show/uninstall/restore/reinstall
detect_domain() {
  python3 -c "import json;print(json.load(open('$CONF_DIR/config.json')).get('public_hostname',''))" 2>/dev/null || true
}

load_context() {
  if [[ -z $DOMAIN ]]; then DOMAIN=$(detect_domain); fi
  if [[ -z $DOMAIN ]]; then DOMAIN=$(state_get DOMAIN); fi
  DOMAIN="${DOMAIN,,}"
  if [[ -n $DOMAIN ]]; then
    valid_domain "$DOMAIN" || die "Некорректный hostname в конфигурации/аргументах: $DOMAIN"
  fi
  if [[ $MODE != auto ]]; then
    RESOLVED_MODE=$MODE
  else
    RESOLVED_MODE=$(state_get MODE)
    if [[ -z $RESOLVED_MODE && -n $DOMAIN ]]; then
      if [[ -f $REMNA_DIR/nginx.conf ]] && ngx_edit exists "$REMNA_DIR/nginx.conf" "$DOMAIN"; then
        RESOLVED_MODE=remnawave
      elif grep -qsF "$DOMAIN" /etc/caddy/Caddyfile; then
        RESOLVED_MODE=standalone
      fi
    fi
  fi
  return 0
}

relay_secret() {
  python3 -c "import json;print(json.load(open('$CONF_DIR/profiles.json'))['profiles'][0]['secret'])" 2>/dev/null || true
}

# ------------------------------------------------------------------ КОМАНДА: show
do_show() {
  load_context
  {
    echo
    if [[ -z $DOMAIN || ! -f $CONF_DIR/config.json ]]; then
      echo "Веб-прокси не установлен (нет $CONF_DIR/config.json)."
      return 0
    fi
    local secret carrier u code cert b found=0
    secret=$(relay_secret)
    carrier=$(python3 -c "import json;print(json.load(open('$CONF_DIR/profiles.json'))['profiles'][0].get('carrier_mode','https'))" 2>/dev/null || true)

    echo "==================== WEB-прокси ===================="
    printf '%-18s %s\n' "Hostname:" "$DOMAIN"
    printf '%-18s %s\n' "Режим:" "${RESOLVED_MODE:-не определён}"
    if [[ -f $USERS_FILE ]]; then
      printf '%-18s %s\n' "Пользователи:" "$(users_py list "$USERS_FILE" | awk -F'\t' '$2==1{e++} END{print NR " (активных: " e+0 ")"}')"
    else
      printf '%-18s %s\n' "Secret:" "${secret:-<не найден>}"
      printf '%-18s %s\n' "Ссылка:" "https://t.me/webproxy?server=$DOMAIN&secret=$secret"
    fi
    printf '%-18s %s\n' "Carrier mode:" "${carrier:-?}"
    printf '%-18s %s\n' "Установлено:" "$(state_get INSTALLED_AT)"
    if [[ -d $SRC/.git ]]; then printf '%-18s %s\n' "Версия relay:" "$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null)"; fi

    if [[ -f $USERS_FILE ]]; then echo; echo "---- пользователи ($USERS_FILE) ----"; users_list_body; fi
    echo; echo "---- relay ($CONF_DIR/config.json) ----"
    python3 -c "
import json
c = json.load(open('$CONF_DIR/config.json'))
for k in ('public_hostname', 'listen', 'admin_listen', 'public_dir', 'public_upstream', 'static_routes'):
    if k in c: print('%-18s %s' % (k + ':', c[k]))
l = c.get('limits', {})
lim = ', '.join('%s=%s' % (k, l[k]) for k in ('max_sessions_global', 'max_streams_global', 'max_pending_global', 'max_sessions_per_ip') if k in l)
if lim: print('%-18s %s' % ('limits:', lim))
print('%-18s %s' % ('backend:', json.load(open('$CONF_DIR/profiles.json'))['profiles'][0].get('backend', '?')))
" 2>/dev/null || true
    if [[ -f $SITE_DST/index.html ]]; then
      printf '%-18s %s\n' "Сайт relay:" "$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$SITE_DST/index.html" | head -1)  [$(ls "$SITE_DST" | tr '\n' ' ')]"
    fi

    echo; echo "---- сервисы ----"
    for u in tproxy-server mtproxy backend-firewall caddy; do
      if [[ -n $(systemctl list-unit-files "$u.service" --no-legend 2>/dev/null) ]]; then
        printf '%-18s %s / %s\n' "$u:" "$(systemctl is-active "$u" 2>/dev/null || true)" "$(systemctl is-enabled "$u" 2>/dev/null || true)"
      fi
    done
    if [[ -f /etc/systemd/system/$REFRESH_UNIT.timer ]]; then
      printf '%-18s %s / %s\n' "обновл. конфига:" "$(systemctl is-active "$REFRESH_UNIT.timer" 2>/dev/null || true)" "$(systemctl is-enabled "$REFRESH_UNIT.timer" 2>/dev/null || true)"
    else
      printf '%-18s %s\n' "обновл. конфига:" "таймер не установлен — выполните: setup-tproxy.sh refresh"
    fi
    if [[ -f /etc/mtproxy/proxy-multi.conf ]]; then
      printf '%-18s %s\n' "proxy-multi.conf:" "изменён $(stat -c '%y' /etc/mtproxy/proxy-multi.conf | cut -d. -f1)"
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8081/readyz || true)
    printf '%-18s %s\n' "/readyz:" "${code:-нет ответа}"
    if iptables -C INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP 2>/dev/null; then
      printf '%-18s %s\n' "2398/8888 снаружи:" "закрыты (правило iptables есть)"
    else
      printf '%-18s %s\n' "2398/8888 снаружи:" "ПРАВИЛА НЕТ — порты могут быть открыты!"
    fi
    cert=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -enddate -issuer 2>/dev/null | tr '\n' ' ' || true)
    printf '%-18s %s\n' "Сертификат:" "${cert:-не удалось получить через 127.0.0.1:443}"

    echo; echo "---- фронтенд ----"
    if [[ $RESOLVED_MODE == remnawave ]]; then
      echo "nginx.conf ($REMNA_DIR/nginx.conf), блок для $DOMAIN:"
      ngx_edit extract "$REMNA_DIR/nginx.conf" "$DOMAIN" 2>/dev/null || echo "  (блок не найден)"
      local compose; compose=$(find_compose_file 2>/dev/null || true)
      if [[ -n $compose ]]; then
        echo; echo "volumes в $compose:"
        grep -F "$DOMAIN" "$compose" || echo "  (нет)"
      fi
    elif [[ $RESOLVED_MODE == standalone ]]; then
      echo "/etc/caddy/Caddyfile:"
      cat /etc/caddy/Caddyfile 2>/dev/null || echo "  (нет файла)"
    else
      echo "Фронтенд не определён."
    fi

    echo; echo "---- бэкапы (для restore) ----"
    shopt -s nullglob
    for b in "$REMNA_DIR"/nginx.conf.pre-tproxy "$REMNA_DIR"/nginx.conf.bak* \
             "$REMNA_DIR"/docker-compose.y*ml.pre-tproxy "$REMNA_DIR"/docker-compose.y*ml.bak* \
             /etc/caddy/Caddyfile.pre-tproxy /etc/caddy/Caddyfile.bak*; do
      [[ -e $b ]] || continue
      printf '  %s  (%s)\n' "$b" "$(stat -c '%y' "$b" | cut -d. -f1)"; found=1
    done
    shopt -u nullglob
    if (( ! found )); then echo "  (не найдены)"; fi
    echo "====================================================="
  } >&3 2>&3
  return 0
}

# ------------------------------------------------------------------ удаление: общие части
stop_services() {
  local u
  systemctl disable --now "$REFRESH_UNIT.timer" >/dev/null 2>&1 || true
  for u in tproxy-server mtproxy backend-firewall; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
  # на случай, если ExecStop не отработал
  while iptables -C INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP 2>/dev/null; do
    iptables -D INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP || break
  done
  while ip6tables -C INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP 2>/dev/null; do
    ip6tables -D INPUT ! -i lo -p tcp -m multiport --dports 2398,8888 -j DROP || break
  done
  rm -f /etc/systemd/system/tproxy-server.service /etc/systemd/system/mtproxy.service \
        /etc/systemd/system/backend-firewall.service \
        "/etc/systemd/system/$REFRESH_UNIT.service" "/etc/systemd/system/$REFRESH_UNIT.timer" "$REFRESH_BIN" \
        "$ACME_PORT_BIN" "$ACME_PRE_HOOK" "$ACME_POST_HOOK"
  rm -rf /etc/systemd/system/mtproxy.service.d
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true
  log "Сервисы tproxy-server, mtproxy, backend-firewall остановлены и удалены"
}

# keep_secret=1: сохранить секрет (profiles.json), seed сайта и каталог сайта (для reinstall)
remove_backend_files() {
  local keep=${1:-0}
  rm -f /usr/local/bin/tproxy-server
  rm -rf /opt/MTProxy /opt/MTProxy.before-tproxy.* /etc/mtproxy
  if (( keep )); then
    rm -f "$CONF_DIR/config.json" "$CONF_DIR/token.key"
    rm -f "$SRC/.built-commit"          # принудительная пересборка
  else
    rm -rf "$SRC" "$CONF_DIR" "$SITE_DST" "$SITE_DST.old" "$SITE_DST.new"
    id tproxy >/dev/null 2>&1 && userdel tproxy >/dev/null 2>&1 || true
  fi
  id mtproxy >/dev/null 2>&1 && userdel mtproxy >/dev/null 2>&1 || true
  return 0
}

# Удаление нашего фрагмента из nginx.conf/compose (режим remnawave, обычный uninstall)
remnawave_remove_surgical() {
  local compose NGCONF ts changed=0
  compose=$(find_compose_file) || { warn "Не найден docker-compose в $REMNA_DIR — фронтенд не трогаю"; return 0; }
  NGCONF="$REMNA_DIR/nginx.conf"
  init_compose
  ts=$(date +%Y%m%d%H%M%S)
  cp -a "$compose" "$compose.before-uninstall.$ts"
  cp -a "$NGCONF" "$NGCONF.before-uninstall.$ts"
  rb() { cp -a "$compose.before-uninstall.$ts" "$compose"; cp -a "$NGCONF.before-uninstall.$ts" "$NGCONF"; }

  if ngx_edit exists "$NGCONF" "$DOMAIN"; then
    ngx_edit remove "$NGCONF" "$DOMAIN"; changed=1
  fi
  if grep -qF "/etc/nginx/ssl/$DOMAIN/" "$compose"; then
    grep -vF "/etc/nginx/ssl/$DOMAIN/" "$compose" > "$compose.tmp.$ts"
    cat "$compose.tmp.$ts" > "$compose"; rm -f "$compose.tmp.$ts"
    changed=1
  fi
  if (( ! changed )); then
    log "В nginx.conf и compose нет следов $DOMAIN — фронтенд не менялся"
    rm -f "$compose.before-uninstall.$ts" "$NGCONF.before-uninstall.$ts"
    return 0
  fi
  if ! nginx_test "$NGCONF"; then
    rb; die "nginx -t не прошёл после удаления блока — изменения отменены (relay уже остановлен)."
  fi
  log "Пересоздаю контейнеры Remnawave"
  if ! recreate_stack; then
    docker logs --tail 20 "$NGINX_CTR" || true
    rb; ( cd "$REMNA_DIR" && $COMPOSE up -d --force-recreate ) || true
    die "Контейнеры не поднялись — конфиги возвращены."
  fi
  log "nginx.conf и compose очищены от $DOMAIN, контейнеры работают (копии до правки: *.before-uninstall.$ts)"
}

# Восстановление nginx.conf/compose из бэкапов (режим remnawave, restore)
remnawave_restore_backups() {
  local compose NGCONF cb nb ts
  compose=$(find_compose_file) || die "Не найден docker-compose в $REMNA_DIR"
  NGCONF="$REMNA_DIR/nginx.conf"
  init_compose
  cb=$(pick_backup "$compose" "$BACKUP_COMPOSE")
  nb=$(pick_backup "$NGCONF" "$BACKUP_NGINX")
  {
    echo
    echo "Будут восстановлены:"
    echo "  $nb  ->  $NGCONF"
    echo "  $cb  ->  $compose"
    echo "Разница (текущий -> бэкап), начало:"
    diff -u "$NGCONF" "$nb" | head -30 || true
    diff -u "$compose" "$cb" | head -30 || true
    echo "Правки, сделанные в этих файлах после бэкапа, будут потеряны (копии текущих — *.before-restore.*)."
  } >&3
  confirm "Восстановить файлы из этих бэкапов и пересоздать контейнеры?" || die "Отменено пользователем."
  ts=$(date +%Y%m%d%H%M%S)
  cp -a "$compose" "$compose.before-restore.$ts"
  cp -a "$NGCONF" "$NGCONF.before-restore.$ts"
  cp -a "$cb" "$compose"
  cp -a "$nb" "$NGCONF"
  rb() { cp -a "$compose.before-restore.$ts" "$compose"; cp -a "$NGCONF.before-restore.$ts" "$NGCONF"; }
  if ! nginx_test "$NGCONF"; then
    rb; die "nginx -t для восстановленного конфига не прошёл — возвращены прежние файлы."
  fi
  log "Пересоздаю контейнеры Remnawave"
  if ! recreate_stack; then
    docker logs --tail 20 "$NGINX_CTR" || true
    rb; ( cd "$REMNA_DIR" && $COMPOSE up -d --force-recreate ) || true
    die "Контейнеры не поднялись — возвращены прежние файлы."
  fi
  log "Восстановлено из бэкапов, контейнеры работают"
}

standalone_remove() {
  local cf=/etc/caddy/Caddyfile pick="" ts; ts=$(date +%Y%m%d%H%M%S)
  if (( RESTORE_MODE )); then
    if [[ -n $BACKUP_CADDY || -e $cf.pre-tproxy || -n $(ls "$cf".bak* 2>/dev/null) ]]; then
      pick=$(pick_backup "$cf" "$BACKUP_CADDY")
    fi
  elif [[ -e $cf.pre-tproxy ]]; then
    pick="$cf.pre-tproxy"
  fi
  if [[ -f $cf ]]; then cp -a "$cf" "$cf.before-uninstall.$ts"; fi
  if [[ -n $pick ]]; then
    cp -a "$pick" "$cf"
    log "Caddyfile восстановлен из $pick"
  else
    printf '# emptied by setup-tproxy.sh uninstall\n' > "$cf"
    log "Caddyfile очищен (копия: $cf.before-uninstall.$ts)"
  fi
  if [[ $(state_get CADDY_BY_US) == 1 ]]; then
    systemctl disable --now caddy >/dev/null 2>&1 || true
    log "Caddy остановлен (его поставил скрипт)"
  elif systemctl is-active --quiet caddy; then
    systemctl restart caddy || warn "Caddy не перезапустился: проверьте Caddyfile"
  fi
  return 0
}

purge_extras() {
  if [[ $RESOLVED_MODE == remnawave || -n $DOMAIN ]]; then
    if [[ -f /etc/letsencrypt/renewal/$DOMAIN.conf ]] && purge_ask "Удалить сертификат Let's Encrypt для $DOMAIN?"; then
      certbot delete --cert-name "$DOMAIN" --non-interactive || warn "certbot delete не удался"
    fi
  fi
  if [[ $(state_get GO_BY_US) == 1 ]] && purge_ask "Удалить Go (/usr/local/go) — его поставил скрипт?"; then
    rm -rf /usr/local/go /usr/local/bin/go
  fi
  if [[ $(state_get CADDY_BY_US) == 1 ]] && purge_ask "Удалить пакет Caddy и его репозиторий — их поставил скрипт?"; then
    apt-get purge -y -qq caddy >/dev/null || true
    rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  fi
  if [[ $(state_get SWAP_BY_US) == 1 && -e /swapfile.tproxy ]] && purge_ask "Удалить swap-файл /swapfile.tproxy — его создал скрипт?"; then
    swapoff /swapfile.tproxy || warn "swapoff не удался — файл оставлен"
    if ! grep -qx /swapfile.tproxy <<<"$(swapon --show=NAME --noheadings)"; then
      rm -f /swapfile.tproxy
      sed -i '\#^/swapfile.tproxy #d' /etc/fstab
    fi
  fi
  return 0
}

# ------------------------------------------------------------------ КОМАНДА: uninstall / restore
do_uninstall() {
  load_context
  if [[ -z $DOMAIN && ! -d $CONF_DIR && ! -f $STATE_FILE && ! -e /etc/systemd/system/tproxy-server.service ]]; then
    log "Ничего не найдено — веб-прокси, похоже, не установлен."
    return 0
  fi
  [[ -n $DOMAIN ]] || warn "Домен не определён (нет $CONF_DIR/config.json) — фронтенд не трогаю."
  local what="Удаление"
  if (( RESTORE_MODE )); then what="Удаление с восстановлением из бэкапов"; fi
  {
    echo
    echo "$what WEB-прокси:  домен=${DOMAIN:-?}  режим=${RESOLVED_MODE:-?}"
    echo "  будут удалены: сервисы tproxy-server/mtproxy/backend-firewall, бинарник, /opt/tproxy-server,"
    echo "                 /opt/MTProxy, /etc/mtproxy, $CONF_DIR (включая СЕКРЕТ), $SITE_DST"
    if [[ $RESOLVED_MODE == remnawave ]]; then
      if (( RESTORE_MODE )); then echo "  nginx.conf и docker-compose будут ВОССТАНОВЛЕНЫ из бэкапов, контейнеры пересозданы (VPN моргнёт)."
      else echo "  из nginx.conf и docker-compose будут убраны только наши фрагменты, контейнеры пересозданы (VPN моргнёт)."; fi
    elif [[ $RESOLVED_MODE == standalone ]]; then
      echo "  Caddyfile будет возвращён к прежнему состоянию (или очищен)."
    fi
  } >&3
  confirm "Продолжить?" || { log "Отменено."; return 0; }

  stop_services

  if [[ -n $DOMAIN ]]; then
    case "$RESOLVED_MODE" in
      remnawave)
        if command -v docker >/dev/null 2>&1 && docker inspect "$NGINX_CTR" >/dev/null 2>&1; then
          if (( RESTORE_MODE )); then remnawave_restore_backups; else remnawave_remove_surgical; fi
        else
          warn "Контейнер $NGINX_CTR не найден — фронтенд (nginx.conf/compose) не трогаю"
        fi ;;
      standalone) standalone_remove ;;
      *) warn "Режим фронтенда не определён — nginx/Caddy не трогаю" ;;
    esac
  fi

  remove_backend_files 0
  purge_extras
  rm -rf "$STATE_DIR"
  log "Готово: WEB-прокси удалён."
  if [[ $RESOLVED_MODE == remnawave ]] && ! (( RESTORE_MODE )); then
    log "Бэкапы остались рядом с конфигами (*.pre-tproxy, *.bak.*, *.before-uninstall.*) — удалите вручную, когда они станут не нужны."
  fi
  return 0
}

# ------------------------------------------------------------------ КОМАНДА: reinstall
do_reinstall() {
  load_context
  [[ -n $DOMAIN ]] || die "Не удалось определить домен установленного прокси — используйте install --domain ..."
  [[ $RESOLVED_MODE =~ ^(remnawave|standalone)$ ]] || die "Не удалось определить режим (укажите --mode remnawave|standalone)."
  {
    echo
    echo "Переустановка WEB-прокси: домен=$DOMAIN режим=$RESOLVED_MODE"
    echo "  сохраняются: секрет (ссылки у клиентов не изменятся), сайт-заглушка, сертификат, блок в nginx/Caddy"
    echo "  заново ставятся: relay (пересборка), MTProxy, systemd-юниты, правило firewall"
  } >&3
  confirm "Продолжить?" || { log "Отменено."; return 0; }
  # install должен подхватить определённые параметры
  MODE="$RESOLVED_MODE"
  if [[ -z $SECRET ]]; then SECRET=$(relay_secret); fi
  stop_services
  remove_backend_files 1
  do_install
}

# ------------------------------------------------------------------ меню
print_status() {
  local d m st
  d=$(detect_domain)
  {
    echo
    echo "=========== Telegram WEB-прокси: setup-tproxy ==========="
    if [[ -n $d ]]; then
      m=$(state_get MODE)
      st=$(systemctl is-active tproxy-server 2>/dev/null || true)
      echo "Состояние: установлен  домен=$d  режим=${m:-?}  relay=${st:-?}"
    else
      echo "Состояние: не установлен"
    fi
    echo "---------------------------------------------------------"
  } >&3
}

menu_users() {
  local c n v
  load_context
  if [[ -z $DOMAIN || ! -f $CONF_DIR/config.json ]]; then echo "Веб-прокси не установлен." >&3; return 0; fi
  run_isolated users_ensure_file
  while :; do
    run_isolated users_list
    cat >&3 <<'EOF'
  1) Добавить пользователя
  2) Отключить
  3) Включить
  4) Удалить
  5) Изменить лимит сессий
  6) Применить (пересоздать профили и перезапустить)
  7) Подобрать глобальные лимиты по ресурсам сервера
  0) Назад
EOF
    ask "Выбор: " c
    case "$c" in
      1) ask "Имя нового пользователя (a-z, 0-9, - _): " n
         ask "Секрет (Enter — сгенерировать): " v
         SECRET=$v; run_isolated users_add "$n"; SECRET=""; pause_menu ;;
      2) ask "Имя пользователя для отключения: " n; run_isolated users_set "$n" disabled; pause_menu ;;
      3) ask "Имя пользователя для включения: " n; run_isolated users_set "$n" enabled; pause_menu ;;
      4) ask "Имя пользователя для удаления: " n; run_isolated users_delete "$n"; pause_menu ;;
      5) ask "Имя пользователя: " n; ask "Новый лимит сессий: " v; run_isolated users_limit "$n" "$v"; pause_menu ;;
      6) run_isolated users_apply_cmd; pause_menu ;;
      7) run_isolated users_tune_limits; pause_menu ;;
      0|q|Q|"") return 0 ;;
      *) echo "Неверный выбор." >&3 ;;
    esac
  done
}

menu_install() {
  local d e s p
  while :; do
    ask "Домен для WEB-прокси (например tp.example.com, Enter — отмена): " d
    d="${d,,}"
    [[ -n $d ]] || { echo "Домен не указан." >&3; return 0; }
    if valid_domain "$d" && [[ $d == *.* ]]; then break; fi
    echo "  «$d» не похоже на домен (нужно имя вида tp.example.com, без https:// и порта). Попробуйте ещё раз." >&3
  done
  DOMAIN=$d
  while :; do
    ask "E-mail для Let's Encrypt (Enter — пропустить) [${EMAIL:-нет}]: " e
    [[ -z $e ]] && break
    if [[ $e =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then EMAIL=$e; break; fi
    echo "  «$e» не похоже на e-mail (нужен вид name@example.com). Enter — пропустить." >&3
  done
  {
    echo "Сайт-заглушка для relay:"
    echo "  1) автоматически (оставить существующий / сгенерировать)"
    echo "  2) каталог на сервере"
    echo "  3) архив (.tar.gz/.zip): путь или https-URL"
    echo "  4) git-репозиторий"
    echo "  5) сгенерировать новый уникальный сайт"
  } >&3
  while :; do
    ask "Выбор [1]: " s
    [[ ${s:-1} =~ ^[1-5]$ ]] && break
    echo "  Введите число от 1 до 5 (или Enter для 1)." >&3
  done
  case "${s:-1}" in
    2) ask "Путь к каталогу: " p; SITE_DIR_ARG=$p ;;
    3) ask "Путь или https-URL архива: " p; SITE_ARCHIVE=$p ;;
    4) ask "URL git-репозитория: " p; SITE_GIT=$p ;;
    5) SITE_AUTO=1 ;;
    *) : ;;
  esac
  do_install
}

# Операция меню — в подоболочке: die/ошибка вернёт в меню, а не завершит весь скрипт.
# (ловушки EXIT/ERR в подоболочке сбрасываются, поэтому ставим их заново)
run_isolated() {
  set +e
  ( set -Ee
    trap cleanup EXIT
    trap 'rc=$?; printf "ОШИБКА: код %s, строка %s (лог: %s)\n" "$rc" "$LINENO" "$LOG_FILE" >&2' ERR
    "$@" )
  LAST_RC=$?
  set -e
  return 0
}

pause_menu() {
  local x
  if (( LAST_RC != 0 )); then
    printf '\nОперация завершилась с ошибкой (код %s). Подробности выше и в %s\n' "$LAST_RC" "$LOG_FILE" >&3
  fi
  LAST_RC=0
  ask $'\nНажмите Enter, чтобы вернуться в меню... ' x
  return 0
}

menu() {
  have_tty || die "Для меню нужен интерактивный терминал. Используйте команды: install | uninstall | restore | reinstall | show (см. --help)."
  local c
  while :; do
    print_status
    cat >&3 <<'EOF'
  1) Установить
  2) Удалить
  3) Удалить и восстановиться из бэкапов
  4) Переустановить
  5) Показать конфиг веб-прокси
  6) Пользователи (секреты, отключение)
  7) Обновить адреса серверов Telegram (MTProxy)
  0) Выход
EOF
    ask "Выбор: " c
    case "$c" in
      1) run_isolated menu_install; pause_menu ;;
      2) RESTORE_MODE=0; run_isolated do_uninstall; pause_menu ;;
      3) RESTORE_MODE=1; run_isolated do_uninstall; RESTORE_MODE=0; pause_menu ;;
      4) run_isolated do_reinstall; pause_menu ;;
      5) run_isolated do_show; pause_menu ;;
      6) menu_users ;;
      7) run_isolated do_refresh; pause_menu ;;
      0|q|Q|"") exit 0 ;;
      *) echo "Неверный выбор." >&3 ;;
    esac
    # параметры одной операции не должны «протекать» в следующую
    DOMAIN=""; SITE_DIR_ARG=""; SITE_ARCHIVE=""; SITE_GIT=""; SITE_AUTO=0; SECRET=""
  done
}

# ------------------------------------------------------------------ main
main() {
  require_root
  setup_logging
  case "$CMD" in
    menu)      menu ;;
    install)   do_install ;;
    uninstall) RESTORE_MODE=0; do_uninstall ;;
    restore)   RESTORE_MODE=1; do_uninstall ;;
    reinstall) do_reinstall ;;
    show)      do_show ;;
    users)     do_users ;;
    refresh)   do_refresh ;;
    *)         usage >&3; die "Неизвестная команда: $CMD" ;;
  esac
}

main "$@"
