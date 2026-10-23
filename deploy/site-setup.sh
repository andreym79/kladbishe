# Сайт из шаблонов + связь с CRM (модуль «Сайт» и «Заявки с сайта»). Повторный запуск безопасен.
# Запуск: bash /opt/graveangels/repo/deploy/site-setup.sh
#   — страница собирается из site/ и раз в минуту забирает опубликованную версию из CRM,
#   — заказы с формы идут в Telegram (как раньше) и в CRM.
set -euo pipefail

APP=/opt/graveangels
REPO=$APP/repo
ETC=/etc/graveangels
CRM_API=${CRM_API:-http://127.0.0.1:4200/api}
SITE_KEY=${SITE_KEY:-graveangels}

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || fail "запустите от root"
[ -d "$REPO/.git" ] || fail "нет $REPO — сначала установите сайт (deploy/install.sh)"
install -d -m 700 "$ETC"

say "1/4 Ставлю шаблонизатор страницы"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
python3 -c 'import jinja2' 2>/dev/null || apt-get -o DPkg::Lock::Timeout=300 install -y -q python3-jinja2 rsync >/dev/null
echo "Готово."

say "2/4 Связь с CRM"
if [ -f "$ETC/site.env" ]; then
  echo "Сайт уже подключён к CRM. Чтобы ввести токен заново: rm $ETC/site.env и запустите скрипт ещё раз."
else
  echo "В CRM: Сайт → Подключить сайт (код «$SITE_KEY») — CRM покажет токен."
  read -rp "Токен сайта (пусто — пропустить, страница останется из репозитория): " SITE_TOKEN
  SITE_TOKEN=$(printf '%s' "$SITE_TOKEN" | tr -d '[:space:]')
  if [ -n "$SITE_TOKEN" ]; then
    (umask 077; printf 'CRM_API=%s\nSITE_KEY=%s\nSITE_TOKEN=%s\n' "$CRM_API" "$SITE_KEY" "$SITE_TOKEN" > "$ETC/site.env")
    if python3 "$REPO/site/build.py" sync --out /var/www/graveangels --order-endpoint auto --force; then
      echo "CRM приняла описание блоков — в CRM появилась кнопка «Редактировать»."
    else
      rm -f "$ETC/site.env"
      fail "CRM не приняла токен или недоступна (адрес $CRM_API). Проверьте код сайта и токен и запустите скрипт ещё раз."
    fi
  fi
fi

if grep -qs '^CRM_FORM_URL=' "$ETC/orders.env"; then
  echo "Заказы уже идут в CRM."
else
  echo
  echo "В CRM: Настройки → Заявки с сайта → создайте форму → «Подключить» → скопируйте «Ссылку на форму»."
  read -rp "Ссылка на форму или её ключ (пусто — заказы только в Telegram): " FORM_KEY
  FORM_KEY=$(printf '%s' "$FORM_KEY" | grep -oE '[a-f0-9]{32}' | tail -1 || true)
  if [ -n "$FORM_KEY" ]; then
    curl -fsS -o /dev/null --max-time 15 "$CRM_API/public/forms/$FORM_KEY" || fail "CRM не нашла форму с таким ключом"
    (umask 077; printf 'CRM_FORM_URL=%s/public/forms/%s\n' "$CRM_API" "$FORM_KEY" >> "$ETC/orders.env")
    echo "Заказы будут приходить и в CRM."
  fi
fi

say "3/4 Сервисы"
cat > "$APP/update.sh" <<'UPDEOF'
# Обновить сайт с GitHub: bash /opt/graveangels/update.sh
set -euo pipefail
REPO=/opt/graveangels/repo
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" fetch -q --depth 1 origin main
  git -C "$REPO" reset -q --hard origin/main
else
  git clone -q --depth 1 https://github.com/andreym79/kladbishe.git "$REPO"
fi
exec bash "$REPO/deploy/update.sh"
UPDEOF

cat > /etc/systemd/system/graveangels-orders.service <<'UNITEOF'
[Unit]
Description=graveangels.ru orders -> Telegram and CRM
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/graveangels/orders.env
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 /opt/graveangels/repo/server/orders.py
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

cat > /etc/systemd/system/graveangels-site.service <<'UNITEOF'
[Unit]
Description=graveangels.ru: published page from the CRM
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/graveangels/repo/site/build.py sync --out /var/www/graveangels --order-endpoint auto
Environment=PYTHONDONTWRITEBYTECODE=1
StateDirectory=graveangels
ProtectSystem=strict
ReadWritePaths=/var/www/graveangels
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
UNITEOF

cat > /etc/systemd/system/graveangels-site.timer <<'UNITEOF'
[Unit]
Description=graveangels.ru: check the CRM for a new version every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNITEOF

systemctl daemon-reload
rm -f "$APP/orders.py"   # the service now runs from the repository
if [ -f "$ETC/orders.env" ]; then
  systemctl enable -q graveangels-orders
  systemctl restart graveangels-orders
fi
if [ -f "$ETC/site.env" ]; then
  systemctl enable -q --now graveangels-site.timer
  echo "Сайт проверяет CRM раз в минуту."
else
  systemctl disable -q --now graveangels-site.timer 2>/dev/null || true
fi

# фото из CRM (media/<id>-<ширина>.webp) не меняются — браузер может хранить их год
NGX=/etc/nginx/sites-available/graveangels
if [ -f "$NGX" ] && ! grep -q 'location /media/' "$NGX"; then
  cp "$NGX" "$NGX.bak"
  python3 - "$NGX" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
block = """    location /media/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

"""
anchor = "    location = /api/order {"
if anchor in s:
    open(p, "w").write(s.replace(anchor, block + anchor, 1))
PY
  if nginx -t -q 2>/dev/null; then systemctl reload nginx; else cp "$NGX.bak" "$NGX"; echo "nginx не принял настройку кэша фото — оставил как было"; fi
fi

say "4/4 Собираю страницу"
bash "$APP/update.sh"

say "Готово"
[ -f "$ETC/site.env" ] && echo "Страница: из CRM (публикуйте изменения кнопкой «Опубликовать»)" || echo "Страница: из репозитория"
grep -qs '^CRM_FORM_URL=' "$ETC/orders.env" && echo "Заказы: в CRM$(grep -qs '^BOT_TOKEN=' "$ETC/orders.env" && echo ' и в Telegram')" || echo "Заказы: в Telegram"
