# Региональный релей (Yandex Cloud) → exit-узел

Тонкий релей в Yandex Cloud: принимает VLESS+REALITY на `:443` и туннелирует трафик внутрь
AmneziaWG-туннеля до твоего exit-узла, где REALITY терминируется. Релей **ничего не расшифровывает** —
только L4-форвард в туннель.

```
клиент →(REALITY, SNI=камуфляж)→ релей:443 (региональный вход)
        →(шифрованный туннель)→ exit-узел: REALITY терминируется → свои ресурсы
```

Зачем региональный релей: точка входа ближе к клиентам (меньше латентность), единый региональный
адрес для своих сервисов, устойчивость канала к exit-узлу.

> Назначение — доступ к **своей** инфраструктуре. Используйте в рамках применимого законодательства;
> учтите, что узел в РФ привязан к личности владельца (телефон→паспорт).

## 0. Предусловия
- Свой exit-VPS с рабочим `amnezia-wg-easy` (см. `deploy-awg-portal.sh`).
- Аккаунт Yandex Cloud.

## 1. Создать ВМ

Через консоль или `yc` CLI:
- Сеть: можно переиспользовать авто-`default`.
- **Security group** (`relay-sg`): ingress `443/tcp ← 0.0.0.0/0`, `22/tcp ← <твой_IP>/32`; egress — всё.
- Зарезервировать статический публичный IP в нужной зоне.
- ВМ: Ubuntu 22.04/24.04 LTS, 2 vCPU (доля 20%), 1 ГБ RAM, HDD 10 ГБ (релею хватает),
  НЕ прерываемая (preemptible гасится раз в сутки), статический публичный адрес, SG = `relay-sg`,
  SSH-ключ (отдельный, одноразовый).

## 2. Установить AmneziaWG (kernel-модуль)
```bash
sudo apt install -y software-properties-common python3-launchpadlib gnupg2 linux-headers-$(uname -r)
sudo add-apt-repository -y ppa:amnezia/ppa
sudo apt-get update
sudo apt-get install -y amneziawg          # ставит DKMS-модуль + awg/awg-quick
sudo modprobe amneziawg && lsmod | grep amneziawg   # проверка
```
> PPA — именно `amnezia/ppa` (не `amnezia/amneziawg`). Заголовки ядра нужны для сборки DKMS.

## 3. Поднять туннель до exit-узла
1. В панели wg-easy (exit-узел) создай клиента → скачай `.conf`.
2. Положи на релей в `/etc/amnezia/amneziawg/awg0.conf` с правками (см. `Yandex-Cloud.conf.example`):
   `AllowedIPs` → только туннельная подсеть exit-узла (напр. `10.8.0.0/24`), `PersistentKeepalive = 25`,
   строку `DNS` убрать.
3. Включить форвардинг и поднять:
```bash
echo net.ipv4.ip_forward=1 | sudo tee /etc/sysctl.d/99-relay.conf && sudo sysctl -w net.ipv4.ip_forward=1
sudo awg-quick up awg0
ping -c3 10.8.0.1                     # туннельный IP exit-узла
sudo awg show awg0                    # latest handshake + rx>0 = успех
```
> **AllowedIPs ограничиваем нарочно:** при `0.0.0.0/0` awg-quick перехватит дефолтный маршрут и
> оборвёт обратный путь SSH. Релею нужен только маршрут до туннельной подсети exit-узла.

## 4. Проброс :443 в туннель + персист
`relay-forward-setup.sh` (в этом репо): DNAT `eth0:443 → 10.8.0.1:443` + MASQUERADE, FORWARD,
автозапуск `awg-quick@awg0`, персист правил.
```bash
sudo bash relay-forward-setup.sh
```
Сторона exit-узла (REALITY-inbound + стыковочный DNAT в контейнере amnezia) — см. `REALITY-SETUP.md`.

## 5. Хардening (после сквозного теста)
Релей держит только WG-ключ узла + адрес exit-узла + правило проброса (не REALITY-ключи, не назначения).
Минимизируем след: логи в volatile/tmpfs, off core-dumps/kdump, swap off, узел одноразовый —
периодически пересоздавать и ротировать ключи.

## Ограничения
REALITY и туннель не помогают, если нижележащий канал физически недоступен или сильно урезан по
полосе — трафик идёт по той же трубе.
