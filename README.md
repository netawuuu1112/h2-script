# h2-script

Bash-скрипт для настройки Hysteria2 на ноде Remnawave (remnanode).

Что делает:

- выпускает сертификат Let's Encrypt через certbot (standalone, порт 80)
- кладёт сертификат в `/opt/hysteria/certs`
- ставит deploy-hook, который при продлении сертификата копирует его заново и перезапускает контейнер remnanode
- открывает в UFW порт 80/tcp (нужен только для ACME) и 443/udp (сам Hysteria2)
- включает BBR, если он доступен в ядре
- добавляет volume с сертификатами в docker-compose.yml remnanode (перед правкой делает бэкап файла)
- пересоздаёт контейнер, чтобы подхватить volume

## Требования

- Ubuntu/Debian, root
- уже поднятый remnanode через docker compose
- домен, у которого A/AAAA запись указывает на этот сервер
- python3 (скрипт им правит docker-compose.yml)

## Запуск

Скачать и сразу запустить:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Origamidnd/h2-script/master/setup.sh)"
```

(process substitution `<(...)` тут не подходит — sudo закрывает лишние файловые дескрипторы у дочернего процесса, и `/dev/fd/...` становится недоступен)

Или вручную:

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/Origamidnd/h2-script/master/setup.sh
sudo bash setup.sh
```

Скрипт спросит:

- домен для этой ноды
- email для Let's Encrypt
- путь к docker-compose.yml remnanode (по умолчанию `/opt/remnanode/docker-compose.yml`)

Перед стартом покажет введённые параметры и попросит подтверждение.

## Что трогает на сервере

- `/etc/letsencrypt` — certbot
- `/opt/hysteria/certs` — копии сертификата для контейнера
- `/etc/letsencrypt/renewal-hooks/deploy` — хук авто-продления
- `/etc/sysctl.conf` — параметры BBR
- ваш docker-compose.yml — добавляет строку volume, оригинал сохраняется рядом как `.bak.<timestamp>`

## После запуска

Привязать Hysteria2 config profile для этой ноды в панели Remnawave. Порт 80/tcp можно закрыть обратно, он нужен только на момент выпуска и продления сертификата.

## Лицензия

MIT
