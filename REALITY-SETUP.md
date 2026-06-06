# REALITY-inbound в 3X-UI (exit-узел) — настройка камуфляжа

После `deploy-3xui.sh` панель поднята за Authelia. Здесь — как создать VLESS+REALITY inbound с
камуфляжем под обычный HTTPS-сайт.

> Назначение — транспорт к **своей** инфраструктуре. Используйте в рамках применимого законодательства.

## 1. Выбор камуфляж-домена (dest/SNI)

REALITY маскирует соединение под обычный TLS-хэндшейк к выбранному домену. Цель должна поддерживать
**TLS 1.3 + HTTP/2 + X25519** и быть стабильной. Подойдёт крупный CDN/статик-хост:

- **Основной:** `yastatic.net` (статик-CDN, стабилен, без редиректов)
- **Резерв:** `avatars.mds.yandex.net`

Проверить кандидата (с exit-узла):

```bash
# TLS 1.3?
echo | openssl s_client -connect yastatic.net:443 -servername yastatic.net -tls1_3 2>/dev/null \
  | grep -E "Protocol|Cipher"
# HTTP/2 (h2 в ALPN)?
curl -sI --http2 https://yastatic.net | head -n1
```

Нужны `TLSv1.3` и `HTTP/2`. Если домен не даёт — бери резервный.

## 2. Inbound в панели

В 3X-UI: **Inbounds → Add Inbound**

| Поле | Значение |
| --- | --- |
| Protocol | `vless` |
| Listen IP | (пусто / `0.0.0.0`) — слушаем внутри контейнера, наружу публикуется на `172.17.0.1:8443` |
| Port | `8443` |
| Flow (у клиента) | `xtls-rprx-vision` |
| Security | `reality` |
| uTLS / Fingerprint | `chrome` |
| Dest (target) | `yastatic.net:443` |
| SNI / serverNames | `yastatic.net` |
| PrivateKey/PublicKey | кнопка генерации x25519 в панели |
| shortIds | сгенерировать (оставить дефолтный набор можно) |
| spiderX | `/` |

Создай VLESS-клиента (UUID сгенерится). Сохрани **publicKey (pbk)**, **shortId (sid)**,
**uuid**, **sni**, **flow** — пойдут в ссылку.

## 3. Клиентская vless://-ссылка

3X-UI отдаст готовую ссылку/QR, но в ней `address` = IP exit-узла. Если вход идёт через региональный
релей, в ссылке `address` меняем на адрес релея (порт `443` оставляем):

```
vless://<uuid>@<АДРЕС_РЕЛЕЯ>:443?type=tcp&security=reality&flow=xtls-rprx-vision&sni=yastatic.net&fp=chrome&pbk=<pbk>&sid=<sid>&spx=%2F#my-node
```

REALITY-аутентификация — внутри содержимого хэндшейка (по pbk/sid/sni), а не по IP, поэтому
коннект на релей с последующим туннелированием на exit-узел валиден.

Клиенты на телефон: iOS — Happ / Streisand; Android — v2rayNG / husi.

## 4. Стыковка релея и exit-узла — DNAT в контейнере

Полный путь:
```
клиент →(REALITY, SNI=камуфляж)→ <АДРЕС_РЕЛЕЯ>:443
        →(релей: DNAT → шифрованный туннель)→ exit-узел wg0 10.8.0.1:443
        →(DNAT в контейнере amnezia)→ 172.17.0.1:8443 (REALITY 3x-ui) → терминируется
```

`amnezia-wg-easy` держит `wg0` (10.8.0.1) внутри своего netns, поэтому REALITY (контейнер 3x-ui)
напрямую недостижим. Решение без host-net и без рестарта контейнера: 3x-ui публикует REALITY на
`172.17.0.1:8443` (docker0-gateway хоста), а внутри контейнера amnezia туннельный `:443` DNAT-им
туда. **Команды (на exit-узле, обратимо):**

```bash
# поставить стык (PREROUTING DNAT + MASQUERADE) внутри netns контейнера amnezia
docker exec amnezia-wg-easy iptables -t nat -A PREROUTING -i wg0 -p tcp --dport 443 \
  -j DNAT --to-destination 172.17.0.1:8443
docker exec amnezia-wg-easy iptables -t nat -A POSTROUTING -d 172.17.0.1 -p tcp \
  --dport 8443 -j MASQUERADE

# проверить
docker exec amnezia-wg-easy iptables -t nat -S | grep -E '443|8443'

# ОТКАТ (если что-то не так — снять оба правила, -D вместо -A):
docker exec amnezia-wg-easy iptables -t nat -D PREROUTING -i wg0 -p tcp --dport 443 \
  -j DNAT --to-destination 172.17.0.1:8443
docker exec amnezia-wg-easy iptables -t nat -D POSTROUTING -d 172.17.0.1 -p tcp \
  --dport 8443 -j MASQUERADE
```

> Правила в контейнере **не персистят** через пересоздание контейнера amnezia (но переживают
> его рестарт). Существующий рабочий туннель они не трогают — только добавляют DNAT для :443.
> Если сквозной путь висит/рвётся — первый кандидат на фикс: MSS-клэмп на релее
> (`iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`).
