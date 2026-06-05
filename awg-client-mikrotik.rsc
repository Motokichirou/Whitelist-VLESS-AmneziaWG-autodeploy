# =====================================================================
#  AWG-proxy client для MikroTik (RouterOS 7.x)
#  Разворачивает клиента AmneziaWG: контейнер awg-proxy + WireGuard-интерфейс
#  + masquerade + mangle + selective-routing (rkn) под обход по list-antifilter.
#
#  ЧТО СДЕЛАТЬ:
#    1) Вставь в блок ниже (CONFIG) скачанный с панели wg-easy .conf клиента.
#       Это ЕДИНСТВЕННОЕ, что нужно вставить — остальное скрипт делает сам.
#    2) (опц.) Проверь tunables (имя образа контейнера, каталог).
#    3) Залей файл на роутер и выполни:  /import file=awg-client-mikrotik.rsc
#       (или просто вставь весь текст в терминал Winbox/SSH).
#  Скрипт rkn-unblock (наполнение list-antifilter) уже ВСТРОЕН ниже.
#
#  ПРЕДУСЛОВИЯ (делается один раз заранее, скриптом НЕ автоматизируется):
#    • Контейнеры включены:  /system device-mode update container=yes  (требует
#      подтверждения кнопкой/перезагрузки).
#    • Образ awg-proxy загружен в корень роутера (Files), имя — в tunable imageFile
#      (для ARM RB4011 это awg-proxy-arm.tar.gz).
#    • Есть бридж в interface-list LAN (defconf) и WAN на ether1.
# =====================================================================

# ====================== ВСТАВЬ СЮДА (1): КОНФИГ С СЕРВЕРА =============
# Замени строку-заглушку на содержимое .conf, скачанного из панели wg-easy.
:local conf "
ВСТАВЬ_СЮДА_СОДЕРЖИМОЕ_CONF_ФАЙЛА
"
# =====================================================================

# ----------------------------- tunables -----------------------------
:local imageFile  "awg-proxy-arm.tar.gz";   # имя образа в Files
:local rootDir    "awg-proxy";               # каталог под rootfs контейнера
:local vethRouter "172.18.0.1";              # IP роутера на veth (служебный /30)
:local vethCont   "172.18.0.2";              # IP контейнера на veth (= endpoint пира)
:local wgListen   12429;                     # listen-port локального WG-интерфейса
:local wgMtu      1420;
# --------------------------------------------------------------------

# ------------------ парсер значений из .conf ------------------------
:local awgVal do={
    :local src ("\n" . [:tostr $1]);
    :local key [:tostr $2];
    :local a ("\n" . $key);
    :local p [:find $src $a 0];
    :if ([:typeof $p] != "num") do={ :return "" };
    :local eq [:find $src "=" $p];
    :if ([:typeof $eq] != "num") do={ :return "" };
    :local nl [:find $src "\n" $eq];
    :local v "";
    :if ([:typeof $nl] = "num") do={ :set v [:pick $src ($eq + 1) $nl] } else={ :set v [:pick $src ($eq + 1) [:len $src]] };
    :while (([:len $v] > 0) and (([:pick $v 0 1] = " ") or ([:pick $v 0 1] = "\t"))) do={ :set v [:pick $v 1 [:len $v]] };
    :while (([:len $v] > 0) and (([:pick $v ([:len $v] - 1) [:len $v]] = " ") or ([:pick $v ([:len $v] - 1) [:len $v]] = "\t") or ([:pick $v ([:len $v] - 1) [:len $v]] = "\r"))) do={ :set v [:pick $v 0 ([:len $v] - 1)] };
    :return $v;
}

:local privKey   [$awgVal $conf "PrivateKey"];
:local address   [$awgVal $conf "Address"];
:local serverPub [$awgVal $conf "PublicKey"];
:local endpoint  [$awgVal $conf "Endpoint"];
:local psk       [$awgVal $conf "PresharedKey"];
:local jc        [$awgVal $conf "Jc"];
:local jmin      [$awgVal $conf "Jmin"];
:local jmax      [$awgVal $conf "Jmax"];
:local s1        [$awgVal $conf "S1"];
:local s2        [$awgVal $conf "S2"];
:local h1        [$awgVal $conf "H1"];
:local h2        [$awgVal $conf "H2"];
:local h3        [$awgVal $conf "H3"];
:local h4        [$awgVal $conf "H4"];

# ------------------------- валидация --------------------------------
:if (([:len $privKey] = 0) or ([:len $address] = 0) or ([:len $serverPub] = 0) or ([:len $endpoint] = 0)) do={
    :error "Не разобран .conf: нужны PrivateKey / Address / PublicKey / Endpoint. Проверь, что вставлен полный конфиг.";
}
:if (([:len $jc] = 0) or ([:len $s1] = 0) or ([:len $s2] = 0) or ([:len $h1] = 0) or ([:len $h2] = 0) or ([:len $h3] = 0) or ([:len $h4] = 0)) do={
    :error "В конфиге нет параметров AmneziaWG (Jc/S1/S2/H1..H4). Похоже на обычный WireGuard, а не AmneziaWG.";
}
:put ("[*] Конфиг разобран. Туннельный IP: " . $address . ", сервер: " . $endpoint);

