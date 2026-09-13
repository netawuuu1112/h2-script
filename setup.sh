#!/bin/bash
set -euo pipefail

# ==========================================================
# Автонастройка сервера под Hysteria2 (Remnawave / remnanode)
# Делает: certbot (standalone), UFW правила, BBR, volume в
# docker-compose remnanode, deploy-hook для авто-продления.
# ==========================================================

CERTS_DIR="/opt/hysteria/certs"

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Запусти скрипт от root (sudo)."
  exit 1
fi

# ---------- 1. Ввод параметров ----------

read -rp "Домен для этой ноды (например node1.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  err "Домен обязателен."
  exit 1
fi

read -rp "Email для Let's Encrypt: " EMAIL
while [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
  warn "\"$EMAIL\" не похож на email (возможно, лишний символ прилетел от переключения раскладки в терминале)."
  read -rp "Email для Let's Encrypt: " EMAIL
done

read -rp "Путь к docker-compose.yml remnanode [/opt/remnanode/docker-compose.yml]: " COMPOSE_PATH
COMPOSE_PATH="${COMPOSE_PATH:-/opt/remnanode/docker-compose.yml}"

if [[ ! -f "$COMPOSE_PATH" ]]; then
  err "Файл $COMPOSE_PATH не найден. Проверь путь и перезапусти скрипт."
  exit 1
fi

echo
log "Параметры:"
echo "    Домен:        $DOMAIN"
echo "    Email:        $EMAIL"
echo "    Compose:      $COMPOSE_PATH"
echo "    Сертификаты:  $CERTS_DIR"
echo
read -rp "Всё верно? Продолжить установку? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  warn "Отменено пользователем."
  exit 0
fi

# ---------- 2. Проверка DNS ----------

log "Проверяю DNS-запись для $DOMAIN..."
RESOLVED_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n1 || true)
SERVER_IP=$(curl -s -4 --max-time 5 https://ifconfig.me || curl -s -4 --max-time 5 https://icanhazip.com || true)

if [[ -z "$RESOLVED_IP" ]]; then
  err "Домен $DOMAIN не резолвится. Проверь DNS-запись (A/AAAA) и повтори."
  exit 1
fi

if [[ -n "$SERVER_IP" && "$RESOLVED_IP" != "$SERVER_IP" ]]; then
  warn "Домен резолвится в $RESOLVED_IP, а IP этого сервера — $SERVER_IP."
  warn "Это может быть нормально (CDN/прокси), но для Let's Encrypt standalone нужно совпадение."
  read -rp "Продолжить всё равно? [y/N] " FORCE
  if [[ "$FORCE" != "y" && "$FORCE" != "Y" ]]; then
    exit 1
  fi
else
  log "DNS ок: $DOMAIN -> $RESOLVED_IP"
fi

# ---------- 3. UFW: открыть нужные порты ----------

if command -v ufw >/dev/null 2>&1; then
  log "Настраиваю UFW..."
  ufw allow 80/tcp   comment 'ACME challenge (certbot)' || true
  ufw allow 443/udp  comment 'Hysteria2' || true
  ufw status | grep -q "80/tcp" && log "80/tcp открыт" || warn "Не удалось подтвердить правило 80/tcp"
else
  warn "UFW не найден — пропускаю настройку файрвола. Убедись, что 80/tcp и 443/udp открыты вручную (в т.ч. в облачном firewall провайдера)."
fi

# ---------- 4. certbot ----------

if ! command -v certbot >/dev/null 2>&1; then
  log "Устанавливаю certbot..."
  apt-get update -qq
  apt-get install -y -qq certbot
else
  log "certbot уже установлен."
fi

mkdir -p "$CERTS_DIR"

if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
  log "Сертификат для $DOMAIN уже существует, пропускаю выпуск (используй certbot renew для обновления)."
else
  PORT80_PID=$(ss -tlnp 'sport = :80' 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n1)
  PORT80_CONTAINER=""
  PORT80_UNIT=""

  if [[ -n "$PORT80_PID" ]]; then
    CID=$(grep -oP '[0-9a-f]{64}' "/proc/$PORT80_PID/cgroup" 2>/dev/null | head -n1)
    if [[ -n "$CID" ]] && command -v docker >/dev/null 2>&1 && docker inspect "$CID" >/dev/null 2>&1; then
      PORT80_CONTAINER="$CID"
    else
      PORT80_UNIT=$(systemctl status "$PORT80_PID" 2>/dev/null | awk 'NR==1{print $2}')
    fi
  fi

  if [[ -n "$PORT80_CONTAINER" ]]; then
    CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$PORT80_CONTAINER" | sed 's#^/##')
    warn "Порт 80 занят докер-контейнером $CONTAINER_NAME, останавливаю на время выпуска сертификата..."
    docker stop "$PORT80_CONTAINER" >/dev/null
    trap 'docker start "$PORT80_CONTAINER" >/dev/null' EXIT
  elif [[ -n "$PORT80_UNIT" ]]; then
    warn "Порт 80 занят сервисом $PORT80_UNIT, останавливаю его на время выпуска сертификата..."
    systemctl stop "$PORT80_UNIT"
    trap 'systemctl start "$PORT80_UNIT"' EXIT
  fi

  log "Выпускаю сертификат через certbot (standalone, порт 80)..."
  certbot certonly --standalone -d "$DOMAIN" --agree-tos -m "$EMAIL" --non-interactive

  if [[ -n "$PORT80_CONTAINER" ]]; then
    trap - EXIT
    docker start "$PORT80_CONTAINER" >/dev/null
    log "Запустил $CONTAINER_NAME обратно."
  elif [[ -n "$PORT80_UNIT" ]]; then
    trap - EXIT
    systemctl start "$PORT80_UNIT"
    log "Запустил $PORT80_UNIT обратно."
  fi
fi

log "Копирую сертификат в $CERTS_DIR..."
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERTS_DIR/fullchain.pem"
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem"  "$CERTS_DIR/privkey.pem"

# ---------- 5. deploy-hook для авто-продления ----------

log "Настраиваю авто-продление сертификата..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy

HOOK_FILE="/etc/letsencrypt/renewal-hooks/deploy/hysteria-copy-${DOMAIN}.sh"
cat > "$HOOK_FILE" <<EOF
#!/bin/bash
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${CERTS_DIR}/fullchain.pem
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem  ${CERTS_DIR}/privkey.pem
docker compose -f ${COMPOSE_PATH} restart remnanode
EOF
chmod +x "$HOOK_FILE"
log "Deploy-hook создан: $HOOK_FILE"

# ---------- 6. BBR ----------

log "Проверяю BBR..."
if sysctl net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
  log "BBR доступен в ядре."
else
  warn "BBR недоступен в текущем ядре. Пропускаю (может потребоваться обновление ядра)."
fi

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$CURRENT_CC" == "bbr" ]]; then
  log "BBR уже активен."
else
  log "Включаю BBR..."
  grep -q "^net.core.default_qdisc" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null
  log "BBR включён."
fi

# ---------- 7. docker-compose: volume для сертификатов ----------

log "Проверяю volume в $COMPOSE_PATH..."
if grep -q "$CERTS_DIR" "$COMPOSE_PATH"; then
  log "Volume для $CERTS_DIR уже прописан в compose-файле."
else
  log "Добавляю volume для сертификатов в compose-файл (с бэкапом оригинала)..."
  cp "$COMPOSE_PATH" "${COMPOSE_PATH}.bak.$(date +%s)"

  python3 - "$COMPOSE_PATH" "$CERTS_DIR" <<'PYEOF'
import re
import sys

compose_path, certs_dir = sys.argv[1], sys.argv[2]
with open(compose_path) as f:
    lines = f.readlines()

new_line_content = f"{certs_dir}:{certs_dir}:ro"
inserted = False
out = []
for line in lines:
    out.append(line)
    match = re.match(r'^(\s*)volumes:\s*$', line.rstrip('\n'))
    if match and not inserted:
        indent = match.group(1) + "  "
        out.append(f"{indent}- '{new_line_content}'\n")
        inserted = True

if not inserted:
    print("WARN: не нашёл секцию volumes: в сервисе — добавь volume вручную:")
    print(f"      - '{new_line_content}'")
else:
    with open(compose_path, "w") as f:
        f.writelines(out)
    print(f"OK: volume {new_line_content} добавлен.")
PYEOF

fi

# ---------- 8. Пересоздать контейнер ----------

log "Пересоздаю контейнер remnanode (up -d, чтобы подхватить volume)..."
docker compose -f "$COMPOSE_PATH" up -d

echo
log "Готово. Проверяю последние логи remnanode..."
sleep 5
docker compose -f "$COMPOSE_PATH" logs --tail=30 remnanode

echo
log "=== Итог ==="
echo "  Домен:            $DOMAIN"
echo "  Сертификаты:       $CERTS_DIR"
echo "  Deploy-hook:       $HOOK_FILE"
echo "  Compose backup:    ${COMPOSE_PATH}.bak.* (если создавался)"
echo
warn "Не забудь: 1) прописать/привязать Hysteria2 config profile для этой ноды в панели Remnawave;"
warn "           2) при желании закрыть 80/tcp обратно (нужен только на момент certbot renew)."
