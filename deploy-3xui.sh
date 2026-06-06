#!/usr/bin/env bash
#
# deploy-3xui.sh
# Идемпотентное РАСШИРЕНИЕ существующего стека /opt/awg-portal (Caddy + Authelia +
# amnezia-wg-easy). Добавляет панель 3X-UI (Xray) за тем же Caddy + Authelia (2FA),
# на новом поддомене. Панель висит приватно на 127.0.0.1:2053.
#
# REALITY-inbound в самой панели создаётся ОТДЕЛЬНО (см. REALITY-SETUP.md) — этот
# скрипт только поднимает панель и гейтит её Authelia.
#
# Запуск на NL:  sudo bash deploy-3xui.sh
#
set -euo pipefail

# ───────────── константы ─────────────
STACK_DIR="/opt/awg-portal"
COMPOSE="${STACK_DIR}/docker-compose.yml"
CADDYFILE="${STACK_DIR}/caddy/Caddyfile"
AUTHELIA_CFG="${STACK_DIR}/authelia/configuration.yml"
XUI_IMAGE="ghcr.io/mhsanaei/3x-ui:latest"
XUI_PORT=2053
REALITY_PORT=8443      # REALITY-inbound: слушает в контейнере, публикуется на 172.17.0.1 (docker0)
XUI_PATH="/panel/"     # фикс. webBasePath панели (иначе 3x-ui генерит случайный)

c_grn=$'\e[1;32m'; c_yel=$'\e[1;33m'; c_red=$'\e[1;31m'; c_cyn=$'\e[1;36m'; c_rst=$'\e[0m'
say()  { printf '%s[*]%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_rst" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

# ───────────── 0. проверки ─────────────
[ "$(id -u)" -eq 0 ] || die "Запусти от root: sudo bash $0"
[ -f "$COMPOSE" ]     || die "Не найден $COMPOSE — сперва разверни базовый стек (deploy-awg-portal.sh)."
[ -f "$CADDYFILE" ]   || die "Не найден $CADDYFILE."
[ -f "$AUTHELIA_CFG" ]|| die "Не найден $AUTHELIA_CFG."
docker compose version >/dev/null 2>&1 || die "Нет 'docker compose'."

# ───────────── 1. вытаскиваем домены из конфигов Authelia ─────────────
BASE_DOMAIN="$(grep -oP "^\s+domain:\s*'\K[^']+" "$AUTHELIA_CFG" | head -n1 || true)"
AUTH_HOST="$(grep -oP "authelia_url:\s*'https://\K[^']+" "$AUTHELIA_CFG" | head -n1 || true)"
[ -n "$BASE_DOMAIN" ] || die "Не смог вычислить базовый домен из $AUTHELIA_CFG."
[ -n "$AUTH_HOST" ]   || die "Не смог вычислить домен портала входа из $AUTHELIA_CFG."

say "Базовый домен:  ${BASE_DOMAIN}"
say "Портал входа:   ${AUTH_HOST}"
read -rp "Поддомен панели 3X-UI [xui.${BASE_DOMAIN}]: " XUI_HOST
XUI_HOST="${XUI_HOST:-xui.${BASE_DOMAIN}}"

echo
say "Панель 3X-UI:   https://${XUI_HOST}  (гейт — Authelia 2FA)"
warn "A-запись ${XUI_HOST} → этот сервер должна существовать ДО запуска (иначе Let's Encrypt не выдаст сертификат)."
read -rp "Продолжаем? [y/N]: " CONF
[[ "${CONF:-}" =~ ^[Yy]$ ]] || die "Отменено."

# ───────────── 2. docker-compose: сервис 3x-ui ─────────────
mkdir -p "${STACK_DIR}/3x-ui/db" "${STACK_DIR}/3x-ui/cert"
if grep -q 'container_name: 3x-ui' "$COMPOSE"; then
  warn "Сервис 3x-ui уже есть в compose — пропускаю добавление."
else
  say "Добавляю сервис 3x-ui в ${COMPOSE}…"
  cat >> "$COMPOSE" <<EOF

  3x-ui:
    image: ${XUI_IMAGE}
    container_name: 3x-ui
    restart: unless-stopped
    tty: true
    volumes:
      - ./3x-ui/db:/etc/x-ui
      - ./3x-ui/cert:/root/cert
    ports:
      - "127.0.0.1:${XUI_PORT}:${XUI_PORT}"
      - "172.17.0.1:${REALITY_PORT}:${REALITY_PORT}"
EOF
  ok "Сервис 3x-ui добавлен."
fi

# ───────────── 3. Caddy: сайт-блок панели за forward_auth ─────────────
if grep -q "^${XUI_HOST} {" "$CADDYFILE"; then
  warn "Сайт ${XUI_HOST} уже есть в Caddyfile — пропускаю."
else
  say "Добавляю сайт ${XUI_HOST} в Caddyfile…"
  cat >> "$CADDYFILE" <<EOF

# Панель 3X-UI — пускаем только после Authelia
${XUI_HOST} {
    forward_auth 127.0.0.1:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
    reverse_proxy 127.0.0.1:${XUI_PORT}
}
EOF
  ok "Сайт добавлен."
fi

# ───────────── 4. Authelia: правило доступа two_factor ─────────────
if grep -q "domain: '${XUI_HOST}'" "$AUTHELIA_CFG"; then
  warn "Правило доступа для ${XUI_HOST} уже есть — пропускаю."
