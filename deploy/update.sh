# Обновить сайт после изменений на GitHub (вызывается из /opt/graveangels/update.sh, который сначала скачивает репозиторий).
# Файлы сайта → /var/www/graveangels, страница собирается из шаблонов: из CRM, если сайт к ней подключён, иначе из site/schema.json.
set -euo pipefail
APP=/opt/graveangels
REPO=$APP/repo
WEB=/var/www/graveangels

mkdir -p "$WEB"
# index.html собирает build.py, media/ — фото из CRM: их rsync не трогает
rsync -a --delete --chmod=D755,F644 \
  --exclude .git --exclude worker --exclude README.md --exclude .nojekyll --exclude deploy --exclude site --exclude server \
  --exclude '*.sh' --exclude index.html --exclude media \
  "$REPO/" "$WEB/"
rm -rf "$WEB/site" "$WEB/server" "$WEB/deploy"   # left by older versions of this script

EP=auto   # '/api/order' when the server forwards orders (orders.env), otherwise the form opens WhatsApp
if ! python3 -c 'import jinja2' 2>/dev/null; then
  echo "Нет python3-jinja2 — ставлю готовую страницу из репозитория"
  cp "$REPO/index.html" "$WEB/index.html"
elif [ -f /etc/graveangels/site.env ]; then
  python3 "$REPO/site/build.py" sync --out "$WEB" --order-endpoint "$EP" --force \
    || { [ -f "$WEB/index.html" ] && echo "CRM не ответила — на сайте остаётся прежняя версия страницы"; } \
    || python3 "$REPO/site/build.py" --out "$WEB" --order-endpoint "$EP"
else
  python3 "$REPO/site/build.py" --out "$WEB" --order-endpoint "$EP"
fi

# сервис заказов запускается прямо из репозитория — новая версия начинает работать после перезапуска
if systemctl is-enabled -q graveangels-orders 2>/dev/null; then systemctl restart graveangels-orders; fi
echo "Сайт обновлён: $(git -C "$REPO" log -1 --format='%h %s')"
