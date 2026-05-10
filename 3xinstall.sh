#!/bin/bash

INSTALL_WARP=false
EXTENDED_SETUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --warp)
            INSTALL_WARP=true
            shift
            ;;
        --extend)
            EXTENDED_SETUP=true
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&3
            exit 1
            ;;
    esac
done

# Проверяем наличие команды x-ui
if command -v x-ui &> /dev/null; then
    echo "Обнаружена установленная панель x-ui."

    read -p "Вы хотите переустановить x-ui? [y/N]: " confirm
    confirm=${confirm,,}

    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Отмена. Скрипт завершает работу."
        exit 1
    fi

    echo "Удаление x-ui..."
    /usr/local/x-ui/x-ui uninstall -y &>/dev/null || true
    rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
    systemctl daemon-reexec
    systemctl daemon-reload
    rm /root/3x-ui.txt
    echo "x-ui успешно удалена. Продолжаем выполнение скрипта..."
fi

exec 3>&1
LOG_FILE="/var/log/3x-ui_install_log.txt"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

if [[ "$EXTENDED_SETUP" == true ]]; then
    read -rp $'\033[0;33mВведите порт для панели (Enter для 8080): \033[0m' USER_PORT
    PORT=${USER_PORT:-8080}

    echo -e "\n${yellow}Хотите установить SelfSNI (поддельный сайт для маскировки)?${plain}"
    read -rp $'\033[0;36mВведите y для установки или нажмите Enter для пропуска: \033[0m' INSTALL_SELFSNI
    if [[ "$INSTALL_SELFSNI" == "y" || "$INSTALL_SELFSNI" == "Y" ]]; then
        echo -e "${green}Устанавливается SelfSNI...${plain}" >&3
        bash <(curl -Ls https://raw.githubusercontent.com/YukiKras/vless-scripts/refs/heads/main/fakesite.sh)
    else
        echo -e "${yellow}Установка SelfSNI пропущена.${plain}" >&3
    fi
else
    PORT=8080
    echo -e "${yellow}Порт панели не указан, используется по умолчанию: ${PORT}${plain}" >&3
fi

echo -e "Весь процесс установки будет сохранён в файле: \033[0;36m${LOG_FILE}\033[0m" >&3
echo -e "\n\033[1;34mИдёт установка... Пожалуйста, не закрывайте терминал.\033[0m"

gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}
USERNAME=$(gen_random_string 10)
PASSWORD=$(gen_random_string 10)
WEBPATH=$(gen_random_string 18)

# Рандомное название инбаунда (10 символов, строчные буквы + цифры)
INBOUND_REMARK=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | fold -w 10 | head -n 1)

# Рандомный порт инбаунда из двух вариантов: 8443 или 4443
INBOUND_PORTS=(8443 4443)
INBOUND_PORT=${INBOUND_PORTS[$RANDOM % ${#INBOUND_PORTS[@]}]}

# SNI и DEST фиксированы
BEST_DOMAIN="ozon.ru"

echo -e "${green}Название инбаунда: ${INBOUND_REMARK}${plain}" >&3
echo -e "${green}Порт инбаунда: ${INBOUND_PORT}${plain}" >&3
echo -e "${green}SNI / DEST: ${BEST_DOMAIN}${plain}" >&3

if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Ошибка:${plain} скрипт нужно запускать от root" >&3
    exit 1
fi

# === Оптимизация сети: BBR + TCP буферы ===
echo -e "${yellow}Настройка TCP BBR и сетевых буферов...${plain}" >&3

# Включаем BBR если ядро поддерживает (>= 4.9)
KERNEL_VERSION=$(uname -r | cut -d. -f1-2 | tr -d '.')
if [[ "$KERNEL_VERSION" -ge 49 ]]; then
    modprobe tcp_bbr 2>/dev/null || true

    SYSCTL_CONF="/etc/sysctl.d/99-bbr-optimize.conf"
    cat > "$SYSCTL_CONF" <<'EOF'
# TCP BBR — алгоритм контроля перегрузки
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Увеличенные буферы TCP для высокой пропускной способности
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728

# Оптимизация очередей и таймаутов
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
EOF

    sysctl -p "$SYSCTL_CONF" >>"$LOG_FILE" 2>&1

    # Проверяем что BBR применился
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$CURRENT_CC" == "bbr" ]]; then
        echo -e "${green}TCP BBR успешно включён.${plain}" >&3
    else
        echo -e "${yellow}BBR не применился (текущий алгоритм: ${CURRENT_CC}). Продолжаем без него.${plain}" >&3
    fi
else
    echo -e "${yellow}Ядро ${KERNEL_VERSION} не поддерживает BBR (нужно >= 4.9). Пропускаем.${plain}" >&3
fi

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
else
    echo "Не удалось определить ОС" >&3
    exit 1
fi

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | arm64 | aarch64) echo 'arm64' ;;
        armv7* | arm) echo 'armv7' ;;
        armv6*) echo 'armv6' ;;
        armv5*) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo "unknown" ;;
    esac
}
ARCH=$(arch)

