#!/bin/bash

# ------------ НАСТРОЙКИ ------------
DATABASE_HOST="192.168.1.1"
DATABASE_PORT="5432"
DATABASE_BACKUP_USER="postgres_backup_user"
DATABASE_BACKUP_USER_PASSWORD=""

BACKUP_DIR="/backups"
LOG_FILE="$(dirname "$0")/postgres_backup.log"
TEMP_DIR="/tmp/db_backup_$$"

# ------------ ФУНКЦИИ ------------
# Логирование ошибок одновременно в лог и в вывод
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Функция очистки: сработает всегда при выходе из скрипта
cleanup() {
    log "Очистка временных файлов..."
    rm -rf "$TEMP_DIR"
    unset PGPASSWORD
}

# Регистрируем cleanup на выход (EXIT) и прерывание (SIGINT, SIGTERM)
trap cleanup EXIT SIGINT SIGTERM

# ------------ ПОДГОТОВКА ------------
mkdir -p "$TEMP_DIR" "$BACKUP_DIR"

log "Запуск резервного копирования PostgreSQL"
export PGPASSWORD="$DATABASE_BACKUP_USER_PASSWORD"

# 1. Получаем список баз
DATABASES=$(psql -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_BACKUP_USER" -d postgres -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true" 2>&1)

if [ $? -ne 0 ]; then
    log "КРИТИЧЕСКАЯ ОШИБКА подключения или получения списка баз: $DATABASES"
    exit 1
fi

# ------------ ОСНОВНОЙ ЦИКЛ ------------
for DB in $DATABASES; do

    log "База: $DB - начинаем обработку"

    CURRENT_DB_DUMP_FILE="$TEMP_DIR/${DB}.sql"
    CURRENT_DB_ARCHIVE_FILE="$TEMP_DIR/${DB}_$(date +%Y%m%d_%H%M).sql.gz"

    # 1. Создание дампа
    if ! pg_dump -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_BACKUP_USER" -d "$DB" -f "$CURRENT_DB_DUMP_FILE" 2>/dev/null; then
        log "ОШИБКА: Не удалось создать дамп базы $DB"
        continue
    fi

    # 2. Сжатие
    if ! gzip -c "$CURRENT_DB_DUMP_FILE" > "$CURRENT_DB_ARCHIVE_FILE"; then
        log "ОШИБКА: Не удалось сжать дамп базы $DB"
        rm -f "$CURRENT_DB_DUMP_FILE" # Удаляем неудачный дамп сразу
        continue
    fi

    # 3. Проверка
    if ! gzip -t "$CURRENT_DB_ARCHIVE_FILE" 2>/dev/null; then
        log "ОШИБКА: Архив базы $DB повреждён"
        rm -f "$CURRENT_DB_DUMP_FILE" "$CURRENT_DB_ARCHIVE_FILE"
        continue
    fi

    # 4. Перенос
    if ! mv "$CURRENT_DB_ARCHIVE_FILE" "$BACKUP_DIR/"; then
        log "ОШИБКА: Не удалось перенести архив базы $DB"
        rm -f "$CURRENT_DB_DUMP_FILE" "$CURRENT_DB_ARCHIVE_FILE"
        continue
    fi

    # Удаляем временный .sql файл после успешного переноса архива
    rm -f "$CURRENT_DB_DUMP_FILE"
    log "Бэкап базы $DB успешно завершен и проверен"

done

log "Резервное копирование завершено"
log "---"
