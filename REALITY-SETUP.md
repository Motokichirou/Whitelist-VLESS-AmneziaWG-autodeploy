# REALITY-inbound в 3X-UI (exit-узел) — настройка камуфляжа

После `deploy-3xui.sh` панель поднята за Authelia. Здесь — как создать VLESS+REALITY inbound с
камуфляжем под обычный HTTPS-сайт, и чтобы ссылка сразу выходила под адрес регионального релея.

> Назначение — транспорт к **своей** инфраструктуре. Используйте в рамках применимого законодательства.

## 1. Выбор камуфляж-домена (dest/SNI)

REALITY маскирует соединение под обычный TLS-хэндшейк к выбранному домену. Цель должна поддерживать
**TLS 1.3 + HTTP/2 + X25519** и быть стабильной. Подойдёт крупный CDN/статик-хост:

- **Основной:** `yastatic.net` (статик-CDN, стабилен, без редиректов)
- **Резерв:** `avatars.mds.yandex.net`

Проверить кандидата (с exit-узла):

```bash
echo | openssl s_client -connect yastatic.net:443 -servername yastatic.net -tls1_3 2>/dev/null \
  | grep -E "Protocol|Cipher"          # ждём TLSv1.3
curl -sI --http2 https://yastatic.net | head -n1   # ждём HTTP/2
```

## 2. Создать inbound (3X-UI v2 — вкладки)

**Inbounds → «+»** (Создать подключение). Раскладка по вкладкам:

**Основное:**
- Примечание: `reality-<имя>` · Протокол: `vless` · Адрес: пусто · **Порт: `8443`**

**Протокол:** ничего не меняем — Расшифрование/Шифрование `none`; кнопки «Аутентификация X25519/ML-KEM»
не жать (это VLESS-native шифрование, не REALITY); **Vision testseed** — оставить дефолт (`900/500/900/256`,
это паддинг Vision для xtls-rprx-vision); Fallback'и не нужны.

**Поток:**
- Транспорт: `RAW` (=TCP)
- **External Proxy: включить** → добавить запись (это и делает ссылку под релей):
  - Принудительный TLS: **`Тот же` (Same)**
  - Адрес: **`<АДРЕС_РЕЛЕЯ>`** (напр. публичный IP RU-релея)
  - Порт: **`443`**
  - Remark: `relay`

**Безопасность:** тип **`Reality`**
- uTLS: `chrome`
- Цель (dest): `yastatic.net:443`
- SNI / serverNames: `yastatic.net`
- Публичный/Приватный ключ: нажать генерацию x25519 (**один раз**, не пересоздавать)
- Short IDs: сгенерировать (дефолтный набор ок)
- SpiderX: `/` · mldsa65 Seed/Verify: пусто · Xver: 0

**Создать.** Затем открыть инбаунд → **добавить клиента**: привязать этот инбаунд → появится поле
**Flow → `xtls-rprx-vision`** → создать.

## 3. Клиентская vless://-ссылка

У инбаунда → кнопка ссылки/QR. Благодаря **External Proxy** ссылка **сразу содержит адрес релея**,
править вручную не нужно. Проверь, что в ней:

```
vless://<uuid>@<АДРЕС_РЕЛЕЯ>:443?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=yastatic.net&pbk=<pbk>&sid=<sid>&spx=%2F...#...
```

Ключевое: `@<АДРЕС_РЕЛЕЯ>:443`, `security=reality`, `flow=xtls-rprx-vision`, `fp=chrome`, `sni=yastatic.net`.
`fp=chrome` (uTLS) важен — клиентский ClientHello мимикрирует под Chrome; держи клиент свежим.

Клиенты на телефон: iOS — Happ / Streisand; Android — v2rayNG / husi.

## 4. Стыковка релея и exit-узла — DNAT в контейнере

Полный путь:
```
клиент →(REALITY, SNI=yastatic.net)→ <АДРЕС_РЕЛЕЯ>:443
        →(релей: DNAT → шифрованный туннель)→ exit-узел wg0 10.8.0.1:443
        →(DNAT в контейнере amnezia)→ 172.17.0.1:8443 (REALITY 3x-ui) → терминируется
```

`amnezia-wg-easy` держит `wg0` (10.8.0.1) внутри своего netns, поэтому REALITY (контейнер 3x-ui)
напрямую недостижим. Решение без host-net и без рестарта контейнера: 3x-ui публикует REALITY на
`172.17.0.1:8443` (docker0-gateway хоста), а внутри контейнера amnezia туннельный `:443` DNAT-им
туда. **Команды (на exit-узле, обратимо):**

> ⚠️ **КРИТИЧНО: `-d 10.8.0.1` обязателен.** Без него DNAT ловит TCP:443 от ВСЕХ клиентов wg-easy
> (телефоны, роутеры) и заворачивает их HTTPS в REALITY → тот проксирует на dest (`yastatic.net`),
> и у клиентов весь HTTPS отдаёт чужой сертификат (`*.cdn.yandex.net`) и 404 — обход ломается для
> всех. `-d 10.8.0.1` сужает правило только до трафика, который шлёт релей (на туннельный IP NL).

```bash
docker exec amnezia-wg-easy iptables -t nat -A PREROUTING -i wg0 -p tcp -d 10.8.0.1 --dport 443 \
  -j DNAT --to-destination 172.17.0.1:8443
docker exec amnezia-wg-easy iptables -t nat -A POSTROUTING -d 172.17.0.1 -p tcp \
  --dport 8443 -j MASQUERADE
# проверить:
docker exec amnezia-wg-easy iptables -t nat -S | grep -E '443|8443'
# ОТКАТ (-D вместо -A):
docker exec amnezia-wg-easy iptables -t nat -D PREROUTING -i wg0 -p tcp -d 10.8.0.1 --dport 443 \
  -j DNAT --to-destination 172.17.0.1:8443
docker exec amnezia-wg-easy iptables -t nat -D POSTROUTING -d 172.17.0.1 -p tcp \
  --dport 8443 -j MASQUERADE
```

## 5. Проверка (с любой машины, до теста клиентом)

REALITY на неаутентифицированном клиенте прозрачно проксирует на dest — это и проверяем:
```bash
curl -sI --resolve yastatic.net:443:<АДРЕС_РЕЛЕЯ> https://yastatic.net/ | head
```
Валидный ответ (заголовки nginx/302 от yastatic) = вся труба релей→туннель→exit→REALITY→dest жива.
Затем — настоящий клиент: импортируй `vless://`, подключись, проверь выходной IP (должен стать IP exit-узла).

> Правила в контейнере **не персистят** через пересоздание контейнера amnezia (переживают рестарт).
> Если путь встаёт, но страницы висят/рвутся — MSS-клэмп на релее:
> `iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`.
