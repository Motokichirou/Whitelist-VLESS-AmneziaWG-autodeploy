# AWG-портал — self-hosted AmneziaWG за Caddy + Authelia

Однофайловый скрипт (`deploy-awg-portal.sh`) разворачивает на чистой Ubuntu готовый стек для обхода DPI/блокировок:

- **amnezia-wg-easy** — сервер AmneziaWG + веб-панель (userspace, `wireguard-go`). Наружу торчит только `51820/udp`, сама панель висит на `127.0.0.1`.
- **Caddy** — реверс-прокси с авто-TLS (Let's Encrypt). Панель отдаётся только после авторизации; apex-домен и голый IP получают безликую заглушку.
- **Authelia** — портал входа с паролем и 2FA (TOTP). Единственный гейт к панели.

```
Интернет
  ├─ https://<apex>             → заглушка «Сайт в разработке»
  ├─ голый IP / неизвестный SNI → заглушка (self-signed)
  ├─ https://<auth-поддомен>    → портал входа Authelia (+ 2FA)
  └─ https://<panel-поддомен>   → Authelia → 127.0.0.1:51821 (панель wg-easy)
```

## Требования

- Ubuntu/Debian, доступ `root` (sudo).
- Домен и **три A-записи** на IP сервера: apex (заглушка), поддомен панели, поддомен портала.
- Открытые порты: `80/tcp` и `443/tcp` (TLS + выпуск сертификатов), `51820/udp` (WireGuard). Если у провайдера есть облачный фаервол — открой их и там.
- Docker не обязателен заранее — скрипт поставит его сам, если нет.

## Запуск

> ⚠️ Скрипт **интерактивный** (спрашивает домены и IP), поэтому его надо сначала **скачать**, а не запускать через `curl | bash` — в пайпе ввод не работает.

<!-- ───────────────────────────────────────────────────────────── -->
<!-- https://github.com/Motokichirou/AmneziaWG-autodeploy/raw/refs/heads/main/deploy-awg-portal.sh -->
<!-- ───────────────────────────────────────────────────────────── -->

```bash
SCRIPT_URL="https://github.com/Motokichirou/AmneziaWG-autodeploy/raw/refs/heads/main/deploy-awg-portal.sh"

curl -fsSL "$SCRIPT_URL" -o deploy-awg-portal.sh
sudo bash deploy-awg-portal.sh
```

Одной строкой:

```bash
curl -fsSL "https://github.com/Motokichirou/AmneziaWG-autodeploy/raw/refs/heads/main/deploy-awg-portal.sh" -o deploy-awg-portal.sh && sudo bash deploy-awg-portal.sh
```

## Что спросит

| Запрос | По умолчанию |
| --- | --- |
| Домен-заглушка (apex) | — |
| Поддомен админки | `panel.<домен>` |
| Поддомен портала входа | `auth.<домен>` |
| Публичный IP / DDNS сервера | автоопределение |

## Что выдаст в конце

- Ссылку на админку, логин `admin` и сгенерированный пароль.
- 2FA: **QR прямо в терминале** + base32-секрет + `otpauth://` URI — добавь в Google Authenticator / Aegis.
- Команду посмотреть текущий код с сервера: `oathtool --totp -b "<секрет>"`.

Вход: открой `https://<panel>` → логин/пароль → 6-значный код.

> Пароль и секрет 2FA печатаются **один раз** — сохрани вывод.

## Обслуживание

Файлы стека: `/opt/awg-portal`.

```bash
# статус контейнеров
docker ps

# логи
docker compose -f /opt/awg-portal/docker-compose.yml logs -f caddy authelia

# перевыпустить 2FA (новый секрет)
docker run --rm -v /opt/awg-portal/authelia:/config authelia/authelia:latest \
  authelia storage user totp generate admin --config /config/configuration.yml

# сменить пароль: сгенерить argon2-хеш…
docker run --rm authelia/authelia:latest \
  authelia crypto hash generate argon2 --password 'НОВЫЙ_ПАРОЛЬ'
# …вписать его в /opt/awg-portal/authelia/users_database.yml, затем:
docker compose -f /opt/awg-portal/docker-compose.yml restart authelia
```

## После установки

Зайди в панель и создай клиентов (телефон, роутер). Параметры обфускации AmneziaWG (`Jc/Jmin/Jmax/S1/S2/H1–H4`) сервер фиксирует при первом старте — их видно в сгенерированном `.conf` клиента, оттуда переноси на клиентов вроде MikroTik.

## Заметки

- Скрипт **идемпотентный**: повторный запуск пересоздаёт контейнеры; том `~/.amnezia-wg-easy` с ключами сервера и клиентами сохраняется.
- Разворачивается **только серверная часть**. Клиенты (включая MikroTik-прокси с awg-proxy) настраиваются отдельно.
- 2FA заводится заранее через CLI Authelia, поэтому код выдаётся сразу — без портальной регистрации через `notification.txt`.
- Заглушка — это обфускация от сканеров, а не замена защиты. Реальную защиту держат TLS, сильный пароль + 2FA и свежий софт.
---

## Клиент на MikroTik (RouterOS 7.x)

Скрипт `awg-client-mikrotik.rsc` поднимает на роутере клиента AmneziaWG: контейнер `awg-proxy` (обфускация AWG) + локальный WireGuard-интерфейс + masquerade + mangle + selective-routing. Заблокированные адреса (по `list-antifilter`) уходят в туннель, остальное — напрямую через провайдера.

```
LAN ──(dst ∈ list-antifilter)──▶ wg-awg-proxy ─▶ контейнер awg-proxy ──AWG──▶ сервер
LAN ──(всё остальное)──────────▶ обычный шлюз провайдера
```

### Предусловия (один раз, вручную)

- Включить контейнеры: `/system device-mode update container=yes` (требует подтверждения кнопкой/перезагрузки).
- Залить образ `awg-proxy` в **Files** (для ARM, напр. RB4011 — `awg-proxy-arm.tar.gz`); имя задаётся в tunable `imageFile`.
- На роутере есть бридж в interface-list `LAN` (defconf) и WAN на `ether1`.

### Запуск

1. В панели wg-easy создай клиента и скачай его `.conf`.
2. Открой `awg-client-mikrotik.rsc` и вставь содержимое `.conf` в блок `CONFIG` вверху — **это единственное, что нужно вставить**.
3. Залей файл на роутер и выполни:

```
/import file=awg-client-mikrotik.rsc
```

`/import` надёжнее вставки в терминал: встроенный `rkn-unblock` идёт длинной строкой `source="…"`.

### Что делает сам

- Разбирает `.conf`: приватный ключ, `Address`, серверный `PublicKey`, `Endpoint`, параметры AmneziaWG (`Jc/Jmin/Jmax/S1/S2/H1–H4`), `PresharedKey` (если есть).
- Создаёт veth + контейнер `awg-proxy` с нужными env (клиентский pubkey RouterOS вычисляет сам).
- Поднимает интерфейс `wg-awg-proxy` с **туннельным IP из `Address`** (не со служебным IP veth — иначе endpoint пира совпадает с собственным адресом интерфейса и рукопожатие уходит «в себя»: tx>0, rx=0).
- Вешает masquerade в туннель, mangle (`dst-address-list=list-antifilter`, `in-interface-list=LAN`) и дефолт `0.0.0.0/0` через туннель в таблице `rkn`.
- Встроенный `rkn-unblock` наполняет `list-antifilter` (чанковый фетч `antifilter.download/list/allyouneed.lst`) + планировщик раз в сутки.

Скрипт идемпотентный — повторный запуск пересоздаёт объекты (контейнер, интерфейс, NAT/mangle/route, `rkn-unblock`).

### Проверка

```
/interface wireguard peers print where interface=wg-awg-proxy
/container print where name=awg-proxy
/ip firewall address-list print count-only where list=list-antifilter
```

Через 10–30 c у пира должен появиться handshake и `rx > 0`.

> Тюнинг — в секции tunables вверху скрипта: имя образа, каталог rootfs, служебная veth-подсеть, `listen-port`, MTU. Частота обновления списка — в строке `/system scheduler … interval=1d`.
