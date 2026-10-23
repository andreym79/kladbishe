# Донастройка уже установленного сервера: HTTP/2, долгий кэш шрифтов и фото,
# правильный тип файлов woff2, служебная папка deploy не публикуется на сайте.
# Запуск: bash /opt/graveangels/repo/deploy/server-tune.sh  (повторный запуск безопасен)
set -euo pipefail
CONF=/etc/nginx/sites-available/graveangels
UPD=/opt/graveangels/update.sh

cp "$CONF" "$CONF.bak"
python3 - "$CONF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('listen 443 ssl;', 'listen 443 ssl http2;')
s = s.replace("""    location /images/ {
        expires 7d;
    }
""", """    location /images/ {
        expires 30d;
    }

    location /fonts/ {
        types { font/woff2 woff2; }
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
""")
open(p, 'w').write(s)
PY
if nginx -t -q; then
  systemctl reload nginx
else
  cp "$CONF.bak" "$CONF"
  echo "ОШИБКА в настройках nginx, вернул прежние. Пришлите текст выше."
  exit 1
fi

grep -q -- '--exclude deploy' "$UPD" || sed -i "s/--exclude .nojekyll/--exclude .nojekyll --exclude deploy --exclude '*.sh'/" "$UPD"
rm -rf /var/www/graveangels/deploy
echo "Готово: HTTP/2 и кэш включены."