else
  say "Добавляю правило two_factor для ${XUI_HOST} в Authelia…"
  awk -v host="$XUI_HOST" '
    {print}
    /^  rules:$/ && !done {
      print "    - domain: \x27" host "\x27"
      print "      policy: \x27two_factor\x27"
      done=1
    }' "$AUTHELIA_CFG" > "${AUTHELIA_CFG}.tmp" && mv "${AUTHELIA_CFG}.tmp" "$AUTHELIA_CFG"
  chmod 600 "$AUTHELIA_CFG"
  grep -q "domain: '${XUI_HOST}'" "$AUTHELIA_CFG" || die "Не удалось вставить правило в Authelia."
  ok "Правило добавлено."
fi

# ───────────── 5. поднимаем/перечитываем ─────────────
say "Поднимаю 3x-ui и перечитываю Caddy + Authelia…"
( cd "$STACK_DIR" && docker compose up -d 3x-ui )
( cd "$STACK_DIR" && docker compose restart authelia )
# мягкий reload Caddy без даунтайма; если не вышло — рестарт
if ! ( cd "$STACK_DIR" && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile ) 2>/dev/null; then
  ( cd "$STACK_DIR" && docker compose restart caddy )
fi

# ───────────── 6. ждём панель и достаём дефолтные креды/путь ─────────────
say "Жду старт 3x-ui…"
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Running}}' 3x-ui 2>/dev/null || echo false)" = "true" ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' 3x-ui 2>/dev/null || echo false)" = "true" ] \
  || { docker logs --tail 30 3x-ui || true; die "3x-ui не запустилась."; }
sleep 3

# 3x-ui на первом старте генерит случайные порт/путь/креды — фиксируем детерминированно.
# Внутри контейнера панель слушает 0.0.0.0:${XUI_PORT} (НЕ listenIP — иначе docker-proxy не достучится);
# приватность даёт публикация только на 127.0.0.1.
if grep -q 'container_name: 3x-ui' "$COMPOSE" && [ ! -f "${STACK_DIR}/3x-ui/.pinned" ]; then
  XUI_USER="admin"
  XUI_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
  say "Фиксирую панель: порт ${XUI_PORT}, путь ${XUI_PATH}, логин ${XUI_USER}…"
  docker exec 3x-ui /app/x-ui setting -port "$XUI_PORT" -webBasePath "$XUI_PATH" \
    -username "$XUI_USER" -password "$XUI_PASS" >/dev/null 2>&1 || warn "Не удалось применить настройки панели."
  ( cd "$STACK_DIR" && docker compose restart 3x-ui >/dev/null 2>&1 ) || true
  touch "${STACK_DIR}/3x-ui/.pinned"
  sleep 3
fi
XUI_SETTINGS="$(docker exec 3x-ui /app/x-ui setting -show 2>/dev/null || true)"

# ───────────── 7. итог ─────────────
echo
echo "════════════════════════════════════════════════════════════"
ok  "ГОТОВО. Панель 3X-UI поднята за Authelia."
echo "════════════════════════════════════════════════════════════"
echo
printf '%sПанель:%s  https://%s\n' "$c_grn" "$c_rst" "$XUI_HOST"
printf '%sГейт:%s    Authelia (логин/пароль + 2FA того же admin, что и wg-easy)\n' "$c_grn" "$c_rst"
echo
echo "── доступ к самой 3X-UI (вторичный логин панели) ──"
printf '%sURL панели:%s https://%s%s\n' "$c_grn" "$c_rst" "$XUI_HOST" "$XUI_PATH"
if [ -n "${XUI_USER:-}" ]; then
  printf '%sЛогин:%s     %s\n' "$c_yel" "$c_rst" "$XUI_USER"
  printf '%sПароль:%s    %s\n' "$c_yel" "$c_rst" "${XUI_PASS:-—}"
  warn "Креды панели печатаются один раз — сохрани (вход всё равно ещё и за Authelia 2FA)."
else
  echo "Настройки (порт/путь):"; echo "$XUI_SETTINGS" | grep -Ei 'port|webBasePath' || true
  echo "Логин/пароль панели не переустанавливались — см. docker logs 3x-ui (первый старт)."
fi
echo
echo "── дальше: REALITY-inbound (см. REALITY-SETUP.md) ──"
echo "  1) Зайди в панель → Inbounds → создай VLESS+REALITY."
echo "     • Port (внутри контейнера): ${REALITY_PORT}   (наружу опубликован на 172.17.0.1:${REALITY_PORT})"
echo "     • SNI/dest: yastatic.net:443  (резерв avatars.mds.yandex.net)"
echo "     • flow xtls-rprx-vision, fp chrome, x25519-кейпара в панели, shortId."
echo "  2) Стыковочный DNAT в контейнере amnezia (живо, без рестарта, обратимо):"
echo "       docker exec amnezia-wg-easy iptables -t nat -A PREROUTING -i wg0 -p tcp --dport 443 \\"
echo "         -j DNAT --to-destination 172.17.0.1:${REALITY_PORT}"
echo "       docker exec amnezia-wg-easy iptables -t nat -A POSTROUTING -d 172.17.0.1 -p tcp \\"
echo "         --dport ${REALITY_PORT} -j MASQUERADE"
echo "  3) Релей уже шлёт :443 в туннель на 10.8.0.1:443 — после DNAT цепочка замкнётся."
echo
warn "Порт ${XUI_PORT} (панель) и ${REALITY_PORT} (REALITY) наружу НЕ открывай — оба слушают приватно."
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E '3x-ui|amnezia-wg-easy|authelia|caddy' || true
