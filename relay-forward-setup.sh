#!/usr/bin/env bash
#
# relay-forward-setup.sh  (выполняется НА Яндекс-релее, sudo)
# Тонкий релей: автозапуск AWG-туннеля до NL + проброс входящего :443 внутрь
# туннеля на REALITY-листенер NL (10.8.0.1:443). Идемпотентно, переживает ребут.
#
# Предусловие: туннель awg0 (AmneziaWG до NL) уже сконфигурен в
# /etc/amnezia/amneziawg/awg0.conf.
#
set -euo pipefail

NL_TUN_IP="10.8.0.1"   # туннельный IP NL (wg-easy сервер), куда уходит :443
PORT=443
WAN="eth0"             # внешний интерфейс ВМ (за NAT Яндекса)
TUN="awg0"

# 1. туннель поднимается на старте
systemctl enable awg-quick@${TUN} >/dev/null 2>&1 || true

# 2. DNAT :443 → NL-REALITY через туннель + MASQUERADE (обратный путь через релей)
iptables -t nat -C PREROUTING -i "$WAN" -p tcp --dport "$PORT" -j DNAT --to-destination "${NL_TUN_IP}:${PORT}" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$WAN" -p tcp --dport "$PORT" -j DNAT --to-destination "${NL_TUN_IP}:${PORT}"
iptables -t nat -C POSTROUTING -d "$NL_TUN_IP" -o "$TUN" -p tcp --dport "$PORT" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -d "$NL_TUN_IP" -o "$TUN" -p tcp --dport "$PORT" -j MASQUERADE

# 3. FORWARD (на случай не-ACCEPT политики)
iptables -C FORWARD -i "$WAN" -o "$TUN" -p tcp --dport "$PORT" -d "$NL_TUN_IP" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$WAN" -o "$TUN" -p tcp --dport "$PORT" -d "$NL_TUN_IP" -j ACCEPT
iptables -C FORWARD -i "$TUN" -o "$WAN" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$TUN" -o "$WAN" -m state --state ESTABLISHED,RELATED -j ACCEPT

# 4. персист правил (без интерактивного промпта)
echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
mkdir -p /etc/iptables
( netfilter-persistent save >/dev/null 2>&1 ) || iptables-save > /etc/iptables/rules.v4

echo "=== nat PREROUTING/POSTROUTING ==="
iptables -t nat -S | grep -E "443|MASQUERADE" || true
echo "=== awg-quick@${TUN} enabled? ==="
systemctl is-enabled awg-quick@${TUN} 2>/dev/null || true
