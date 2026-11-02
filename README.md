# VPN-фронтинг стек: Nginx + Xray (VLESS/Trojan over WebSocket over TLS) + Certbot

Self-hosted VPN-прокси, замаскированный под обычный HTTPS-сайт:

* **Nginx** — принимает весь внешний трафик на 80/443, обслуживает fallback-сайт и проксирует WebSocket по «скрытому» пути на Xray.
* **Xray-core** — сам прокси; слушает **только внутри docker-сети** (порт наружу не публикуется).
* **Certbot** — одноразовый контейнер для получения/продления сертификатов Let's Encrypt (метод webroot, nginx не останавливается).

Все конфиги живут на хосте (bind mounts), секреты генерируются скриптами и хранятся в `.env` и `xray/users.json` (оба в gitignore). Образы зафиксированы переменными в `.env`, обновления — только явно через `update.sh`.

---

## Содержание

1. [Требования](#требования)
2. [Развёртывание (установка)](#развёртывание-установка)
3. [Управление пользователями](#управление-пользователями)
4. [Подключение клиентов](#подключение-клиентов)
5. [Ежедневное управление стеком](#ежедневное-управление-стеком)
6. [Обновление версий](#обновление-версий)
7. [Ротация секретов / смена домена](#ротация-секретов--смена-домена)
8. [Сертификаты](#сертификаты)
9. [Резервные копии и восстановление](#резервные-копии-и-восстановление)
10. [Структура проекта](#структура-проекта)
11. [Настройки `.env`](#настройки-env)
12. [Диагностика и частые проблемы](#диагностика-и-частые-проблемы)
13. [Безопасность](#безопасность)
14. [Тесты](#тесты)

---

## Требования

* Linux-сервер (VPS) с **публичным IP**; порт 80 обязан быть доступен извне (Let's Encrypt HTTP-01), 443 — для клиентов.
* Домен, у которого **A-запись** указывает на этот сервер (`dig +short ваш.домен`).
* Docker + Compose v2 (устанавливаются автоматически из `install.sh` через apt, либо ставятся вручную).
* Утилиты: `jq`, `openssl`, `python3`, `curl`, `gettext-base (envsubst)`; `qrencode` — опционально для QR-кодов.
* Запуск от **root** или от пользователя в группе `docker`.

---

## Развёртывание (установка)

### Быстрый старт (рекомендуется)

```bash
git clone <репозиторий> && cd vpn-docker
sudo ./install.sh --domain example.com --email you@example.com
```

Скрипт идемпотентен: повторный запуск безопасен — он ничего не удаляет, а лишь дозаполняет отсутствующее и продлевает сертификат. Полезные флаги:

| Флаг | Назначение |
|---|---|
| `--domain DOMAIN` | публичный домен (A-запись уже должна указывать на сервер) |
| `--email EMAIL` | контактный email для Let's Encrypt |
| `--staging` | тестовый CA Let's Encrypt (не создаёт доверенный сертификат, но снимает rate-limit) |
| `-y, --yes` | без интерактивных подтверждений (установка зависимостей, cron) |

Что делает `install.sh` по шагам:

1. Проверка ОС, прав, Docker/Compose (при отсутствии — предлагает поставить через apt).
2. Создаёт `.env` из `.env.example` (chmod 600), применяет `--domain/--email/--staging`.
3. Генерирует секреты (`scripts/generate-secrets.sh`): `HIDDEN_PATH`, `SECRET_BASE64`, `SECRET_PASSWORD` — только пустые значения, существующие не трогаются.
4. Создаёт пустой `xray/users.json`, если его нет.
5. Preflight-проверки (`scripts/check-env.sh`): DNS, занятость портов 80/443.
6. Поднимает стек с временным self-signed сертификатом (bootstrap, чтобы nginx мог отвечать на ACME-запросы).
7. Получает реальный сертификат Let's Encrypt методом webroot.
8. Перерендеривает конфиги с настоящим сертификатом, проверяет `nginx -t`, перезагружает nginx.
9. Прогоняет healthcheck.
10. Ставит в root-crontab ежедневную продление сертификата (03:00):
   `0 3 * * * .../certbot/renew-hook.sh renew >> .../backups/renew.log 2>&1`
11. Показывает итог и следующие шаги.

### Ручная установка (если не хотите инсталлятор)

```bash
cp .env.example .env && chmod 600 .env      # отредактируйте DOMAIN, ACME_EMAIL
bash scripts/generate-secrets.sh            # сгенерировать HIDDEN_PATH и ключи
mkdir -p nginx/certs xray clients backups
bash scripts/render-configs.sh              # рендер nginx-conf и xray config.json
docker compose up -d                        # поднять стек
docker compose run --rm certbot certonly --webroot -w /var/www/acme \
    -d "$DOMAIN" --email "$ACME_EMAIL" --agree-tos --no-eff-email
bash scripts/render-configs.sh && bash certbot/renew-hook.sh deploy-only
bash scripts/healthcheck.sh
```

### Первый пользователь

```bash
./manage.sh add-user phone        # создаст UUID и сразу покажет ссылку
./manage.sh show-link phone       # ссылка позже
./manage.sh show-qr phone         # QR прямо в терминале
```

---

## Управление пользователями

Всё через `./manage.sh`. Пользователи хранятся в `xray/users.json` (name / uuid / enabled / created_at). Любое изменение пользователей пересобирает конфиг Xray и **пересоздаёт контейнер xray (~1 секунда — активные туннели коротко падают)**. Nginx при этом не трогается, публичный сайт продолжает работать.

| Команда | Что делает |
|---|---|
| `./manage.sh add-user <имя>` | Генерирует UUID, добавляет пользователя, применяет конфиг, печатает клиентскую ссылку. Имя: `[A-Za-z0-9_-]`, до 32 символов |
| `./manage.sh remove-user <имя>` | Удаляет пользователя (с подтверждением) и его файлы в `clients/`; ссылка сразу перестаёт работать |
| `./manage.sh list-users` | Таблица name / uuid / enabled / created_at (UUID — секрет!) |
| `./manage.sh show-link <имя>` | Печатает `vless://…` (или `trojan://…`) ссылку |
| `./manage.sh show-qr <имя>` | То же в виде QR-кода (нужен `qrencode`) |
| `./manage.sh export-links [--json]` | Экспортирует ссылки **всех** пользователей в `clients/<имя>.txt` (chmod 600, в gitignore); `--json` — дополнительно JSON-конфиг |
| `./manage.sh rotate-user <имя>` | Новый UUID для существующего имени — старая ссылка умертвляется, печатается новая |
| `./manage.sh disable-user <имя>` | Временно отключить: запись остаётся в файле, но исключается из рабочего конфига Xray |
| `./manage.sh enable-user <имя>` | Включить обратно |

Пример типового цикла «выдать устройство другу / забрать доступ»:

```bash
./manage.sh add-user friend-laptop   # выдать
./manage.sh disable-user friend-laptop   # временно выключить
./manage.sh rotate-user friend-laptop    # сменить ключ (старая ссылка скомпрометирована)
./manage.sh remove-user friend-laptop    # удалить совсем
```

---

## Подключение клиентов

Формат ссылки (генерируется автоматически):

```
vless://<UUID>@<DOMAIN>:443?encryption=none&security=tls&type=ws&host=<DOMAIN>&path=<URL-encoded HIDDEN_PATH>&sni=<DOMAIN>#<имя>
```

При `PROFILE=trojan` в `.env`: `trojan://<TROJAN_PASSWORD>@<DOMAIN>:443?...&type=ws...`.

Работает в любых клиентах, поддерживающих **VLESS + WebSocket + TLS**: v2rayN / v2rayNG (Windows/Android), Streisand, Shadowrocket/Hiddify (iOS), Xray-core/xray-ruleset-совместимые. Просто вставьте ссылку или отсканируйте QR (`./manage.sh show-qr <имя>`).

**Ссылка = пароль.** Не пересылайте её по незащищённым каналам; при утечке — `rotate-user`.

---

## Ежедневное управление стеком

| Команда | Назначение |
|---|---|
| `./manage.sh status` | `docker compose ps` + полный healthcheck |
| `./manage.sh logs [svc]` | Тейл логов (`svc` = `nginx` / `xray` / все) |
| `./manage.sh restart` | Перезапуск всего стека (`docker compose restart`) |
| `./manage.sh reload` | Перерендерить конфиги → `nginx -t` → graceful reload nginx → пересоздать xray. Применяется после ручной правки шаблонов или `.env` |
| `bash scripts/check-env.sh` | Preflight: DNS, порты, наличие `.env`, сертификатов и т.д. (`--skip-dns`, `--skip-ports`) |
| `bash scripts/healthcheck.sh` | Живая проверка: редирект HTTP→HTTPS, работа сайта, проксирование скрытого WS-пути, срок действия сертификата |
| `docker compose down` | Полная остановка (данные и конфиги на хосте сохраняются) |

Полезно помнить: после любой ручной правки файлов в `nginx/conf.d/default.conf.template`, `xray/config.json.template` или значений в `.env` нужно выполнить `./manage.sh reload`.

---

## Обновление версий

Обновления контролируемые и обратимые — через `./update.sh`:

```bash
./update.sh --check                     # показать закреплённые образы и каналы релизов
./update.sh                             # pull закреплённых образов + recreate изменившихся
./update.sh --to nginx:1.28-alpine NGINX_IMAGE   # повысить версию конкретного образа
```

Порядок действий скрипта: pre-update backup → сохранение `.env`/конфигов в `backups/pre-update-<ts>/` → pull → пересборка → healthcheck. **Если проверка не прошла — автоматический откат** к предыдущему `.env` и конфигурации. После успешного обновления можно почистить старые образы: `docker image prune -f`.

Доступные переменные для `--to`: `NGINX_IMAGE`, `XRAY_IMAGE`, `CERTBOT_IMAGE`.

---

## Ротация секретов / смена домена

* **Компрометация доступа пользователя** → `./manage.sh rotate-user <имя>` (меняет только его UUID).
* **Компрометация общего конфига** (утечка `.env`): очистите в `.env` значения `SECRET_BASE64`, `SECRET_PASSWORD`, `HIDDEN_PATH` (для trojan — `TROJAN_PASSWORD`) и выполните:

  ```bash
  bash scripts/generate-secrets.sh   # сгенерирует заново только пустые поля
  ./manage.sh reload                 # перерендерить всё и применить
  ./manage.sh export-links           # обновить ссылки в clients/ — старые умрут
  ```

  Смена `HIDDEN_PATH` ломает все клиентские ссылки — раздайте новые.
* **Смена домена**: отредактируйте `DOMAIN` в `.env`, направьте A-запись, затем:

  ```bash
  sudo ./install.sh --domain новый.домен --email you@example.com   # идемпотентно, перевыпустит сертификат
  ./manage.sh export-links                                          # ссылки содержат домен — обновите их
  ```

---

## Сертификаты

Метод — **webroot**: certbot пишет challenge-файлы в общий volume `acme-web`, который nginx отдаёт по `/.well-known/acme-challenge/`. Nginx не останавливается, docker.sock в контейнерах не используется.

```bash
sudo ./certbot/renew-hook.sh renew          # плановое продление (это же делает cron ежедневно в 03:00)
sudo ./certbot/renew-hook.sh renew-now      # принудительная проверка/продление
sudo ./certbot/renew-hook.sh deploy-only    # просто скопировать текущие сертификаты в nginx/certs + reload
docker volume ls | grep certbot             # сертификаты в volume vpn-docker_certbot-conf
```

Совет: при отладке используйте `--staging`, чтобы не упереться в лимиты Let's Encrypt (5 выпусков на домен в неделю). Для смены email при ошибке аккаунта LE: удалите `/etc/letsencrypt/accounts` в volume или добавьте флаг регистрации без email.

---

## Резервные копии и восстановление

```bash
./backup.sh                    # tar.gz в BACKUP_DIR (по умолчанию backups/)
./backup.sh --encrypt          # + AES-256-CBC (openssl, pbkdf2), спросит пароль дважды
```

В архив попадает всё для восстановления: `.env`, `xray/users.json`, рабочий `xray/config.json`, рендеренный vhost nginx, дерево проекта, экспортированные сертификаты Let's Encrypt из volume, строка cron. **Архив содержит секреты** (права 0600) — храните его вне сервера!

Восстановление на этом или новом сервере:

```bash
./restore.sh backups/vpn-docker-backup-20260101-000000.tar.gz [--encrypt]
```

`restore.sh` покажет, что будет перезаписано, потребует подтверждение, предварительно сохранит текущее состояние в `backups/pre-restore-<ts>/`, затем распакует, починит права, перерендерит конфиги, поднимет стек и прогонит healthcheck.

---

## Структура проекта

```
.
├── install.sh                  # одношаговая идемпотентная установка
├── manage.sh                   # дневная эксплуатация: пользователи, статус, логи, reload
├── update.sh                   # контролируемое обновление образов с авто-откатом
├── backup.sh / restore.sh      # резервные копии и восстановление
├── docker-compose.yml          # nginx + xray + certbot (одноразовый)
├── .env.example                # шаблон настроек (после установки — .env, chmod 600)
├── scripts/
│   ├── common.sh               # общие хелперы (лог, env, compose) — только source
│   ├── check-env.sh            # preflight: DNS, порты, зависимости
│   ├── generate-secrets.sh     # генерация недостающих секретов в .env
│   ├── render-configs.sh       # рендер nginx conf.d + xray config.json из шаблонов
│   ├── generate-client-links.sh# сборка vless://|trojan:// ссылок, QR, JSON
│   └── healthcheck.sh          # живая проверка работы стека
├── nginx/
│   ├── nginx.conf              # статический основной конфиг
│   ├── conf.d/default.conf.template  # шаблон vhost (DOMAIN, HIDDEN_PATH, upstream)
│   ├── certs/                  # TLS-материал для nginx (рендерится из certbot volume)
│   ├── snippets/               # TLS-сниппеты (создаются при рендере)
│   └── html/                   # fallback-сайт
├── xray/
│   ├── config.json.template    # шаблон конфига Xray
│   ├── users.json              # пользователи (секрет, gitignored)
│   └── users.example.json      # пример структуры
├── certbot/renew-hook.sh       # продление/деплой сертификатов (cron)
├── clients/                    # экспортированные ссылки (0600, gitignored)
├── backups/                    # резервные копии (0700)
└── tests/smoke-test.sh         # офлайн-тесты + интеграция с живым стеком (--live)
```

---

## Настройки `.env`

| Переменная | Значение по умолчанию | Описание |
|---|---|---|
| `DOMAIN` | `vpn.example.com` | Публичный домен (обязательно изменить) |
| `ACME_EMAIL` | `admin@example.com` | Email для Let's Encrypt (обязательно изменить) |
| `USE_STAGING` | `false` | `true` — тестовый CA LE |
| `PROFILE` | `main` | Профиль Xray: `main` (VLESS+WS+TLS) или `trojan` |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | Публикуемые порты nginx |
| `HIDDEN_PATH` | *(генерируется)* | Секретный WS-путь, напр. `/api/v1/9f3c2a7b/stream` |
| `SECRET_BASE64`, `SECRET_PASSWORD` | *(генерируются)* | Ключи anti-replay defenses Xray |
| `TROJAN_PASSWORD` | *(генерируется для trojan)* | Пароль, если `PROFILE=trojan` |
| `XRAY_INTERNAL_PORT` | `10000` | Порт Xray внутри docker-сети |
| `NETWORK_NAME` | `vpn-frontend` | Имя docker-сети |
| `NGINX_IMAGE` / `XRAY_IMAGE` / `CERTBOT_IMAGE` | pinned теги | Закреплённые образы (менять через `update.sh --to`) |
| `BACKUP_DIR` | `./backups` | Куда писать резервные копии |
| `LOG_LEVEL` | `warning` | Уровень логов Xray |

После любой правки `.env` — `./manage.sh reload`.

---

## Диагностика и частые проблемы

| Симптом | Причина / решение |
|---|---|
| Ошибка выпуска сертификата | `dig +short $DOMAIN` должен возвращать IP этого сервера; входящий TCP 80 не закрыт фаерволом/панелью облака; сработали лимиты LE → `--staging`. Подробности: `docker volume inspect vpn-docker_certbot-logs` или `tail backups/renew.log` |
| `port 80 is occupied` | Другой сервис (apache/nginx/host) занял порт — освободите его или поменяйте `HTTP_PORT/HTTPS_PORT` в `.env` и переустановите |
| Клиент не подключается | Проверьте `./manage.sh status` и `bash scripts/healthcheck.sh`; убедитесь, что используете актуальную ссылку (после `rotate-user`/смены `HIDDEN_PATH` старые ссылки мертвы); проверьте, что пользователь `enabled:true` в `list-users` |
| xray unhealthy | `./manage.sh logs xray`; типично — битый `config.json`: `bash scripts/render-configs.sh` пересоберёт его из шаблона |
| nginx не стартует | `docker compose exec nginx nginx -t`; чаще всего отсутствует сертификат в `nginx/certs` — `bash certbot/renew-hook.sh deploy-only` |
| Изменения пользователей «не применились» | Выполните `./manage.sh reload` (он пересоздаёт xray) и проверьте `list-users` |
| Нужно полностью пересобрать | `docker compose down && docker compose up -d` или `./install.sh` повторно (идемпотентен) |

---

## Безопасность

* Публикуются только 80/443; Xray недоступен напрямую из сети.
* Контейнер xray: `cap_drop: ALL`, без привилегий, `no-new-privileges`, конфиг примонтирован read-only.
* Секреты не попадают в git (`.env`, `xray/users.json`, `clients/`, `nginx/certs/*` — кроме шаблонов); права 600/700.
* Certbot работает webroot'ом — docker.sock не монтируется ни в один долгоживущий контейнер.
* Ссылка клиента — это фактически пароль: храните `clients/` и вывод `show-link` соответствующе; при утечке — `rotate-user`.
* Логи контейнеров ограничены (10 МБ × 3 файла).

---

## Тесты

```bash
./tests/smoke-test.sh          # офлайн-проверки: синтаксис всех скриптов, парсинг compose,
                               # генерация секретов, юз-кейсы пользователей через jq,
                               # валидность рендера nginx/xray и формата ссылок
./tests/smoke-test.sh --live   # + проверки живого стека: редиректы, сертификат, скрытый путь,
                               # цикл add-user -> link -> remove
```

Офлайн-часть можно запускать где угодно (CI, ноутбук) — Docker не нужен.
