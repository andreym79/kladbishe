# Лендинг «Хранители памяти (graveangels)»

Одностраничный сайт: уход за могилами в Москве для семей в Израиле. Работает на https://graveangels.ru.

| Файл | Что это |
| --- | --- |
| `index.html` | Готовая страница — собирается из `site/` командой `python3 site/build.py` (на сервере — сама) |
| `site/schema.json` | Какие блоки есть на странице и какие у них поля + текущие тексты (`initial`) — по нему CRM строит редактор |
| `site/templates/` | Шаблоны страницы: по файлу на блок (`blocks/hero.html`, `blocks/prices.html` …) и форма заказа |
| `site/build.py` | Сборка страницы; `sync` — забрать опубликованную версию из CRM (на сервере раз в минуту) |
| `server/orders.py` | Сервис заказов: форма → Telegram и CRM |
| `images/` | Фото (на сайте используются `.webp`) |
| `fonts/` | Шрифты Cormorant Garamond и Manrope — грузятся с нашего сервера, без Google Fonts |
| `deploy/install.sh` | Установка сайта на сервер с нуля |
| `deploy/server-tune.sh` | Донастройка уже установленного сервера (HTTP/2, кэш) |
| `deploy/site-setup.sh` | Страница из шаблонов, синхронизация с CRM, сервисы — и для перевода уже работающего сервера |
| `deploy/crm-install.sh` | Mini CRM на этом же сервере (crm.graveangels.ru): готовые образы, подкачка, ограничения памяти |
| `deploy/update.sh` | Что делает `/opt/graveangels/update.sh` после скачивания репозитория |
| `worker/telegram-worker.js` | Старый посредник для Cloudflare — на сервере не нужен, оставлен на всякий случай |

## Как менять тексты, цены и фото

В CRM: **Сайт → Хранители памяти → Редактировать**. Блоки можно добавлять, скрывать (значок глаза), переставлять
и копировать; после правок — **Опубликовать**, через минуту сайт обновится сам. Шапка и подвал всегда на своих местах.

Новый тип блока или новое поле — правка `site/schema.json` и шаблона в `site/templates/blocks/`, затем на сервере
`bash /opt/graveangels/update.sh`: сайт сам отправит новое описание в CRM. Формат описания — `docs/SITE.md` в репозитории CRM.

## Как устроено на сервере

- **nginx** раздаёт сайт из `/var/www/graveangels`, сертификат https — Let's Encrypt, продлевается сам.
- **Заказы с формы** идут на `/api/order` → сервис `graveangels-orders` (`server/orders.py`) → Telegram-бот и CRM
  (контакт, сделка и задача «Обработать заявку»). Токен бота, CHAT_ID и адрес формы CRM лежат только на сервере:
  `/etc/graveangels/orders.env`. Заказ принят, если дошёл хотя бы до одного из них.
- **Страница** собирается из `site/`: таймер `graveangels-site.timer` раз в минуту спрашивает CRM, нет ли новой
  опубликованной версии, скачивает фото в `/var/www/graveangels/media/` и пересобирает `index.html`.
  Связь с CRM — `/etc/graveangels/site.env`. Если CRM недоступна, на сайте остаётся последняя собранная версия.
- **CRM** — `/opt/minicrm`, https://crm.graveangels.ru (Docker, готовые образы с GitHub). Обновление:
  `bash /opt/graveangels/repo/deploy/crm-install.sh` (резервная копия, новые образы, откат при ошибке).
- Outline VPN на том же сервере работает в Docker отдельно, сайт его не трогает.

## Обновить сайт после изменений на GitHub

Зайти на сервер и выполнить:

```
bash /opt/graveangels/update.sh
```

Скрипт скачает свежую версию из ветки `main` и сам подставит адрес для заказов в `index.html` (на GitHub `ORDER_ENDPOINT` остаётся пустым — это нормально).

## Установить на новый сервер (Ubuntu 22.04+)

```
curl -fsSLO https://raw.githubusercontent.com/andreym79/kladbishe/main/deploy/install.sh && bash install.sh
```

Скрипт спросит токен бота от @BotFather и попросит написать боту `/start`. Перед запуском домен `graveangels.ru` **и** `www.graveangels.ru` должны указывать на IP сервера (DNS в панели Beget). Повторный запуск безопасен.

## Если что-то не работает

- Сервис заказов: `systemctl status graveangels-orders`, журнал — `journalctl -u graveangels-orders`.
- Сертификат: `certbot certificates`.
- Если форма не может отправить заказ, посетитель видит просьбу написать в WhatsApp (+7 977 390-11-55) — заявки не теряются.
