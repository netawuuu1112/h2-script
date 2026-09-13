# h2-script

Автоматическая подготовка **Remnawave Node** под **Hysteria2**.

Скрипт рассчитан на уже установленную и рабочую ноду Remnawave с Docker Compose. Он не меняет `SECRET_KEY`, не трогает Node API и не переносит порт `2222`.

## Что делает

- автоматически определяет имя Docker Compose сервиса Remnawave Node (`remnanode`, `node` и другие варианты);
- проверяет A-запись домена через системный DNS, Google, Cloudflare и Quad9;
- определяет публичный IPv4 сервера и сверяет его с доменом;
- устанавливает необходимые зависимости;
- открывает `80/tcp` для Let's Encrypt и `443/udp` для Hysteria2 через UFW, если UFW установлен;
- проверяет, не занят ли `UDP/443`;
- выпускает сертификат Let's Encrypt через `certbot standalone`;
- сохраняет сертификаты в `/opt/hysteria/certs`;
- создаёт deploy-hook для автоматического обновления сертификатов и перезапуска именно обнаруженного Node-сервиса;
- включает BBR, если ядро его поддерживает;
- делает backup `docker-compose.yml`;
- добавляет volume с сертификатами только в обнаруженный сервис Remnawave Node;
- валидирует compose через `docker compose config`;
- пересоздаёт только Node-сервис;
- проверяет, что сертификаты реально примонтированы и читаются внутри контейнера;
- создаёт готовый Hysteria2 Config Profile для Remnawave: `/opt/hysteria/hysteria2-remnawave-profile.json`.

## Требования

- Ubuntu/Debian;
- запуск от `root`;
- уже установленный и рабочий Remnawave Node;
- Docker Compose v2;
- домен с A-записью на публичный IPv4 ноды;
- доступный `80/tcp` для выпуска/продления Let's Encrypt;
- доступный `443/udp` для Hysteria2.

## Запуск

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/netawuuu1112/h2-script/main/setup.sh)"
```

Скрипт попросит домен ноды, email для Let's Encrypt и путь к `docker-compose.yml`. По умолчанию используется:

```text
/opt/remnanode/docker-compose.yml
```

## После выполнения

Готовый профиль:

```bash
cat /opt/hysteria/hysteria2-remnawave-profile.json
```

Его нужно вставить в Config Profiles панели Remnawave и привязать к нужной ноде.

После применения профиля проверить:

```bash
ss -lunp | grep ':443'
```

Должен появиться Hysteria2 listener на `UDP/443`. Node API продолжает работать отдельно на `TCP/2222`.

## Обновление Remnawave Node

Сначала посмотреть имя compose-сервиса:

```bash
cd /opt/remnanode
docker compose config --services
```

Затем обновить все сервисы проекта:

```bash
cd /opt/remnanode
cp docker-compose.yml docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)
cp .env .env.bak-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

docker compose pull
docker compose up -d --force-recreate
sleep 5
docker compose ps
```

Логи Node можно посмотреть без предположения о container name:

```bash
cd /opt/remnanode
NODE_SERVICE="$(docker compose config --services | head -n1)"
docker compose logs --tail=100 "$NODE_SERVICE"
```

## Проверки

```bash
ss -lntp | grep ':2222'
ss -lunp | grep ':443'

docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

Чтобы проверить mount сертификатов, сначала найди Node-контейнер:

```bash
NODE_CID="$(docker ps -q --filter ancestor=remnawave/node:latest | head -n1)"
[[ -n "$NODE_CID" ]] || NODE_CID="$(docker ps -q --filter name=remnanode | head -n1)"
docker inspect "$NODE_CID" --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' | grep hysteria
```

## Важное

`TCP/443` и `UDP/443` не конфликтуют. Hysteria2 использует `UDP/443`.

`80/tcp` должен быть доступен во время выпуска и автоматического продления сертификата Let's Encrypt.

Скрипт специально не включает UFW автоматически, даже если пакет UFW установлен, чтобы не потерять SSH-доступ.

## Репозиторий

https://github.com/netawuuu1112/h2-script

## Лицензия

MIT
