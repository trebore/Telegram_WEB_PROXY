Купить кофе автору:
USDT(BNB) - 0x15c8ec6ef4e8d7343ddb4cc07c0f0e32d070fae7

Скрипт для установки и обслуживания Telegram WEB proxy на сервере:

- `telegramdesktop/tproxy-server` как web-relay;
- официальный MTProxy как backend;
- фронтенд через существующий nginx Remnawave или через standalone Caddy;
- отдельные пользовательские секреты и ссылки;
- автоматическое обновление `proxy-multi.conf` с адресами серверов Telegram.

## Главное требование: домен должен указывать на IP сервера

Перед установкой обязательно создайте DNS-запись для домена прокси.

Нужна `A`-запись:

```text
proxy.example.com  A  <публичный IPv4 вашего сервера>
```

Важно:

- домен передается в скрипт через `--domain`;
- домен должен быть отдельным hostname, например `proxy.example.com`;
- `A`-запись должна указывать именно на текущий сервер;
- CDN/проксирование нужно отключить, запись должна быть прямой, например `DNS only` в Cloudflare;
- `AAAA`-запись допустима только если IPv6 реально настроен на этом сервере;
- если IPv6 на сервере нет, удалите `AAAA`, иначе Let's Encrypt и клиенты могут пойти по нерабочему IPv6.

Скрипт проверяет DNS перед установкой. Если домен не указывает на IP сервера, установка остановится с ошибкой. Можно дать DNS время обновиться через `--dns-wait 300`.

Проверить заранее:

```bash
curl -4 https://api.ipify.org
dig +short A proxy.example.com @1.1.1.1
dig +short AAAA proxy.example.com @1.1.1.1
```

IP из первой команды должен совпадать с `A`-записью домена.

## Требования

- Ubuntu 22.04+ или Debian 12+.
- Архитектура `x86_64`.
- Запуск от `root`.
- Открытые входящие порты `80/tcp` и `443/tcp`.
- Порты `2398`, `8888`, `8080`, `8081` не должны быть открыты наружу.
- Для режима Remnawave нужен существующий docker/nginx-контейнер Remnawave.

Базовые пакеты скрипт устанавливает сам через `apt`.

## Быстрый запуск

Скопируйте скрипт на сервер и запустите:

```bash
chmod +x setup-tproxy.sh
sudo ./setup-tproxy.sh install \
  --domain proxy.example.com \
  --email admin@example.com \
  --dns-wait 300
```

Если команда запускается только с `--domain`, без явной команды, это тоже считается установкой:

```bash
sudo ./setup-tproxy.sh --domain proxy.example.com --email admin@example.com
```

Интерактивное меню:

```bash
sudo ./setup-tproxy.sh
```

## Режимы установки

По умолчанию используется `--mode auto`.

- `auto` - скрипт сам выбирает режим.
- `remnawave` - интеграция с nginx-контейнером Remnawave. Скрипт добавляет server-блок, сертификат и volume в docker-compose. Контейнеры пересоздаются, VPN может кратко прерваться.
- `standalone` - если Remnawave/nginx нет, ставится Caddy. Он занимает `80/443` и сам выпускает TLS-сертификат.

Явно указать режим:

```bash
sudo ./setup-tproxy.sh install \
  --domain proxy.example.com \
  --email admin@example.com \
  --mode standalone
```

Для Remnawave:

```bash
sudo ./setup-tproxy.sh install \
  --domain proxy.example.com \
  --email admin@example.com \
  --mode remnawave \
  --remnanode-dir /opt/remnanode \
  --nginx-container remnawave-nginx
```

## Сайт-заглушка

Relay отдает обычный сайт на `https://domain/`, чтобы прокси выглядел как нормальный web-сайт.

Можно передать свой источник:

```bash
sudo ./setup-tproxy.sh install --domain proxy.example.com --site-dir /path/to/site
sudo ./setup-tproxy.sh install --domain proxy.example.com --site-archive /path/to/site.zip
sudo ./setup-tproxy.sh install --domain proxy.example.com --site-git https://github.com/user/site.git
sudo ./setup-tproxy.sh install --domain proxy.example.com --site-auto
```

Если источник не указан, скрипт использует уже установленный сайт или создаст заглушку автоматически.

## После установки

Показать конфигурацию, ссылку и состояние сервисов:

```bash
sudo ./setup-tproxy.sh show
```

В конце установки скрипт выводит ссылку вида:

```text
https://t.me/webproxy?server=proxy.example.com&secret=<secret>
```

Секреты хранятся в `/etc/tproxy-server/profiles.json`.

## Пользователи

Скрипт поддерживает отдельный секрет на пользователя.

```bash
sudo ./setup-tproxy.sh users list
sudo ./setup-tproxy.sh users add alice
sudo ./setup-tproxy.sh users disable alice
sudo ./setup-tproxy.sh users enable alice
sudo ./setup-tproxy.sh users delete alice
sudo ./setup-tproxy.sh users limit alice 6
sudo ./setup-tproxy.sh users limits
sudo ./setup-tproxy.sh users apply
```

Лимит по IP не используется, потому что много пользователей могут находиться за одним NAT оператора.

## Обслуживание

Обновить адреса серверов Telegram и поставить ежедневный timer:

```bash
sudo ./setup-tproxy.sh refresh
```

Переустановить backend без смены домена, секрета, сайта и сертификата:

```bash
sudo ./setup-tproxy.sh reinstall
```

Удалить изменения скрипта:

```bash
sudo ./setup-tproxy.sh uninstall
```

Удалить и восстановить конфиги из бэкапов:

```bash
sudo ./setup-tproxy.sh restore
```

Полная очистка с удалением сертификата и компонентов, которые поставил скрипт:

```bash
sudo ./setup-tproxy.sh uninstall --purge
```

## Где лежат файлы

- `/etc/tproxy-server` - конфигурация relay и секреты.
- `/srv/tproxy-site` - сайт-заглушка.
- `/var/lib/tproxy-setup/state.env` - сохраненное состояние установки.
- `/var/log/tproxy-setup.log` - лог установки без секрета.
- `/opt/tproxy-server` - исходники и сборка `tproxy-server`.

## Частые ошибки

`A-запись не указывает на этот сервер`  
Создайте или исправьте `A`-запись домена на публичный IPv4 сервера. Если запись только что изменена, запустите с `--dns-wait 300`.

`У домена есть AAAA, которой нет на сервере`  
Удалите `AAAA`-запись или настройте IPv6 на сервере.

`Порт 80 занят`  
Для выпуска сертификата Let's Encrypt порт `80/tcp` должен быть доступен. Освободите порт или используйте подходящий режим интеграции.

`Порт 443 занят` в standalone-режиме  
Standalone-режим ставит Caddy, который должен слушать `443/tcp`. Если на сервере уже есть Xray/Reality/nginx на `443`, используйте режим `remnawave` или настройте фронтенд вручную.
