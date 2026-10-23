# Установка сайта graveangels.ru: nginx + https + пересылка заказов в Telegram.
# Повторный запуск безопасен. Outline VPN и Docker не трогает.
# Запуск на сервере: curl -fsSLO https://raw.githubusercontent.com/andreym79/kladbishe/main/deploy/install.sh && bash install.sh
set -euo pipefail

DOMAIN=graveangels.ru
APP=/opt/graveangels
ENVF=/etc/graveangels/orders.env

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || fail "запустите от root"

say "1/6 Ставлю nginx, certbot и git (1-2 минуты)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null
apt-get -o DPkg::Lock::Timeout=300 install -y -q nginx certbot python3-certbot-nginx git rsync curl python3 >/dev/null
echo "Установлено."

setup_telegram() {
  local token chat code found
  echo "Нужен токен бота: Telegram -> @BotFather -> /mybots -> @Andrymorbot -> API Token."
  while :; do
    read -rp "Введите токен и нажмите Enter. Пусто = пропустить: " token
    token=$(printf '%s' "$token" | tr -d '[:space:]')
    [ -n "$token" ] || return 1
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://api.telegram.org/bot$token/getMe" || true)
    case "$code" in
      200) echo "Токен подходит."; break ;;
      401|404) warn "Telegram не принял токен. Проверьте и вставьте ещё раз." ;;
      *) warn "Сервер не может связаться с api.telegram.org (код: $code)."; return 1 ;;
    esac
  done

  echo
  echo "Откройте @Andrymorbot в Telegram и отправьте ему любое сообщение, например /start."
  read -rp "Когда отправите, нажмите здесь Enter... " _
  found=$(curl -sS --max-time 15 "https://api.telegram.org/bot$token/getUpdates" | python3 -c '
import json, sys
seen = {}
for u in json.load(sys.stdin).get("result", []):
    m = u.get("message") or u.get("edited_message") or u.get("my_chat_member") or {}
    c = m.get("chat")
    if c:
        seen[c["id"]] = c.get("title") or c.get("first_name") or c.get("username") or ""
for k, v in seen.items():
    print(k, v)
' 2>/dev/null || true)
  if [ "$(printf '%s' "$found" | grep -c .)" = 1 ]; then
    chat=${found%% *}
    echo "Нашёл ваш чат: $found"
  else
    if [ -n "$found" ]; then printf 'Нашёл несколько чатов:\n%s\n' "$found"; fi
    read -rp "Введите CHAT_ID (число): " chat
  fi
  chat=$(printf '%s' "$chat" | tr -d '[:space:]')
  [[ "$chat" =~ ^-?[0-9]+$ ]] || { warn "CHAT_ID должен быть числом."; return 1; }

  if curl -fsS -o /dev/null --max-time 15 --data-urlencode "chat_id=$chat" \
       --data-urlencode "text=✅ Сайт $DOMAIN подключён. Заказы с сайта будут приходить сюда." \
       "https://api.telegram.org/bot$token/sendMessage"; then
    install -d -m 700 /etc/graveangels
    (umask 077; printf 'BOT_TOKEN=%s\nCHAT_ID=%s\n' "$token" "$chat" > "$ENVF")
    echo "Проверочное сообщение отправлено в Telegram."
  else
    warn "Не удалось отправить сообщение в чат $chat."
    return 1
  fi
}

say "2/6 Подключаю заказы в Telegram"
if [ -f "$ENVF" ]; then
  echo "Telegram уже настроен. Чтобы ввести токен заново: rm $ENVF и запустите скрипт ещё раз."
  TG=1
elif setup_telegram; then
  TG=1
else
  TG=0
  warn "Telegram пропущен: форма заказа будет открывать WhatsApp, как раньше."
fi

say "3/6 Скачиваю сайт с GitHub"
mkdir -p "$APP"
cat > "$APP/update.sh" <<'UPDEOF'
# Обновить сайт с GitHub: bash /opt/graveangels/update.sh
set -euo pipefail
APP=/opt/graveangels
WEB=/var/www/graveangels
if [ -d "$APP/repo/.git" ]; then
  git -C "$APP/repo" fetch -q --depth 1 origin main
  git -C "$APP/repo" reset -q --hard origin/main
else
  git clone -q --depth 1 https://github.com/andreym79/kladbishe.git "$APP/repo"
fi
mkdir -p "$WEB"
rsync -a --delete --chmod=D755,F644 --exclude .git --exclude worker --exclude README.md --exclude .nojekyll --exclude deploy --exclude '*.sh' "$APP/repo/" "$WEB/"
# Если Telegram настроен, форма отправляет заказы на наш сервер
if [ -f /etc/graveangels/orders.env ]; then
  sed -i "s|var ORDER_ENDPOINT = '[^']*';|var ORDER_ENDPOINT = '/api/order';|" "$WEB/index.html"
fi
echo "Сайт обновлён: $(git -C "$APP/repo" log -1 --format='%h %s')"
UPDEOF
bash "$APP/update.sh"

