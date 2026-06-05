#!/usr/bin/env bash
#
# deploy-awg-portal.sh
# Развёртывание на чистом Ubuntu: AmneziaWG (amnezia-wg-easy, userspace)
# за Caddy + Authelia (портал входа с 2FA). Заглушка на apex и голом IP.
#
# Запуск:  sudo bash deploy-awg-portal.sh
#
set -euo pipefail

# ───────────── константы ─────────────
STACK_DIR="/opt/awg-portal"
AUTHELIA_DIR="${STACK_DIR}/authelia"
COMPOSE="${STACK_DIR}/docker-compose.yml"
AUTHELIA_IMAGE="authelia/authelia:latest"
WGEASY_IMAGE="ghcr.io/w0rng/amnezia-wg-easy"
ADMIN_USER="admin"

c_grn=$'\e[1;32m'; c_yel=$'\e[1;33m'; c_red=$'\e[1;31m'; c_cyn=$'\e[1;36m'; c_rst=$'\e[0m'
say()  { printf '%s[*]%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_rst" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

# ───────────── 0. проверки ─────────────
[ "$(id -u)" -eq 0 ] || die "Запусти от root: sudo bash $0"
command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Ubuntu/Debian (apt)."
say "Развёртывание AWG-портала в ${STACK_DIR}"

# ───────────── 1. ввод от пользователя ─────────────
detect_ip() { ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' 2>/dev/null | head -n1 || true; }

read -rp "Домен-заглушка (apex), напр. example.com: " BASE_DOMAIN
[ -n "${BASE_DOMAIN:-}" ] || die "Домен обязателен."
BASE_DOMAIN="${BASE_DOMAIN#http://}"; BASE_DOMAIN="${BASE_DOMAIN#https://}"; BASE_DOMAIN="${BASE_DOMAIN%%/*}"

read -rp "Поддомен админки [panel.${BASE_DOMAIN}]: " PANEL_HOST
PANEL_HOST="${PANEL_HOST:-panel.${BASE_DOMAIN}}"

read -rp "Поддомен портала входа [auth.${BASE_DOMAIN}]: " AUTH_HOST
AUTH_HOST="${AUTH_HOST:-auth.${BASE_DOMAIN}}"

DEF_IP="$(detect_ip)"
read -rp "Публичный IP или DDNS сервера [${DEF_IP}]: " WG_HOST
WG_HOST="${WG_HOST:-$DEF_IP}"
[ -n "${WG_HOST:-}" ] || die "Не удалось определить адрес сервера — впиши вручную."

echo
say "Заглушка:      https://${BASE_DOMAIN}   (и голый IP)"
say "Админка:       https://${PANEL_HOST}"
say "Портал входа:  https://${AUTH_HOST}"
say "WG endpoint:   ${WG_HOST}:51820/udp"
warn "Перед запуском A-записи ${BASE_DOMAIN}, ${PANEL_HOST}, ${AUTH_HOST} должны указывать на этот сервер,"
warn "иначе Let's Encrypt не выдаст сертификаты."
read -rp "Всё верно, продолжаем? [y/N]: " CONF
[[ "${CONF:-}" =~ ^[Yy]$ ]] || die "Отменено."

# ───────────── 2. зависимости ─────────────
say "Проверяю зависимости…"
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  say "Ставлю Docker…"; curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "Нет 'docker compose'. Обнови Docker до актуальной версии."
PKGS=()
command -v openssl  >/dev/null 2>&1 || PKGS+=(openssl)
command -v qrencode >/dev/null 2>&1 || PKGS+=(qrencode)
command -v oathtool >/dev/null 2>&1 || PKGS+=(oathtool)
command -v curl     >/dev/null 2>&1 || PKGS+=(curl)
[ "${#PKGS[@]}" -gt 0 ] && { apt-get update -qq; apt-get install -y -qq "${PKGS[@]}"; }
ok "Зависимости готовы."

# ───────────── 3. подготовка хоста под userspace WireGuard ─────────────
# amnezia-wg-easy здесь работает в userspace (wireguard-go), а он конфликтует
# со штатным модулем wireguard и требует /dev/net/tun.
say "Готовлю хост (блокирую штатный модуль wireguard, поднимаю tun)…"
cat > /etc/modprobe.d/blacklist-wireguard.conf <<'EOF'
blacklist wireguard
install wireguard /bin/true
EOF
rmmod wireguard 2>/dev/null || true
modprobe tun 2>/dev/null || true
if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net && mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun
fi
echo tun > /etc/modules-load.d/tun.conf
ok "Хост готов."

# ───────────── 4. секреты и пароль ─────────────
say "Генерирую секреты и пароль администратора…"
JWT_SECRET="$(openssl rand -hex 64)"
SESSION_SECRET="$(openssl rand -hex 64)"
STORAGE_KEY="$(openssl rand -hex 64)"
ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
ARGON2_HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
  authelia crypto hash generate argon2 --password "$ADMIN_PASSWORD" \
  | grep -oE '\$argon2id\$\S+' || true)"
[ -n "$ARGON2_HASH" ] || die "Не удалось сгенерировать argon2-хеш пароля."
ok "Секреты готовы."

# ───────────── 5. каталоги и конфиги ─────────────
say "Пишу конфиги в ${STACK_DIR}…"
mkdir -p "${AUTHELIA_DIR}" "${STACK_DIR}/caddy/data" "${STACK_DIR}/caddy/config" "${STACK_DIR}/decoy"

cat > "${STACK_DIR}/decoy/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ой</title>
  <style>
    body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
         font-family:system-ui,Segoe UI,Roboto,sans-serif;background:#f5f6f8;color:#222}
    .card{text-align:center;padding:40px}
    h1{font-weight:600;margin:0 0 10px;font-size:1.6rem}
    p{color:#777;margin:0}
  </style>
</head>
<body>
  <div class="card">
    <h1>Ой, тут пока ничего нет</h1>
    <p>Сайт в разработке.</p>
  </div>
</body>
</html>
EOF

cat > "${AUTHELIA_DIR}/configuration.yml" <<EOF
server:
  address: 'tcp://0.0.0.0:9091'

log:
  level: 'info'

totp:
  issuer: '${BASE_DOMAIN}'

identity_validation:
  reset_password:
    jwt_secret: '${JWT_SECRET}'

authentication_backend:
  file:
    path: '/config/users_database.yml'

access_control:
  default_policy: 'deny'
  rules:
    - domain: '${PANEL_HOST}'
      policy: 'two_factor'

session:
  secret: '${SESSION_SECRET}'
  cookies:
    - name: 'authelia_session'
      domain: '${BASE_DOMAIN}'
      authelia_url: 'https://${AUTH_HOST}'
      default_redirection_url: 'https://${PANEL_HOST}'
      expiration: '1 hour'
      inactivity: '5 minutes'

regulation:
  max_retries: 3
  find_time: '2 minutes'
  ban_time: '5 minutes'

storage:
  encryption_key: '${STORAGE_KEY}'
  local:
    path: '/config/db.sqlite3'

notifier:
  filesystem:
    filename: '/config/notification.txt'
EOF

cat > "${AUTHELIA_DIR}/users_database.yml" <<EOF
users:
  ${ADMIN_USER}:
    disabled: false
    displayname: 'Admin'
    password: '${ARGON2_HASH}'
    email: 'admin@${BASE_DOMAIN}'
    groups:
      - 'admins'
EOF

cat > "${STACK_DIR}/caddy/Caddyfile" <<EOF
# Боевая панель — пускаем только после Authelia
${PANEL_HOST} {
    forward_auth 127.0.0.1:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
    reverse_proxy 127.0.0.1:51821
}

# Портал входа Authelia
${AUTH_HOST} {
    reverse_proxy 127.0.0.1:9091
}

# Заглушка — apex
${BASE_DOMAIN} {
    root * /srv/decoy
    file_server
}

# Заглушка — голый IP и неизвестный SNI
:443 {
    tls internal
    root * /srv/decoy
    file_server
}
EOF

cat > "${COMPOSE}" <<EOF
services:
  authelia:
    image: ${AUTHELIA_IMAGE}
    container_name: authelia
    restart: unless-stopped
    volumes:
      - ./authelia:/config
    ports:
      - "127.0.0.1:9091:9091"

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    network_mode: host
    depends_on:
      - authelia
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./decoy:/srv/decoy:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
EOF

chmod 600 "${AUTHELIA_DIR}/configuration.yml" "${AUTHELIA_DIR}/users_database.yml"
ok "Конфиги записаны."

# ───────────── 6. amnezia-wg-easy (userspace AWG, без пароля панели) ─────────────
# WG_DEVICE=eth0 — это интерфейс ВНУТРИ контейнера (а не хоста); по нему делается masquerade.
say "Поднимаю amnezia-wg-easy…"
docker rm -f amnezia-wg-easy >/dev/null 2>&1 || true
docker run -d \
  --name=amnezia-wg-easy \
  --restart unless-stopped \
  -e LANG=ru \
  -e WG_HOST="${WG_HOST}" \
  -e PORT=51821 \
  -e WG_PORT=51820 \
  -e WG_DEVICE=eth0 \
  -e WG_DEFAULT_DNS=1.1.1.1 \
  -v /root/.amnezia-wg-easy:/etc/wireguard \
  -p 51820:51820/udp \
  -p 127.0.0.1:51821:51821/tcp \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
  --sysctl="net.ipv4.ip_forward=1" \
  --device=/dev/net/tun:/dev/net/tun \
  "$WGEASY_IMAGE" >/dev/null
ok "amnezia-wg-easy запущен (гейт только Authelia, своего пароля у панели нет)."

# ───────────── 7. Caddy + Authelia ─────────────
say "Поднимаю Caddy + Authelia (TLS-сертификаты могут занять до минуты)…"
( cd "$STACK_DIR" && docker compose up -d )

# проверяем, что Authelia не упала на конфиге
say "Жду инициализации Authelia…"
for _ in $(seq 1 30); do [ -f "${AUTHELIA_DIR}/db.sqlite3" ] && break; sleep 1; done
sleep 4
if [ "$(docker inspect -f '{{.State.Running}}' authelia 2>/dev/null || echo false)" != "true" ]; then
  warn "Authelia не запустилась. Лог:"; docker logs --tail 30 authelia || true
  die "Останов: проверь configuration.yml."
fi

# ───────────── 8. предзагрузка TOTP (2FA) ─────────────
# БД уже мигрирована стартом Authelia; глушим её на пару секунд, чтобы не держала sqlite,
# и заводим TOTP-конфиг (секрет шифруется ключом из конфига — иначе не вставить вручную).
say "Готовлю 2FA для ${ADMIN_USER}…"
( cd "$STACK_DIR" && docker compose stop authelia >/dev/null 2>&1 ) || true
TOTP_OUT="$(docker run --rm -v "${AUTHELIA_DIR}":/config "$AUTHELIA_IMAGE" \
  authelia storage user totp generate "$ADMIN_USER" --config /config/configuration.yml 2>&1 || true)"
( cd "$STACK_DIR" && docker compose start authelia >/dev/null 2>&1 ) || true
TOTP_URI="$(printf '%s' "$TOTP_OUT" | grep -oE "otpauth://[^[:space:]']+" | head -n1 || true)"
TOTP_SECRET="$(printf '%s' "$TOTP_URI" | grep -oE 'secret=[A-Z2-7]+' | cut -d= -f2 || true)"
[ -n "$TOTP_URI" ] && ok "2FA подготовлена." || warn "TOTP-URI не захватился автоматически (см. итог)."

# ───────────── 9. ufw (если активен) ─────────────
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  say "ufw активен — открываю 80,443/tcp и 51820/udp…"
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 51820/udp >/dev/null 2>&1 || true
fi

sleep 6

# ───────────── 10. итог ─────────────
echo
echo "════════════════════════════════════════════════════════════"
ok  "ГОТОВО. Стек развёрнут."
echo "════════════════════════════════════════════════════════════"
echo
printf '%sАдминка (вход):%s  https://%s\n' "$c_grn" "$c_rst" "$PANEL_HOST"
printf '%sПортал входа:%s    https://%s\n'  "$c_grn" "$c_rst" "$AUTH_HOST"
printf '%sЗаглушка:%s        https://%s   (и голый IP)\n' "$c_grn" "$c_rst" "$BASE_DOMAIN"
echo
printf '%sЛогин:%s   %s\n'  "$c_yel" "$c_rst" "$ADMIN_USER"
printf '%sПароль:%s  %s\n'  "$c_yel" "$c_rst" "$ADMIN_PASSWORD"
echo
echo "── 2FA (TOTP) ──"
if [ -n "${TOTP_URI:-}" ]; then
  echo "Отсканируй QR в Google Authenticator / Aegis:"
  echo
  qrencode -t ANSIUTF8 "$TOTP_URI" 2>/dev/null || true
  echo
  printf '%sСекрет (base32):%s %s\n' "$c_cyn" "$c_rst" "${TOTP_SECRET:-—}"
  printf '%sURI:%s            %s\n'  "$c_cyn" "$c_rst" "$TOTP_URI"
  echo
  echo "Посмотреть текущий 6-значный код с сервера (если телефона нет под рукой):"
  echo "    oathtool --totp -b \"${TOTP_SECRET}\""
else
  warn "Сгенерируй код 2FA вручную:"
  echo "    docker run --rm -v ${AUTHELIA_DIR}:/config ${AUTHELIA_IMAGE} \\"
  echo "      authelia storage user totp generate ${ADMIN_USER} --config /config/configuration.yml"
  echo "  затем добавь полученный otpauth:// URI в приложение-аутентификатор."
fi
echo
echo "Вход: открой https://${PANEL_HOST} → логин/пароль → 6-значный код."
echo
echo "── обслуживание ──"
echo "  Перевыпустить код 2FA:  docker run --rm -v ${AUTHELIA_DIR}:/config ${AUTHELIA_IMAGE} \\"
echo "                            authelia storage user totp generate ${ADMIN_USER} --config /config/configuration.yml"
echo "  Сменить пароль:         сгенерируй argon2 (authelia crypto hash generate argon2 --password '…'),"
echo "                          впиши в ${AUTHELIA_DIR}/users_database.yml → docker compose -f ${COMPOSE} restart authelia"
echo "  Статус:                 docker ps"
echo "  Логи:                   docker compose -f ${COMPOSE} logs -f caddy authelia"
echo
warn "Сохрани этот вывод: пароль и секрет 2FA больше нигде не показываются."
warn "Если у провайдера есть внешний фаервол — открой 80/tcp, 443/tcp, 51820/udp."
echo
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'amnezia-wg-easy|authelia|caddy' || true