# --------------------- очистка прошлого прогона ---------------------
:put "[*] Чищу прежние объекты awg-proxy (если были)…";
:do { /container stop [find where name=awg-proxy] } on-error={}
:delay 2s;
:do { /container remove [find where name=awg-proxy] } on-error={}
:do { /container envs remove [find where name=awg-proxy-env] } on-error={}
:do { /interface wireguard peers remove [find where interface=wg-awg-proxy] } on-error={}
:do { /ip address remove [find where interface=wg-awg-proxy] } on-error={}
:do { /ip address remove [find where interface=veth-awg-proxy] } on-error={}
:do { /interface wireguard remove [find where name=wg-awg-proxy] } on-error={}
:do { /interface veth remove [find where name=veth-awg-proxy] } on-error={}
:do { /ip firewall nat remove [find where comment="awg-proxy"] } on-error={}
:do { /ip firewall mangle remove [find where comment="awg-proxy rkn"] } on-error={}
:do { /ip route remove [find where comment="awg-proxy"] } on-error={}
:do { /system scheduler remove [find where name=rkn-unblock] } on-error={}
:do { /system script remove [find where name=rkn-unblock] } on-error={}

# --------------------- 1. таблица маршрутизации rkn -----------------
:if ([:len [/routing table find where name=rkn]] = 0) do={
    /routing table add fib name=rkn;
}

# --------------------- 2. veth-пара под контейнер -------------------
/interface veth add name=veth-awg-proxy address=($vethCont . "/30") gateway=$vethRouter;
/ip address add interface=veth-awg-proxy address=($vethRouter . "/30");

# --------------------- 3. WireGuard-интерфейс + туннельный IP --------
# ВАЖНО: на wg-awg-proxy вешаем именно туннельный Address из .conf (10.8.0.x/..),
# а НЕ адрес veth — иначе endpoint пира совпадает с собственным IP интерфейса
# и рукопожатие уходит "в себя" (tx>0, rx=0).
/interface wireguard add name=wg-awg-proxy listen-port=$wgListen mtu=$wgMtu private-key=$privKey;
/ip address add interface=wg-awg-proxy address=$address;

# публичный ключ клиента RouterOS вычисляет сам — забираем для контейнера
:local clientPub [/interface wireguard get [find where name=wg-awg-proxy] public-key];

# --------------------- 4. пир → локальный контейнер -----------------
/interface wireguard peers add interface=wg-awg-proxy public-key=$serverPub \
    endpoint-address=$vethCont endpoint-port=51820 allowed-address=0.0.0.0/0 \
    persistent-keepalive=25s;
:if ([:len $psk] > 0) do={
    /interface wireguard peers set [find where interface=wg-awg-proxy] preshared-key=$psk;
}

# --------------------- 5. env-лист для контейнера -------------------
/container envs add name=awg-proxy-env key=AWG_CLIENT_PUB value=$clientPub;
/container envs add name=awg-proxy-env key=AWG_SERVER_PUB value=$serverPub;
/container envs add name=awg-proxy-env key=AWG_REMOTE     value=$endpoint;
/container envs add name=awg-proxy-env key=AWG_LISTEN     value=":51820";
/container envs add name=awg-proxy-env key=AWG_JC   value=$jc;
/container envs add name=awg-proxy-env key=AWG_JMIN value=$jmin;
/container envs add name=awg-proxy-env key=AWG_JMAX value=$jmax;
/container envs add name=awg-proxy-env key=AWG_S1   value=$s1;
/container envs add name=awg-proxy-env key=AWG_S2   value=$s2;
/container envs add name=awg-proxy-env key=AWG_H1   value=$h1;
/container envs add name=awg-proxy-env key=AWG_H2   value=$h2;
/container envs add name=awg-proxy-env key=AWG_H3   value=$h3;
/container envs add name=awg-proxy-env key=AWG_H4   value=$h4;

# --------------------- 6. контейнер awg-proxy -----------------------
/container add name=awg-proxy interface=veth-awg-proxy envlists=awg-proxy-env \
    root-dir=$rootDir file=$imageFile hostname=awg-proxy start-on-boot=yes logging=yes;

# --------------------- 7. NAT: маскарад в туннель -------------------
/ip firewall nat add chain=srcnat action=masquerade out-interface=wg-awg-proxy comment="awg-proxy";

# --------------------- 8. mangle: LAN → заблокированные в rkn --------
# Только трафик из LAN (бридж), идущий на адреса из list-antifilter, помечается
# меткой rkn. Контейнер заходит через veth (не в LAN) — его трафик к серверу
# не маркируется, петли нет.
/ip firewall mangle add chain=prerouting action=mark-routing new-routing-mark=rkn \
    dst-address-list=list-antifilter in-interface-list=LAN passthrough=no comment="awg-proxy rkn";