case "${release}" in
    ubuntu | debian | armbian)
        apt-get update > /dev/null 2>&1
        apt-get install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    centos | rhel | almalinux | rocky | ol)
        yum -y update > /dev/null 2>&1
        yum install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    fedora | amzn | virtuozzo)
        dnf -y update > /dev/null 2>&1
        dnf install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm > /dev/null 2>&1
        pacman -S --noconfirm wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    opensuse-tumbleweed)
        zypper refresh > /dev/null 2>&1
        zypper install -y wget curl tar timezone jq xxd qrencode > /dev/null 2>&1
        ;;
    *)
        apt-get update > /dev/null 2>&1
        apt-get install -y wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
esac

cd /usr/local/ || exit 1
URL1="https://github.com/MHSanaei/3x-ui/releases/download/v2.6.7/x-ui-linux-amd64.tar.gz"
URL2="https://files.yukikras.net/3x-ui/v2.6.7.x-ui-linux-amd64.tar.gz"
FILE="x-ui-linux-${ARCH}.tar.gz"

if ! wget -q -O "$FILE" "$URL1"; then
    echo "Не удалось скачать с GitHub, пробую зеркало..."
    wget -q -O "$FILE" "$URL2" || {
        echo "Ошибка: не удалось скачать файл ни с одного источника"
        exit 1
    }
fi

systemctl stop x-ui 2>/dev/null
rm -rf /usr/local/x-ui/
tar -xzf x-ui-linux-${ARCH}.tar.gz
rm -f x-ui-linux-${ARCH}.tar.gz

cd x-ui || exit 1
chmod +x x-ui
[[ "$ARCH" == armv* ]] && mv bin/xray-linux-${ARCH} bin/xray-linux-arm && chmod +x bin/xray-linux-arm
chmod +x x-ui bin/xray-linux-${ARCH}
cp -f x-ui.service /etc/systemd/system/

URL1="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh"
URL2="https://files.yukikras.net/3x-ui/x-ui.sh"
FILE="/usr/bin/x-ui"

if ! wget -q -O "$FILE" "$URL1"; then
    echo "Не удалось скачать с GitHub, пробую зеркало..."
    wget -q -O "$FILE" "$URL2" || {
        echo "Ошибка: не удалось скачать файл ни с одного источника"
        exit 1
    }
fi
chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui

/usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$WEBPATH" >>"$LOG_FILE" 2>&1
/usr/local/x-ui/x-ui migrate >>"$LOG_FILE" 2>&1

systemctl daemon-reload >>"$LOG_FILE" 2>&1
systemctl enable x-ui >>"$LOG_FILE" 2>&1
systemctl start x-ui >>"$LOG_FILE" 2>&1

# Генерация Reality ключей
KEYS=$(/usr/local/x-ui/bin/xray-linux-${ARCH} x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | sed -E 's/.*Key:\s*//')
PUBLIC_KEY=$(echo "$KEYS" | grep -i "Password" | sed -E 's/.*Password:\s*//')
SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)
UUID=$(cat /proc/sys/kernel/random/uuid)
EMAIL=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)

# Авторизация в API
COOKIE_JAR=$(mktemp)

LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${USERNAME}\", \"password\": \"${PASSWORD}\"}")

if ! echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    echo -e "${red}Ошибка авторизации через cookie.${plain}" >&3
    echo "$LOGIN_RESPONSE" >&3
    exit 1
fi

SETTINGS_JSON=$(jq -nc --arg uuid "$UUID" --arg email "$EMAIL" '{
  clients: [
    {
      id: $uuid,
      flow: "xtls-rprx-vision",
      email: $email,
      enable: true
    }
  ],
  decryption: "none"
}')

STREAM_SETTINGS_JSON=$(jq -nc \
  --arg pbk "$PUBLIC_KEY" \
  --arg prk "$PRIVATE_KEY" \
  --arg sid "$SHORT_ID" \
  --arg dest "${BEST_DOMAIN}:443" \
  --arg sni "$BEST_DOMAIN" '{
  network: "tcp",
  security: "reality",
  realitySettings: {
    show: false,
    dest: $dest,
    xver: 0,
    serverNames: [$sni],
    privateKey: $prk,
    settings: {publicKey: $pbk},
    shortIds: [$sid]
  }
}')

SNIFFING_JSON=$(jq -nc '{
  enabled: true,
  destOverride: ["http", "tls"]
}')

ADD_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --argjson settings "$SETTINGS_JSON" \
    --argjson stream "$STREAM_SETTINGS_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    --arg remark "$INBOUND_REMARK" \
    --argjson port "$INBOUND_PORT" \
    '{
      enable: true,
      remark: $remark,
      listen: "",
      port: $port,
      protocol: "vless",
      settings: ($settings | tostring),
      streamSettings: ($stream | tostring),
      sniffing: ($sniffing | tostring)
    }')"
)

