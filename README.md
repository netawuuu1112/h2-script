# h2-script

Автоматическая подготовка **Remnawave Node** под **Hysteria2**.

Скрипт рассчитан на уже установленную и рабочую ноду Remnawave с Docker Compose. Он не меняет `SECRET_KEY`, не трогает Node API и не переносит порт `2222`.

## Что делает

- проверяет A-запись домена через системный DNS, Google, Cloudflare и Quad9;
- определяет публичный IPv4 сервера и сверяет его с доменом;
- устанавливает необходимые зависимости;
- открывает `80/tcp` для Let's Encrypt и `443/udp` для Hysteria2 через UFW, если UFW установлен;
- проверяет, не занят ли `UDP/443`;
- выпускает сертификат Let's Encrypt через `certbot standalone`;
- сохраняет сертификаты в:
  - `/opt/hysteria/certs/fullchain.pem`
  - `/opt/hysteria/certs/privkey.pem`
- создаёт deploy-hook для автоматического обновления сертификатов и перезапуска `remnanode`;
- включает BBR, если ядро его поддерживает;
- делает backup `docker-compose.yml`;
- добавляет volume с сертификатами **только в сервис `remnanode`**;
- валидирует compose через `docker compose config`;
- пересоздаёт только контейнер `remnanode`;
- проверяет, что сертификаты реально примонтированы и читаются внутри контейнера;
- создаёт готовый Hysteria2 Config Profile для Remnawave:
  `/opt/hysteria/hysteria2-remnawave-profile.json`.

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

Скрипт попросит:

- домен ноды;
- email для Let's Encrypt;
- путь к `docker-compose.yml` Remnawave Node.

По умолчанию используется:

```text
/opt/remnanode/docker-compose.yml
```

## После выполнения

Готовый профиль находится здесь:

```bash
cat /opt/hysteria/hysteria2-remnawave-profile.json
```

Его нужно создать/вставить в Config Profiles панели Remnawave и привязать к нужной ноде.

После применения профиля проверить:

```bash
ss -lunp | grep ':443'
```

Должен появиться listener Hysteria2 на `UDP/443`.

Node API при этом продолжает работать отдельно на `TCP/2222`.

## Обновление Remnawave Node

Если нода уже установлена в `/opt/remnanode`:

```bash
cd /opt/remnanode

docker compose pull

docker compose up -d --force-recreate

sleep 5

docker compose ps

docker logs --tail=100 remnanode
```

Перед обновлением рекомендуется сохранить compose и `.env`:

```bash
cd /opt/remnanode
cp docker-compose.yml docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)
cp .env .env.bak-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
```

## Проверки

Node API:

```bash
ss -lntp | grep ':2222'
```

Hysteria2:

```bash
ss -lunp | grep ':443'
```

Mount сертификатов:

```bash
docker inspect remnanode \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
  | grep hysteria
```

Сертификаты внутри контейнера:

```bash
docker exec remnanode ls -la /opt/hysteria/certs
```

Логи:

```bash
docker logs --tail=100 remnanode
```

## Важное

`TCP/443` и `UDP/443` не конфликтуют между собой. Hysteria2 использует `UDP/443`.

`80/tcp` должен быть доступен во время автоматического продления сертификата Let's Encrypt.

Скрипт специально не включает UFW автоматически, даже если пакет UFW установлен: это сделано, чтобы не потерять SSH-доступ к серверу.

## Репозиторий

https://github.com/netawuuu1112/h2-script

## Лицензия

MIT
