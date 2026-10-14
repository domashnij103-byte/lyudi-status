#!/usr/bin/env bash
# =============================================================================
# «Люди» — развёртывание прода на чистом сервере (Ubuntu 22.04), запуск от root.
#
#   1. Положите файл настроек в /root/.env.production (nano, вставить, сохранить).
#   2. bash deploy.sh   — спросит GitHub-токен (только чтение) и сделает всё сам.
#
# Секреты скрипт не печатает. Можно запускать повторно: шаги идемпотентны.
# Полный журнал: /root/deploy.log
# =============================================================================
set -euo pipefail

REPO="github.com/domashnij103-byte/lyudi.git"
BRANCH="feat/themes-ads-channels"
APP_USER="lyudi"
APP_DIR="/home/${APP_USER}/ludi"
ENV_SRC="/root/.env.production"
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINjlkFXzjda7ngxlGjG0S84CwxMIrW04x3PzPjYknNwu lyudi"
COMPOSE="docker compose --env-file .env.production -f docker-compose.vm.yml"
LOG=/root/deploy.log

step() { echo; echo "=== [$(date +%H:%M:%S)] $* ==="; }
die()  { echo; echo "!!! ОШИБКА: $*"; echo "!!! Пришлите последние строки: tail -40 ${LOG}"; exit 1; }

exec > >(tee -a "$LOG") 2>&1

[ "$(id -u)" = 0 ] || die "запустите от root"
PUBLIC_IP="$(curl -4 -s -m 10 https://ifconfig.me || hostname -I | awk '{print $1}')"
echo "Публичный IP сервера: ${PUBLIC_IP}"

# ─── 0. Файл настроек ────────────────────────────────────────────────────────
step "0/9 Проверяю файл настроек"
ENV_FILE="$ENV_SRC"
[ -f "$ENV_FILE" ] || ENV_FILE="${APP_DIR}/.env.production"
[ -f "$ENV_FILE" ] || die "нет ${ENV_SRC}. Создайте: nano ${ENV_SRC}, вставьте содержимое .env.production, Ctrl+O, Enter, Ctrl+X"
sed -i 's/\r$//' "$ENV_FILE"   # на случай переводов строк Windows
for k in POSTGRES_PASSWORD REDIS_PASSWORD JWT_SECRET DATABASE_URL S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET_FILES LIVEKIT_API_KEY LIVEKIT_API_SECRET; do
  grep -qE "^${k}=.+" "$ENV_FILE" || die "в файле настроек нет параметра ${k} (файл вставлен не целиком?)"
done
echo "Файл настроек: $(grep -cE '^[A-Z0-9_]+=' "$ENV_FILE") параметров, обязательные на месте."

# ─── 1. Пользователь и SSH ───────────────────────────────────────────────────
step "1/9 Пользователь ${APP_USER} и вход только по ключу"
id "$APP_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$APP_USER"
install -d -m 700 -o "$APP_USER" -g "$APP_USER" "/home/${APP_USER}/.ssh"
grep -qF "$PUBKEY" "/home/${APP_USER}/.ssh/authorized_keys" 2>/dev/null || echo "$PUBKEY" >> "/home/${APP_USER}/.ssh/authorized_keys"
chown "$APP_USER:$APP_USER" "/home/${APP_USER}/.ssh/authorized_keys"; chmod 600 "/home/${APP_USER}/.ssh/authorized_keys"
echo "${APP_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"; chmod 440 "/etc/sudoers.d/90-${APP_USER}"
cat > /etc/ssh/sshd_config.d/20-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
systemctl reload ssh || systemctl restart ssh

# ─── 2. Swap (сборка Next.js на 4 ГБ RAM) ────────────────────────────────────
step "2/9 Файл подкачки 4 ГБ"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -m | sed -n 1,3p

# ─── 3. Docker ───────────────────────────────────────────────────────────────
step "3/9 Устанавливаю Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git ufw docker.io >/dev/null
apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
if ! docker compose version >/dev/null 2>&1; then
  # Плагин compose вручную (если в репозиториях нет пакета).
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL -m 120 "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose || die "не удалось скачать docker compose"
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi
# Docker Hub из РФ ограничен — тянем образы через зеркала.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://dockerhub.timeweb.cloud", "https://mirror.gcr.io"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" }
}
EOF
systemctl enable docker >/dev/null 2>&1; systemctl restart docker
usermod -aG docker "$APP_USER"
docker --version; docker compose version
docker pull -q node:20-alpine >/dev/null || die "не скачивается образ node:20-alpine (зеркала Docker Hub недоступны)"
echo "Образы Docker скачиваются."

# ─── 4. Код ──────────────────────────────────────────────────────────────────
step "4/9 Скачиваю код из GitHub"
if [ ! -d "${APP_DIR}/.git" ]; then
  echo "Вставьте GitHub-токен (только чтение) и нажмите Enter. Символы не отображаются:"
  read -rs GH_TOKEN; echo
  [ -n "$GH_TOKEN" ] || die "токен пустой"
  sudo -u "$APP_USER" git clone -q --depth 1 --branch "$BRANCH" "https://x-access-token:${GH_TOKEN}@${REPO}" "$APP_DIR" \
    || die "не удалось скачать код (проверьте токен и доступ к репозиторию lyudi)"
  sudo -u "$APP_USER" git -C "$APP_DIR" remote set-url origin "https://${REPO}"   # токен в .git не храним
  unset GH_TOKEN