say "4/6 Сервис пересылки заказов"
cat > "$APP/orders.py" <<'PYEOF'
# Принимает заказ с сайта и пересылает его в Telegram (замена Cloudflare Worker).
import json, os, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ["BOT_TOKEN"]
CHAT_ID = os.environ["CHAT_ID"]
ALLOWED = {s + "://" + h for s in ("https", "http") for h in ("graveangels.ru", "www.graveangels.ru")}


def clean(v, n):
    return str(v or "").strip()[:n]


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        origin = self.headers.get("Origin", "")
        if origin and origin not in ALLOWED:
            return self.reply(403, "Forbidden")
        try:
            size = min(int(self.headers.get("Content-Length") or 0), 20000)
            o = json.loads(self.rfile.read(size) or b"{}")
            if not isinstance(o, dict):
                raise ValueError
        except Exception:
            return self.reply(400, "Bad request")

        # Ловушка для спам-ботов: скрытое поле должно быть пустым
        if o.get("website"):
            return self.reply(200, "OK")

        name, phone, cemetery = clean(o.get("name"), 120), clean(o.get("phone"), 40), clean(o.get("cemetery"), 200)
        if not (name and phone and cemetery):
            return self.reply(400, "Missing fields")

        lines = ["🕯 Новый заказ с сайта", "", "Имя: " + name, "Телефон: " + phone, "Кладбище: " + cemetery]
        if o.get("grave"):
            lines.append("Имя на могиле: " + clean(o.get("grave"), 200))
        lines.append("Тариф: " + clean(o.get("tariff"), 80))
        if o.get("info"):
            lines.append("Дополнительно: " + clean(o.get("info"), 1500))

        data = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": "\n".join(lines)}).encode()
        try:
            urllib.request.urlopen("https://api.telegram.org/bot" + TOKEN + "/sendMessage", data, timeout=15)
        except Exception as e:
            print("telegram error:", e, flush=True)
            return self.reply(502, "Telegram error")
        self.reply(200, "OK")


ThreadingHTTPServer(("127.0.0.1", 8787), Handler).serve_forever()
PYEOF
cat > /etc/systemd/system/graveangels-orders.service <<'UNITEOF'
[Unit]
Description=graveangels.ru orders -> Telegram
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/graveangels/orders.env
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 /opt/graveangels/orders.py
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
if [ "$TG" = 1 ]; then
  if systemctl -q is-active graveangels-orders; then :
  elif ss -tln | grep -q ':8787 '; then fail "порт 8787 занят другой программой"
  fi
  systemctl enable -q graveangels-orders
  systemctl restart graveangels-orders
  sleep 2
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8787/ || true)
  if [ "$code" = 400 ]; then echo "Сервис заказов работает."; else warn "Сервис заказов не отвечает. Журнал: journalctl -u graveangels-orders"; fi
else
  echo "Пропущено (Telegram не настроен)."
fi

say "5/6 Настраиваю nginx"
echo 'limit_req_zone $binary_remote_addr zone=graveangels_orders:1m rate=10r/m;' > /etc/nginx/conf.d/graveangels-ratelimit.conf
if [ -f /etc/nginx/sites-available/graveangels ]; then
  echo "Настройки nginx для сайта уже есть, оставляю."
else
  cat > /etc/nginx/sites-available/graveangels <<'NGXEOF'
server {
    listen 80;
    server_name graveangels.ru www.graveangels.ru;
    root /var/www/graveangels;
    index index.html;
    charset utf-8;

    location / {
        try_files $uri $uri/ =404;
    }

    location /images/ {
        expires 30d;
    }

    location /fonts/ {
        types { font/woff2 woff2; }
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location = /api/order {
        limit_req zone=graveangels_orders burst=5 nodelay;
        client_max_body_size 16k;
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGXEOF
fi
ln -sf /etc/nginx/sites-available/graveangels /etc/nginx/sites-enabled/graveangels
rm -f /etc/nginx/sites-enabled/default
nginx -t -q
systemctl enable -q nginx
systemctl reload-or-restart nginx
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  echo "Открыл порты 80 и 443 в файрволе."
fi
echo "nginx работает."

say "6/6 Получаю сертификат https (Let's Encrypt)"
HTTPS=0
if certbot --nginx -n --agree-tos --register-unsafely-without-email --keep-until-expiring --redirect -d "$DOMAIN" -d "www.$DOMAIN"; then
  HTTPS=1
  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' /etc/nginx/sites-available/graveangels
  nginx -t -q && systemctl reload nginx
else
  warn "Сертификат получить не удалось, сайт пока работает по http. Пришлите текст ошибки выше."
fi

say "Готово"
if [ "$HTTPS" = 1 ]; then echo "Сайт:    https://$DOMAIN"; else echo "Сайт:    http://$DOMAIN"; fi
if [ "$TG" = 1 ]; then echo "Заказы:  приходят в Telegram-бота"; else echo "Заказы:  через WhatsApp"; fi
echo "Обновить сайт после изменений на GitHub:  bash $APP/update.sh"
