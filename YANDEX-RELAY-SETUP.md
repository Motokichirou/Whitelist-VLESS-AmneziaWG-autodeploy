# Яндекс-релей: RU-вход с белым IP (обход IP+SNI вайтлиста)

Тонкий релей в Yandex Cloud: принимает VLESS+REALITY на `:443`, прокидывает трафик внутрь
AmneziaWG-туннеля до зарубежного exit-VPS (NL), где REALITY терминируется. Релей **ничего не
расшифровывает** — только L4-форвард в туннель.

```
телефон →(REALITY, SNI=белый)→ Яндекс:443 (белый RU-IP)
        →(DNAT → AWG-туннель)→ NL: REALITY терминируется + egress → интернет
```

Зачем именно Яндекс: при режиме **IP+SNI** оператор пускает только забелённые подсети.
Публичные пулы Yandex Cloud (`51.250.x`, `158.160.x`, `84.201.x`, `178.154.x`, `89.169.x`)
массово присутствуют в community-вайтлистах — значит ВМ может получить белый IP.

## 0. Предусловия
- Зарубежный exit-VPS (NL) с рабочим `amnezia-wg-easy` (см. `deploy-awg-portal.sh`).
- Аккаунт Yandex Cloud. **Важно:** RU-узел завязан на личность (телефон→паспорт) — принять как данность.

## 1. Создать ВМ с БЕЛЫМ IP

Через консоль или `yc` CLI:
- Сеть: можно переиспользовать авто-`default`.
- **Security group** (`relay-sg`): ingress `443/tcp ← 0.0.0.0/0`, `22/tcp ← <твой_IP>/32`; egress — всё.
- **Зарезервировать статический публичный IP** в нужной зоне.
- **СВЕРИТЬ IP на «белизну»** до создания ВМ (членство в CIDR из community-вайтлиста, напр.
  `hxehex/russia-mobile-internet-whitelist` → `cidrwhitelist.txt`/`ipwhitelist.txt`). Не белый →
  удалить адрес и зарезервировать заново.
- ВМ: Ubuntu 22.04/24.04 LTS, 2 vCPU (доля 20%), 1 ГБ RAM, HDD 10 ГБ (релею хватает),
  НЕ прерываемая (preemptible гасится раз в сутки), публичный адрес = забелённый,
  SG = `relay-sg`, SSH-ключ (отдельный, одноразовый).

Проверка членства IP (локально, нужен python3):
```bash
python3 - "$IP" <<'PY'
import sys, ipaddress, urllib.request
ip=ipaddress.ip_address(sys.argv[1])
cidr=urllib.request.urlopen("https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/cidrwhitelist.txt").read().decode().split()
hits=[c for c in cidr if ip in ipaddress.ip_network(c,strict=False)]
print("WHITE:", hits or "НЕТ — пересоздай IP")
PY
```

## 2. Установить AmneziaWG (kernel-модуль)
```bash
sudo apt install -y software-properties-common python3-launchpadlib gnupg2 linux-headers-$(uname -r)
sudo add-apt-repository -y ppa:amnezia/ppa
sudo apt-get update
sudo apt-get install -y amneziawg          # ставит DKMS-модуль + awg/awg-quick
sudo modprobe amneziawg && lsmod | grep amneziawg   # проверка
```
> PPA — именно `amnezia/ppa` (не `amnezia/amneziawg`). Заголовки ядра нужны для сборки DKMS.

## 3. Поднять туннель до NL
1. В панели wg-easy (NL) создай клиента → скачай `.conf`.
2. Положи на релей в `/etc/amnezia/amneziawg/awg0.conf` с правками (см. `Yandex-Cloud.conf.example`):
   `AllowedIPs` → только туннельная подсеть NL (напр. `10.8.0.0/24`), `PersistentKeepalive = 25`,
   строку `DNS` убрать.
3. Включить форвардинг и поднять:
```bash
echo net.ipv4.ip_forward=1 | sudo tee /etc/sysctl.d/99-relay.conf && sudo sysctl -w net.ipv4.ip_forward=1
sudo awg-quick up awg0
ping -c3 10.8.0.1                     # туннельный IP сервера NL
sudo awg show awg0                    # latest handshake + rx>0 = успех
```
> **AllowedIPs ограничиваем нарочно:** при `0.0.0.0/0` awg-quick перехватит дефолтный маршрут и
> оборвёт обратный путь SSH. Релею нужен только маршрут до туннельной подсети NL.

## 4. Проброс :443 в туннель + персист
`relay-forward-setup.sh` (в этом репо): DNAT `eth0:443 → 10.8.0.1:443` + MASQUERADE, FORWARD,
автозапуск `awg-quick@awg0`, персист правил.
```bash
sudo bash relay-forward-setup.sh
```
NL-сторона (REALITY-inbound + стыковочный DNAT в контейнере amnezia) — см. `REALITY-SETUP.md`.

## 5. Хардening (после сквозного теста)
Релей держит только WG-ключ узла + IP NL + правило проброса (не REALITY-ключи, не назначения).
Минимизируем след: логи в volatile/tmpfs, off core-dumps/kdump, swap off, узел одноразовый —
периодически пересоздавать и ротировать ключи.

## Потолок (честно)
REALITY+белый SNI решает **вайтлист**, но не физическое отключение: при полном блэкауте или
троттлинге туннель едет по той же дохлой трубе. Это не лечится ничем на стороне клиента.