fi
echo "Код: $(sudo -u "$APP_USER" git -C "$APP_DIR" log --oneline -1)"

# Файл настроек → в проект
if [ "$ENV_FILE" = "$ENV_SRC" ]; then
  install -m 600 -o "$APP_USER" -g "$APP_USER" "$ENV_SRC" "${APP_DIR}/.env.production"
  shred -u "$ENV_SRC" 2>/dev/null || rm -f "$ENV_SRC"
fi
# Старый IP (Яндекс) → новый, если где-то упоминается
sed -i "s/158\.160\.32\.11/${PUBLIC_IP}/g" "${APP_DIR}/.env.production" "${APP_DIR}/infra/livekit/livekit.yaml"
grep -n "node_ip" "${APP_DIR}/infra/livekit/livekit.yaml"

# ─── 5. Фаервол ──────────────────────────────────────────────────────────────
step "5/9 Фаервол"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
for p in 22 2222 8022 8443 80 443 7881; do ufw allow "${p}/tcp" >/dev/null; done
ufw allow 50000:50100/udp >/dev/null
ufw allow from 172.16.0.0/12 to any port 7880 proto tcp >/dev/null   # Caddy (docker) → LiveKit (host)
ufw --force enable >/dev/null
ufw status | head -20

# ─── 6. Сборка ───────────────────────────────────────────────────────────────
step "6/9 Собираю образы (10–25 минут)"
cd "$APP_DIR"
$COMPOSE --profile migrate build migrate api web || die "сборка не удалась"

# ─── 7. База ─────────────────────────────────────────────────────────────────
step "7/9 База данных: запуск, миграции, справочники"
$COMPOSE up -d postgres redis
for i in $(seq 1 30); do $COMPOSE exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER"' >/dev/null 2>&1 && break; sleep 2; done
$COMPOSE --profile migrate run --rm migrate || die "миграции не прошли"

# ─── 8. Запуск ───────────────────────────────────────────────────────────────
step "8/9 Запускаю сервис"
$COMPOSE up -d --no-build caddy api web livekit
echo "Жду запуска API…"
for i in $(seq 1 40); do
  $COMPOSE exec -T api wget -q -O /dev/null http://localhost:3001/v1/health 2>/dev/null && { echo "API: OK"; break; }
  sleep 3
done
$COMPOSE ps --format '{{.Service}}: {{.Status}}'

# ─── 9. Ежедневные копии базы ────────────────────────────────────────────────
step "9/9 Ежедневная копия базы (на сервер + в Object Storage)"
cat > "/home/${APP_USER}/backup.sh" <<'EOF'
#!/usr/bin/env bash
# Копия базы «Люди»: локально (14 дней) + в Object Storage (backups/).
set -euo pipefail
cd /home/lyudi/ludi
C="docker compose --env-file .env.production -f docker-compose.vm.yml"
D=/home/lyudi/backups; mkdir -p "$D"
F="$D/lyudi_$(date +%F_%H%M).sql.gz"
$C exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > "$F"
$C exec -T api node -e '
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const chunks = []; process.stdin.on("data", (c) => chunks.push(c)).on("end", async () => {
  const s3 = new S3Client({ endpoint: process.env.S3_ENDPOINT, region: process.env.S3_REGION,
    forcePathStyle: (process.env.S3_FORCE_PATH_STYLE ?? "true") === "true",
    credentials: { accessKeyId: process.env.S3_ACCESS_KEY_ID, secretAccessKey: process.env.S3_SECRET_ACCESS_KEY } });
  await s3.send(new PutObjectCommand({ Bucket: process.env.S3_BUCKET_FILES, Key: "backups/" + process.argv[1],
    Body: Buffer.concat(chunks), ContentType: "application/gzip" }));
  console.log("uploaded backups/" + process.argv[1]);
});' "$(basename "$F")" < "$F"
find "$D" -name 'lyudi_*.sql.gz' -mtime +14 -delete
echo "backup ok: $F ($(du -h "$F" | cut -f1))"
EOF
chmod 750 "/home/${APP_USER}/backup.sh"; chown "$APP_USER:$APP_USER" "/home/${APP_USER}/backup.sh"
echo "17 3 * * * ${APP_USER} /home/${APP_USER}/backup.sh >> /home/${APP_USER}/backup.log 2>&1" > /etc/cron.d/lyudi-backup
sudo -u "$APP_USER" "/home/${APP_USER}/backup.sh" || echo "!!! первая копия не удалась — разберёмся отдельно"

echo
echo "=================================================================="
echo " ГОТОВО. Сервис запущен на ${PUBLIC_IP}."
echo " Сертификаты HTTPS появятся сами после смены записей в Cloudflare."
echo " Пришлите Claude последние ~30 строк вывода (там нет секретов)."
echo "=================================================================="
