# Whitelist · VLESS · AmneziaWG — self-hosted autodeploy

Самохостед-стек для обхода блокировок РФ в **двух режимах**:

1. **DPI-блокировки** (режут «то, что похоже на VPN») → **AmneziaWG** (обфусцированный WireGuard).
2. **Режим белых списков** (оператор пускает только забелённые IP+SNI, всё прочее режет/блокирует) →
   **VLESS + REALITY** с подменой SNI на белый домен, через RU-релей с белым IP.

Вторая прослойка строится **поверх** первой: зарубежный AmneziaWG-VPS становится финальным egress,
а RU-релей с белым IP — точкой входа, переживающей вайтлист.

```
                 ┌── DPI-режим ────────────────────────────────────────────────┐
клиент ─AmneziaWG─────────────────────────────────────────────▶ NL exit-VPS ──▶ интернет
                 └─────────────────────────────────────────────────────────────┘

                 ┌── режим белых списков (IP+SNI) ─────────────────────────────┐
телефон ─VLESS+REALITY(SNI=белый)─▶ Яндекс:443 (белый RU-IP, тонкий релей)
        ─(DNAT → AmneziaWG-туннель)─▶ NL exit-VPS: REALITY терминируется ──▶ интернет
                 └─────────────────────────────────────────────────────────────┘
```

## Когда какая прослойка

| Симптом | Что это | Решение |
| --- | --- | --- |
| VPN-протоколы рвутся/не коннектятся, обычный сайт открывается | DPI | хватает AmneziaWG (прослойка 1) |
| `yandex.ru` открывается, `1.1.1.1`/`yahoo.com` — нет; VPN мёртв | белый список | нужен REALITY + белый IP (прослойка 2) |
| Ничего не грузится, даже белое | блэкаут/троттлинг | **не лечится туннелем** (см. «Потолок») |

Проверка режима: открой белый домен по не-белому IP. Прошло → SNI-only (хватит подмены SNI).
Не прошло → IP+SNI (нужен белый IP релея).

---

## Прослойка 1 — AmneziaWG (база)

### Сервер: `deploy-awg-portal.sh`
Разворачивает на чистой Ubuntu стек за Caddy + Authelia:
- **amnezia-wg-easy** — сервер AmneziaWG + веб-панель (userspace), наружу только `51820/udp`.
- **Caddy** — реверс-прокси с авто-TLS; apex и голый IP получают заглушку.
- **Authelia** — портал входа с паролем + 2FA (TOTP), единственный гейт к панели.

```bash
curl -fsSL "https://github.com/Motokichirou/Whitelist-VLESS-AmneziaWG-autodeploy/raw/refs/heads/main/deploy-awg-portal.sh" -o deploy-awg-portal.sh
sudo bash deploy-awg-portal.sh
```
Интерактивный (спрашивает домены/IP) — качай файл, не запускай через `curl | bash`. Идемпотентен;
том ключей `~/.amnezia-wg-easy` сохраняется. Подробности — в шапке скрипта и его выводе.

### Клиент MikroTik: `awg-client-mikrotik.rsc`
RouterOS 7.x: контейнер `awg-proxy` + selective-routing по `list-antifilter` (заблокированное —
в туннель, остальное — напрямую). Вставляешь `.conf` из панели в блок CONFIG, заливаешь,
`/import file=awg-client-mikrotik.rsc`. Детали — в шапке `.rsc`.

---

## Прослойка 2 — VLESS + REALITY (обход белых списков)

Нужна, когда оператор в режиме **IP+SNI**: AmneziaWG (UDP, без SNI, незабелённый IP) под вайтлистом
недостижим в принципе. Решение — **VLESS+REALITY поверх TCP:443** с подменой SNI на белый домен,
через RU-релей с белым IP. REALITY терминируется на NL — релей ничего не расшифровывает.

### Компоненты
- **`YANDEX-RELAY-SETUP.md`** — провижининг RU-ВМ с белым IP (Yandex Cloud), установка AmneziaWG,
  туннель до NL.
- **`relay-forward-setup.sh`** — на релее: проброс входящего `:443` внутрь AWG-туннеля + персист.
- **`deploy-3xui.sh`** — на NL: панель **3X-UI** (Xray) за тем же Caddy + Authelia, REALITY-inbound.
- **`REALITY-SETUP.md`** — настройка REALITY-inbound (выбор белого SNI, поля, `vless://`) +
  стыковочный DNAT в контейнере amnezia.
- **`Yandex-Cloud.conf.example`** — шаблон конфига релея.

### Белый SNI
Community-списки забелённого: [`hxehex/russia-mobile-internet-whitelist`](https://github.com/hxehex/russia-mobile-internet-whitelist).
Для REALITY-dest нужен белый домен с TLS 1.3 + HTTP/2 + X25519 — например **`yastatic.net`**
(резерв `avatars.mds.yandex.net`).

### Порядок развёртывания (прослойка 2)
1. `YANDEX-RELAY-SETUP.md` — поднять RU-релей с белым IP + туннель до NL.
2. На NL: `sudo bash deploy-3xui.sh` (нужна A-запись `<поддомен>` → NL) → создать REALITY-inbound.
3. `relay-forward-setup.sh` на релее + стыковочный DNAT на NL (`REALITY-SETUP.md`).
4. Собрать `vless://` (`address` = белый IP релея, `:443`) + QR на телефон.
   Клиенты: iOS — Happ/Streisand; Android — v2rayNG/husi.

---

## Безопасность
- Заглушка на apex/голом IP — обфускация от сканеров, не замена защиты. Реальную защиту держат
  TLS + сильный пароль + 2FA + свежий софт.
- **RU-релей завязан на личность** (телефон→паспорт) и память работающего сервиса видна гипервизору —
  поэтому REALITY и egress держим на зарубежном NL, а релей делаем тонким (знает только про NL).
  Хардening релея — в `YANDEX-RELAY-SETUP.md` §5.
- **Секреты не коммитим**: приватные ключи, реальные `.conf`, доступы — в `.gitignore`. Публикуется
  только код и обезличенные гайды.

## Потолок (честно)
REALITY + белый SNI решают **вайтлист**, но не физическое отключение. При полном блэкауте или
троттлинге до 14 кбит/с туннель едет по той же дохлой трубе — на стороне клиента это не лечится ничем.

## Карта файлов
| Файл | Слой | Где запускать |
| --- | --- | --- |
| `deploy-awg-portal.sh` | 1 | NL (сервер) |
| `awg-client-mikrotik.rsc` | 1 | MikroTik |
| `YANDEX-RELAY-SETUP.md` | 2 | гайд (RU-релей) |
| `relay-forward-setup.sh` | 2 | RU-релей |
| `deploy-3xui.sh` | 2 | NL (сервер) |
| `REALITY-SETUP.md` | 2 | гайд (NL + клиент) |
| `Yandex-Cloud.conf.example` | 2 | шаблон |
