# Mini CRM на этом же сервере (crm.graveangels.ru): готовые образы с GitHub и ограничения памяти — для сервера с 1 ГБ.
# Запуск: bash /opt/graveangels/repo/deploy/crm-install.sh      (повторный запуск — обновление CRM)
# Нужно заранее: DNS-запись crm.graveangels.ru → IP сервера и токен GitHub с правом read:packages.
set -euo pipefail

DOMAIN=${DOMAIN:-crm.graveangels.ru}
OWNER=${OWNER:-andreym79}
PREFIX=ghcr.io/$OWNER/minicrm
DIR=/opt/minicrm

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || fail "запустите от root"
command -v docker >/dev/null || fail "нет Docker"

if [ -f "$DIR/.env" ]; then
  say "CRM уже установлена — обновляю"
  cd "$DIR" && exec ./scripts/update.sh
fi

say "1/4 Проверяю сервер"
if ! docker compose version >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 install -y -q docker-compose-plugin >/dev/null || fail "не удалось поставить docker compose"
fi
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
DNS=$(getent ahostsv4 "$DOMAIN" | awk 'NR == 1 {print $1}' || true)
[ "$DNS" = "$IP" ] || fail "$DOMAIN указывает на «${DNS:-никуда}», а адрес сервера $IP. Добавьте в DNS (панель Beget) запись A: crm → $IP и подождите 10–15 минут."
echo "Домен $DOMAIN указывает на этот сервер."
FREE=$(df -Pm / | awk 'NR == 2 {print $4}')
[ "$FREE" -gt 3000 ] || fail "на диске свободно $FREE МБ, нужно хотя бы 3000"

say "2/4 Файл подкачки"
if [ -n "$(swapon --show --noheadings)" ]; then
  echo "Уже есть."
else
  fallocate -l 1536M /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Добавлен файл подкачки 1,5 ГБ."
fi

say "3/4 Скачиваю CRM с GitHub"
if ! docker pull -q "$PREFIX-bundle:latest" >/dev/null 2>&1; then
  echo "Нужен токен GitHub: github.com → Settings → Developer settings → Personal access tokens → Tokens (classic)"
  echo "→ Generate new token (classic), отметьте только read:packages."
  read -rp "Вставьте токен и нажмите Enter: " GH_TOKEN
  printf '%s' "$GH_TOKEN" | tr -d '[:space:]' | docker login ghcr.io -u "$OWNER" --password-stdin >/dev/null || fail "GitHub не принял токен"
  docker pull -q "$PREFIX-bundle:latest" >/dev/null || fail "образ $PREFIX-bundle не найден — проверьте, что сборка на GitHub (Actions → Images) прошла"
fi
mkdir -p "$DIR"
docker run --rm -v "$DIR:/out" "$PREFIX-bundle:latest"
echo "Файлы CRM — в $DIR"

say "4/4 Устанавливаю CRM"
read -rp "E-mail администратора CRM (это будет логин): " EMAIL
cd "$DIR"
./scripts/install.sh --domain "$DOMAIN" --email "$EMAIL" --images "$PREFIX" --small --yes
