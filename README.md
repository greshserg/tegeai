YC Watchdog — автостарт и рестарт VM в Yandex Cloud

Описание: Этот проект реализует watchdog для виртуальной машины в Yandex
Cloud.

Функции: - проверяет доступность сервера (IP:PORT) - делает несколько
попыток - при недоступности: - запускает ВМ (start), если она
остановлена - перезапускает (restart), если зависла - работает через
systemd timer

Как работает: systemd timer → service → скрипт → проверка порта → IAM
token → Compute API → start/restart

Структура: /opt/yc-watchdog/ yc_autostart.sh get_iam_token.py
authorized_key.json

/etc/systemd/system/ yc-watchdog.service yc-watchdog.timer

Установка: sudo apt update sudo apt install -y python3 python3-pip curl
jq netcat-openbsd util-linux sudo pip3 install PyJWT cryptography
requests

Настройка: INSTANCE_ID=“…” TARGET_IP=“…” PORT=443

Запуск: sudo systemctl daemon-reload sudo systemctl enable –now
yc-watchdog.timer

Проверка: sudo /opt/yc-watchdog/yc_autostart.sh tail -n 50
/var/log/yc-watchdog.log

Cooldown: ACTION_COOLDOWN=900

Логи: journalctl -u yc-watchdog.service journalctl -u yc-watchdog.timer
