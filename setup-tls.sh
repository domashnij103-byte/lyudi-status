#!/usr/bin/env bash
# =============================================================================
# «Люди» — HTTPS-сертификат lyudi.app + *.lyudi.app через DNS-01 (Cloudflare).
#
# Зачем: Let's Encrypt проверяет HTTP-01 из нескольких стран, а зарубежный
# трафик к российскому серверу часто режется → «secondary validation: timeout».
# DNS-01 проверяет TXT-запись в Cloudflare и от доступности сервера не зависит.
#
# Запуск от root:  bash setup-tls.sh
# Спросит Cloudflare API-токен (права Zone → DNS → Edit на зону lyudi.app),
# сохранит его в /root/.secrets/cloudflare.ini (600) и больше не спросит.
# Продление — systemd-таймер certbot; после продления Caddy перезапускается.
# Повторный запуск безопасен.
# =============================================================================
set -euo pipefail

APP_DIR="/home/lyudi/ludi"
COMPOSE="docker compose --env-file .env.production -f docker-compose.vm.yml"
CF_INI="/root/.secrets/cloudflare.ini"
LOG=/root/setup-tls.log
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "!!! ОШИБКА: $*"; echo "!!! Пришлите: tail -40 ${LOG}"; exit 1; }
[ "$(id -u)" = 0 ] || die "запустите от root"

echo "=== 1/4 certbot + плагин Cloudflare"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null || die "не установился certbot"
certbot --version

echo "=== 2/4 Токен Cloudflare"
if [ ! -s "$CF_INI" ]; then
  echo "Вставьте Cloudflare API-токен и нажмите Enter. Символы не отображаются:"
  read -rs CF_TOKEN; echo
  # Веб-консоли оборачивают вставку в ESC[200~…ESC[201~ (bracketed paste) —
  # убираем эти маркеры и пробелы, иначе Cloudflare ответит 6003.
  CF_TOKEN="$(printf '%s' "$CF_TOKEN" | tr -d '\033' | sed 's/\[20[01]~//g' | tr -d '[:space:]')"
  [ -n "$CF_TOKEN" ] || die "токен пустой"
  install -d -m 700 /root/.secrets
  umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$CF_INI"; chmod 600 "$CF_INI"
  unset CF_TOKEN
fi
sed -i 's/\x1b//g; s/\[20[01]~//g; s/[[:space:]]*$//' "$CF_INI"
if ! curl -s -m 20 -H "Authorization: Bearer $(sed 's/^.* = //' "$CF_INI")" \
    https://api.cloudflare.com/client/v4/user/tokens/verify | grep -q '"status":"active"'; then
  rm -f "$CF_INI"
  die "Cloudflare не принял токен. Запустите скрипт ещё раз и вставьте API Token (не Global API Key)"
fi
echo "Токен Cloudflare принят."

echo "=== 3/4 Выпуск сертификата (1–2 минуты)"
certbot certonly --non-interactive --agree-tos -m admin@lyudi.app \
  --dns-cloudflare --dns-cloudflare-credentials "$CF_INI" --dns-cloudflare-propagation-seconds 30 \
  --cert-name lyudi.app -d lyudi.app -d '*.lyudi.app' --keep-until-expiring \
  || die "сертификат не выпущен (проверьте права токена: Zone → DNS → Edit для lyudi.app)"
# Caddy в контейнере работает не от root — даём читать ключ.
chmod 755 /etc/letsencrypt/live /etc/letsencrypt/archive
chmod 644 /etc/letsencrypt/archive/lyudi.app/privkey*.pem
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-caddy.sh <<EOF
#!/bin/sh
chmod 644 /etc/letsencrypt/archive/lyudi.app/privkey*.pem
cd ${APP_DIR} && ${COMPOSE} restart caddy
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/restart-caddy.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

echo "=== 4/4 Caddy читает этот сертификат"
cd "$APP_DIR"
python3 - <<'PY'
import re
p = "infra/caddy/Caddyfile"
s = open(p, encoding="utf-8").read()
if "(lyudi_tls)" not in s:
    s = s.replace("\temail admin@lyudi.app\n}\n",
        "\temail admin@lyudi.app\n}\n\n(lyudi_tls) {\n\ttls /etc/letsencrypt/live/lyudi.app/fullchain.pem /etc/letsencrypt/live/lyudi.app/privkey.pem\n}\n", 1)
    for head in ("lyudi.app, www.lyudi.app, app.lyudi.app {", "api.lyudi.app {", "livekit.lyudi.app {"):
        s = s.replace(head + "\n", head + "\n\timport lyudi_tls\n", 1)
    open(p, "w", encoding="utf-8").write(s)
p = "docker-compose.vm.yml"
s = open(p, encoding="utf-8").read()
if "/etc/letsencrypt:/etc/letsencrypt" not in s:
    s = s.replace("      - caddy_config:/config\n", "      - caddy_config:/config\n      - /etc/letsencrypt:/etc/letsencrypt:ro\n", 1)
    open(p, "w", encoding="utf-8").write(s)
print("Caddyfile и docker-compose обновлены")
PY
$COMPOSE up -d --no-build caddy
sleep 5
for h in lyudi.app api.lyudi.app livekit.lyudi.app; do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' --resolve "${h}:443:127.0.0.1" "https://${h}/" || true)
  echo "  https://${h}/ → ${code}"
done
echo
echo "ГОТОВО. Сертификат действует до: $(openssl x509 -enddate -noout -in /etc/letsencrypt/live/lyudi.app/fullchain.pem | cut -d= -f2)"