# --------------------- 9. дефолт в таблице rkn через туннель ---------
/ip route add dst-address=0.0.0.0/0 gateway=wg-awg-proxy routing-table=rkn comment="awg-proxy";

# =====================================================================
#  ANTIFILTER — скрипт rkn-unblock наполняет address-list list-antifilter
#  (чанковый фетч https://antifilter.download/list/allyouneed.lst). Встроен
#  ниже одной строкой source="..." (экранирован) + планировщик раз в сутки.
# ---------------------------------------------------------------------
/system script add name=rkn-unblock policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source=":do {\n    :local retryflag true;\n    :local maxretry 3;\n    :local delay 120s;\n    :local url \"https://antifilter.download/list/allyouneed.lst\";\n    :local listname \"list-antifilter\";\n    :for retry from=1 to=\$maxretry step=1 do={\n        :if (retryflag) do={\n            :set \$retryflag false;\n            :set \$counter 0;\n            :if (retry > 1) do={\n                :delay \$delay;\n            };\n            :do {\n                /ip firewall address-list remove [find where list=(\$listname.\"-updated\")];\n            } on-error={};\n            :do {\n                /ip firewall address-list add list=(\$listname.\"-updated\") address=antifilter.download comment=\"antifilter.download\";\n            } on-error={};\n            :local filesize ([/tool fetch url=\$url keep-result=no as-value]->\"total\");\n            :local chunksize 64000;\n            :local start 0;\n            :local end (\$chunksize - 1);\n            :local chunks (\$filesize / (\$chunksize / 1024));\n            :local lastchunk (\$filesize % (\$chunksize / 1024));\n            :if (\$lastchunk > 0) do={\n                :set \$chunks (\$chunks + 1);\n            };\n            :for chunk from=1 to=\$chunks step=1 do={\n                :local comparesize ([/tool fetch url=\$url keep-result=no as-value]->\"total\");\n                :if (\$comparesize = \$filesize) do={\n                    :set \$data ([:tool fetch url=\$url http-header-field=\"Range: bytes=\$start-\$end\" output=user as-value]->\"data\");\n                } else={\n                    :set \$data [:toarray \"\"];\n                    :set \$retryflag true;\n                };\n                :local regexp \"^((25[0-5]|(2[0-4]|[01]?[0-9]?)[0-9])\\\\.){3}(25[0-5]|(2[0-4]|[01]?[0-9]?)[0-9])(\\\\/(3[0-2]|[0-2]?[0-9])){0,1}\\\$\";\n                :if (\$start > 0) do={\n                    :set \$data [:pick \$data ([:find \$data \"\\n\"]+1) [:len \$data]];\n                };\n                \n                :while ([:len \$data]!=0) do={\n                    :local line [:pick \$data 0 [:find \$data \"\\n\"]];\n                    :if ( \$line ~ \$regexp ) do={    \n                        :do {\n                            /ip firewall address-list add list=(\$listname.\"-updated\") address=\$line;\n                            :set \$counter (\$counter + 1);\n                        } on-error={};        \n                    };\n                    :set \$data [:pick \$data ([:find \$data \"\\n\"]+1) [:len \$data]];\n                    :if ([:len \$data] < 256) do={\n                        :set \$data [:toarray \"\"];\n                    };\n                };\n                :set \$start ((\$start-512) + \$chunksize); \n                :set \$end ((\$end-512) + \$chunksize); \n            \n            };\n        \n        };\n    };\n    :if (\$counter > 0) do={\n        :do {\n            /ip firewall address-list remove [find where list=\$listname];\n        } on-error={};\n        :do {\n            :foreach address in=[/ip firewall address-list find list=(\$listname.\"-updated\")] do={\n                :do {\n                    /ip firewall address-list set list=\$listname \$address;\n                } on-error={};\n            };\n        } on-error={};\n    };\n} on-error={};"

/system scheduler add name=rkn-unblock interval=1d \
    on-event="/system script run rkn-unblock" \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    comment="awg-proxy: обновление list-antifilter";

# первичное наполнение списка (может занять пару минут)
:do {
    /system script run rkn-unblock;
    :put "[*] rkn-unblock запущен — наполняю list-antifilter.";
} on-error={
    :put "[!] Не удалось запустить rkn-unblock.";
}
# =====================================================================

# --------------------- 10. старт контейнера -------------------------
:delay 2s;
:do {
    /container start [find where name=awg-proxy];
} on-error={
    :put "[!] Контейнер не стартовал. Проверь: включён ли container mode и лежит ли образ в Files.";
}

# --------------------- 11. итог -------------------------------------
:delay 3s;
:put "──────────────────────────────────────────────";
:put "[+] AWG-proxy развёрнут.";
:put ("    wg-awg-proxy IP : " . $address);
:put ("    AWG_REMOTE      : " . $endpoint);
:put ("    client pubkey   : " . $clientPub);
:put "Проверь через ~10–30 c (должны быть handshake и rx > 0):";
:put "    /interface wireguard peers print where interface=wg-awg-proxy";
:put "    /container print where name=awg-proxy";
:put "    /ip firewall address-list print count-only where list=list-antifilter";
