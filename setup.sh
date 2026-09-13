#!/usr/bin/env bash
set -Eeuo pipefail

CERTS_DIR="/opt/hysteria/certs"
PROFILE_FILE="/opt/hysteria/hysteria2-remnawave-profile.json"
COMPOSE_DEFAULT="/opt/remnanode/docker-compose.yml"
SERVICE=""

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Запусти скрипт от root."; exit 1; }

export DEBIAN_FRONTEND=noninteractive

need=0
for cmd in curl dig certbot python3 openssl ss; do
  command -v "$cmd" >/dev/null 2>&1 || need=1
done
if [[ "$need" == 1 ]]; then
  apt-get update -qq
  apt-get install -y -qq curl dnsutils certbot python3 openssl iproute2 ca-certificates
fi

command -v docker >/dev/null 2>&1 || { err "Docker не найден. Сначала установи Remnawave Node."; exit 1; }
docker compose version >/dev/null 2>&1 || { err "docker compose v2 не найден."; exit 1; }

read -rp "Домен ноды: " DOMAIN
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"

read -rp "Email для Let's Encrypt: " EMAIL
while [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
  warn "Некорректный email."
  read -rp "Email для Let's Encrypt: " EMAIL
done

read -rp "Путь к docker-compose.yml [$COMPOSE_DEFAULT]: " COMPOSE_PATH
COMPOSE_PATH="${COMPOSE_PATH:-$COMPOSE_DEFAULT}"
COMPOSE_PATH="$(readlink -f "$COMPOSE_PATH")"

[[ -f "$COMPOSE_PATH" ]] || { err "$COMPOSE_PATH не найден."; exit 1; }

# Автоопределение имени docker compose сервиса Remnawave Node.
mapfile -t COMPOSE_SERVICES < <(docker compose -f "$COMPOSE_PATH" config --services)

for candidate in remnanode node remnawave-node remnawave_node; do
  if printf '%s\n' "${COMPOSE_SERVICES[@]}" | grep -qx "$candidate"; then
    SERVICE="$candidate"
    break
  fi
done

# Если имя нестандартное — ищем сервис по запущенному контейнеру и image remnawave/node.
if [[ -z "$SERVICE" ]]; then
  for svc in "${COMPOSE_SERVICES[@]}"; do
    CID="$(docker compose -f "$COMPOSE_PATH" ps -q "$svc" 2>/dev/null || true)"
    [[ -n "$CID" ]] || continue
    IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CID" 2>/dev/null || true)"
    CNAME="$(docker inspect -f '{{.Name}}' "$CID" 2>/dev/null | sed 's#^/##' || true)"
    if [[ "$IMAGE" == remnawave/node* || "$CNAME" == *remnanode* ]]; then
      SERVICE="$svc"
      break
    fi
  done
fi

# Если compose содержит ровно один сервис, считаем его Node-сервисом.
if [[ -z "$SERVICE" && ${#COMPOSE_SERVICES[@]} -eq 1 ]]; then
  SERVICE="${COMPOSE_SERVICES[0]}"
fi

if [[ -z "$SERVICE" ]]; then
  err "Не удалось автоматически определить сервис Remnawave Node."
  echo "Сервисы в compose: ${COMPOSE_SERVICES[*]}"
  echo "Контейнеры compose:"
  docker compose -f "$COMPOSE_PATH" ps || true
  exit 1
fi

log "Определён Docker Compose сервис Node: $SERVICE"

SERVER_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(curl -4fsS --max-time 8 https://ifconfig.me || true)"
[[ -n "$SERVER_IP" ]] || { err "Не удалось определить публичный IPv4."; exit 1; }

log "IPv4 сервера: $SERVER_IP"
log "Проверяю A-запись $DOMAIN..."

DNS_OK=0
for R in system 8.8.8.8 1.1.1.1 9.9.9.9; do
  if [[ "$R" == system ]]; then
    A="$(dig +short A "$DOMAIN" 2>/dev/null || true)"
  else
    A="$(dig @"$R" +short A "$DOMAIN" 2>/dev/null || true)"
  fi
  echo "  $R -> ${A:-<пусто>}"
  echo "$A" | grep -qx "$SERVER_IP" && DNS_OK=1
done
[[ "$DNS_OK" == 1 ]] || {
  err "A-запись пока не указывает на $SERVER_IP."
  exit 1
}

if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp comment 'LetsEncrypt HTTP-01' >/dev/null || true
  ufw allow 443/udp comment 'Hysteria2' >/dev/null || true
  ufw status | head -n1 | grep -qi inactive && warn "UFW не активен. Скрипт не включает его автоматически, чтобы не потерять SSH."
else
  warn "UFW не найден. Проверь firewall провайдера: 80/tcp и 443/udp должны быть открыты."
fi

if ss -lunH | awk '{print $5}' | grep -Eq '(^|:)443$'; then
  warn "UDP/443 уже занят:"
  ss -lunp | grep -E '(:|\])443\b' || true
fi

mkdir -p "$CERTS_DIR"

if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] && \
   openssl x509 -checkend 86400 -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" >/dev/null 2>&1; then
  log "Действующий сертификат уже есть."
else
  if ss -ltnH '( sport = :80 )' | grep -q .; then
    err "TCP/80 занят. Освободи порт и запусти скрипт снова:"
    ss -ltnp '( sport = :80 )' || true
    exit 1
  fi

  log "Выпускаю Let's Encrypt сертификат..."
  certbot certonly \
    --standalone \
    --preferred-challenges http \
    -d "$DOMAIN" \
    --agree-tos \
    -m "$EMAIL" \
    --non-interactive
fi

install -d -m 755 "$CERTS_DIR"
install -m 644 "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERTS_DIR/fullchain.pem"
install -m 600 "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CERTS_DIR/privkey.pem"

log "Сертификат:"
openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -subject -issuer -dates

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
HOOK="/etc/letsencrypt/renewal-hooks/deploy/hysteria-${DOMAIN}.sh"

cat > "$HOOK" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/${DOMAIN}" ]] || exit 0
install -m 644 "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CERTS_DIR}/fullchain.pem"
install -m 600 "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${CERTS_DIR}/privkey.pem"
docker compose -f "${COMPOSE_PATH}" restart "${SERVICE}"
EOF
chmod 755 "$HOOK"

modprobe tcp_bbr 2>/dev/null || true
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  cat > /etc/sysctl.d/99-hysteria-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  log "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
else
  warn "BBR недоступен в этом ядре. Продолжаю без него."
fi

BACKUP="${COMPOSE_PATH}.bak-hysteria-$(date +%Y%m%d-%H%M%S)"
cp -a "$COMPOSE_PATH" "$BACKUP"

python3 - "$COMPOSE_PATH" "$CERTS_DIR:$CERTS_DIR:ro" "$SERVICE" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
mount = sys.argv[2]
service = sys.argv[3]
lines = path.read_text().splitlines(True)

services_i = None
for i, line in enumerate(lines):
    if re.match(r'^\s*services:\s*(?:#.*)?$', line.rstrip('\n')):
        services_i = i
        break
if services_i is None:
    raise SystemExit("services: section not found")

base_indent = len(lines[services_i]) - len(lines[services_i].lstrip(' '))
service_i = None
service_indent = None
pattern = r'^\s*' + re.escape(service) + r':\s*(?:#.*)?$'

for i in range(services_i + 1, len(lines)):
    raw = lines[i].rstrip('\n')
    if not raw.strip() or raw.lstrip().startswith('#'):
        continue
    indent = len(raw) - len(raw.lstrip(' '))
    if indent <= base_indent:
        break
    if re.match(pattern, raw):
        service_i = i
        service_indent = indent
        break
if service_i is None:
    raise SystemExit(f"service {service!r} not found")

end_i = len(lines)
for i in range(service_i + 1, len(lines)):
    raw = lines[i].rstrip('\n')
    if not raw.strip() or raw.lstrip().startswith('#'):
        continue
    indent = len(raw) - len(raw.lstrip(' '))
    if indent <= service_indent:
        end_i = i
        break

block = ''.join(lines[service_i:end_i])
certs_dir = mount.split(':', 1)[0]
if certs_dir in block:
    print(f"certificate mount already exists in {service}")
    raise SystemExit(0)

volumes_i = None
volumes_indent = None
for i in range(service_i + 1, end_i):
    raw = lines[i].rstrip('\n')
    if re.match(r'^\s*volumes:\s*(?:#.*)?$', raw):
        volumes_i = i
        volumes_indent = len(raw) - len(raw.lstrip(' '))
        break

if volumes_i is not None:
    lines.insert(volumes_i + 1, ' ' * (volumes_indent + 2) + f"- '{mount}'\n")
else:
    lines.insert(end_i, ' ' * (service_indent + 2) + "volumes:\n" + ' ' * (service_indent + 4) + f"- '{mount}'\n")

path.write_text(''.join(lines))
print(f"certificate mount added to {service}")
PY

if ! docker compose -f "$COMPOSE_PATH" config >/dev/null; then
  cp -a "$BACKUP" "$COMPOSE_PATH"
  err "Compose после изменения невалиден. Восстановлен backup: $BACKUP"
  exit 1
fi

cat > "$PROFILE_FILE" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "HYSTERIA-BBR",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "settings": {"users": [], "clients": [], "version": 2},
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [
            {
              "keyFile": "/opt/hysteria/certs/privkey.pem",
              "certificateFile": "/opt/hysteria/certs/fullchain.pem"
            }
          ]
        },
        "hysteriaSettings": {"version": 2}
      }
    }
  ],
  "outbounds": [
    {"tag": "DIRECT", "protocol": "freedom"},
    {"tag": "BLOCK", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [
      {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
      {"domain": ["geosite:private"], "outboundTag": "BLOCK"},
      {"protocol": ["bittorrent"], "outboundTag": "BLOCK"}
    ]
  }
}
JSON

python3 -m json.tool "$PROFILE_FILE" >/dev/null

log "Пересоздаю сервис Node: $SERVICE"
docker compose -f "$COMPOSE_PATH" up -d --force-recreate "$SERVICE"
sleep 5

CID="$(docker compose -f "$COMPOSE_PATH" ps -q "$SERVICE")"
[[ -n "$CID" ]] || { err "Контейнер Node не найден после recreate."; exit 1; }

docker inspect "$CID" --format '{{range .Mounts}}{{println .Destination}}{{end}}' | grep -qx "$CERTS_DIR" || {
  err "Volume $CERTS_DIR не появился внутри Node-контейнера."
  exit 1
}

docker exec "$CID" test -r "$CERTS_DIR/fullchain.pem"
docker exec "$CID" test -r "$CERTS_DIR/privkey.pem"

echo
log "========== ГОТОВО =========="
echo "Домен:             $DOMAIN"
echo "IPv4:              $SERVER_IP"
echo "Compose service:   $SERVICE"
echo "Сертификаты:       $CERTS_DIR"
echo "Профиль Remnawave: $PROFILE_FILE"
echo "Compose backup:    $BACKUP"
echo
log "Node API:"
ss -lntp | grep -E ':2222\b' || warn "TCP/2222 не найден — проверь логи Node-контейнера."
echo
log "После привязки профиля в панели проверь:"
echo "ss -lunp | grep ':443'"
echo
warn "TCP/443 и UDP/443 не конфликтуют: Hysteria2 использует UDP/443."
warn "TCP/80 должен быть доступен при продлении Let's Encrypt."