if echo "$ADD_RESULT" | grep -q '"success":true'; then
    echo -e "${green}Инбаунд успешно добавлен через API.${plain}" >&3

    systemctl restart x-ui >>"$LOG_FILE" 2>&1

    if [[ "$INSTALL_WARP" == true ]]; then
        echo -e "${yellow}Установка WARP...${plain}" >&3
        wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo -e "${green}Скрипт WARP загружен, начинаем установку...${plain}" >&3
            echo -e "1\n" | bash /tmp/warp_menu.sh c >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                echo -e "${green}WARP успешно установлен${plain}" >&3
                echo -e "${yellow}Настройка WARP в 3x-ui панели...${plain}" >&3

                XRAY_CONFIG=$(jq -nc --arg inbound_tag "inbound-${INBOUND_PORT}" '{
  "log": {"access": "none", "dnsLog": false, "error": "", "loglevel": "warning", "maskAddress": ""},
  "api": {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]},
  "inbounds": [{"tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "AsIs", "redirect": "", "noises": []}},
    {"tag": "blocked", "protocol": "blackhole", "settings": {}},
    {"tag": "WARP", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": 40000, "users": []}]}}
  ],
  "policy": {
    "levels": {"0": {"statsUserDownlink": true, "statsUserUplink": true}},
    "system": {"statsInboundDownlink": true, "statsInboundUplink": true, "statsOutboundDownlink": false, "statsOutboundUplink": false}
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
      {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]},
      {"type": "field", "inboundTag": [$inbound_tag], "outboundTag": "WARP"}
    ]
  },
  "stats": {},
  "metrics": {"tag": "metrics_out", "listen": "127.0.0.1:11111"}
}')

                XRAY_CONFIG_ENCODED=$(echo "$XRAY_CONFIG" | jq -sRr @uri)

                echo -e "${yellow}Отправка конфигурации Xray...${plain}" >&3
                UPDATE_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/panel/xray/update" \
                  -H "Content-Type: application/x-www-form-urlencoded" \
                  --data-raw "xraySetting=${XRAY_CONFIG_ENCODED}")

                if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
                    echo -e "${green}Конфигурация Xray успешно обновлена${plain}" >&3

                    RESTART_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/server/restartXrayService")

                    if echo "$RESTART_RESPONSE" | grep -q '"success":true'; then
                        echo -e "${green}Xray успешно перезапущен с настройками WARP${plain}" >&3
                        echo -e "\n${green}VLESS Reality с поддержкой WARP успешно настроен!${plain}" >&3
                        echo -e "${yellow}Весь трафик через Reality инбаунд теперь идёт через WARP${plain}" >&3
                    else
                        echo -e "${red}Ошибка при перезапуске Xray:${plain}" >&3
                        echo "$RESTART_RESPONSE" >&3
                    fi
                else
                    echo -e "${red}Ошибка при обновлении конфигурации Xray:${plain}" >&3
                    echo "$UPDATE_RESPONSE" >&3
                fi
            else
                echo -e "${red}Ошибка при установке WARP${plain}" >&3
            fi
            rm -f /tmp/warp_menu.sh
        else
            echo -e "${red}Не удалось загрузить скрипт WARP${plain}" >&3
        fi
    fi

    rm -f "$COOKIE_JAR"

    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${INBOUND_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${BEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#${INBOUND_REMARK}"

    echo -e ""
    echo -e "\n\033[0;32mVLESS Reality успешно создан!\033[0m" >&3
    echo -e "\033[1;36mВаш VPN ключ:\033[0m" >&3
    echo -e ""
    echo -e "${VLESS_LINK}" >&3
    echo -e ""
    echo -e "QR код:"
    echo -e ""
    qrencode -t ANSIUTF8 "$VLESS_LINK"
    echo -e ""

    {
    echo "Ваш VPN ключ:"
    echo ""
    echo "$VLESS_LINK"
    echo ""
    echo "Название инбаунда: ${INBOUND_REMARK}"
    echo "Порт инбаунда:     ${INBOUND_PORT}"
    echo "SNI / DEST:        ${BEST_DOMAIN}"
    echo ""
    qrencode -t ANSIUTF8 "$VLESS_LINK"
    } >> /root/3x-ui.txt
else
    echo -e "${red}Ошибка при добавлении инбаунда через API:${plain}" >&3
    echo "$ADD_RESULT" >&3
fi

SERVER_IP=${SERVER_IP:-$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)}

echo -e "\n\033[1;32mПанель управления 3X-UI:\033[0m" >&3
echo -e "Адрес: \033[1;36mhttp://${SERVER_IP}:${PORT}/${WEBPATH}\033[0m" >&3
echo -e "Логин: \033[1;33m${USERNAME}\033[0m" >&3
echo -e "Пароль:\033[1;33m${PASSWORD}\033[0m" >&3
echo -e "\nВсе данные сохранены в: \033[1;36m/root/3x-ui.txt\033[0m" >&3
echo -e "Просмотр: \033[0;36mcat /root/3x-ui.txt\033[0m" >&3

{
  echo "Панель управления 3X-UI:"
  echo "Адрес  - http://${SERVER_IP}:${PORT}/${WEBPATH}"
  echo "Логин:   ${USERNAME}"
  echo "Пароль:  ${PASSWORD}"
} >> /root/3x-ui.txt
