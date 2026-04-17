# YC Watchdog — автостарт и рестарт VM в Yandex Cloud

Проект реализует watchdog для виртуальной машины в Yandex Cloud.

## Что делает
- Проверяет доступность `TARGET_IP:PORT`.
- Делает несколько попыток проверки.
- При недоступности:
  - запускает ВМ (`start`), если она остановлена;
  - перезапускает ВМ (`restart`), если статус `RUNNING`, но сервис недоступен.
- Запускается по расписанию через `systemd timer`.

## Как работает
`systemd timer` → `systemd service` → `yc_autostart.sh` → проверка порта → IAM token → Compute API → `start/restart`

## Структура
```text
/opt/yc-watchdog/
  yc_autostart.sh
  get_iam_token.py
  authorized_key.json

/etc/systemd/system/
  yc-watchdog.service
  yc-watchdog.timer
```

## Установка зависимостей
```bash
sudo apt update
sudo apt install -y python3 python3-pip curl jq netcat-openbsd util-linux
sudo pip3 install PyJWT cryptography requests
```

## Настройка
Переопределите переменные окружения или отредактируйте значения по умолчанию в `yc_autostart.sh`:

```bash
export INSTANCE_ID="..."
export TARGET_IP="..."
export PORT=443
```

## Запуск
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now yc-watchdog.timer
```

## Проверка
```bash
sudo /opt/yc-watchdog/yc_autostart.sh
sudo tail -n 50 /var/log/yc-watchdog.log
```

## Cooldown
По умолчанию:
```bash
ACTION_COOLDOWN=900
```

## Логи
```bash
journalctl -u yc-watchdog.service
journalctl -u yc-watchdog.timer
```
