# Лендинг «Хранители памяти (graveangels)»

Одностраничный сайт: уход за могилами в Москве для семей в Израиле. Работает на https://graveangels.ru.

| Файл | Что это |
| --- | --- |
| `index.html` | Весь сайт: разметка, стили и форма заказа в одном файле |
| `images/` | Фото (на сайте используются `.webp`) |
| `fonts/` | Шрифты Cormorant Garamond и Manrope — грузятся с нашего сервера, без Google Fonts |
| `deploy/install.sh` | Установка сайта на сервер с нуля |
| `deploy/server-tune.sh` | Донастройка уже установленного сервера (HTTP/2, кэш) |
| `worker/telegram-worker.js` | Старый посредник для Cloudflare — на сервере не нужен, оставлен на всякий случай |

## Как устроено на сервере

- **nginx** раздаёт сайт из `/var/www/graveangels`, сертификат https — Let's Encrypt, продлевается сам.
- **Заказы с формы** идут на `/api/order` → сервис `graveangels-orders` (`/opt/graveangels/orders.py`) → Telegram-бот.
  Токен бота и CHAT_ID лежат только на сервере: `/etc/graveangels/orders.env`.
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
