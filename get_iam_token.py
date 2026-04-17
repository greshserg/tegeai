#!/usr/bin/env python3

# Скрипт получает IAM token от Yandex Cloud
# по authorized_key.json сервисного аккаунта.
#
# Логика:
# 1. Читаем authorized_key.json
# 2. Собираем JWT
# 3. Подписываем JWT алгоритмом PS256
# 4. Отправляем JWT в IAM API
# 5. Получаем iamToken
# 6. Печатаем iamToken в stdout
#
# Этот скрипт НЕ стартует ВМ и НЕ проверяет порт.
# Он только получает IAM token для дальнейших API-запросов.

import json
import sys
import time

import jwt
import requests

# Путь к JSON-ключу сервисного аккаунта
KEY_PATH = "/opt/yc-watchdog/authorized_key.json"

# IAM endpoint Яндекс Клауда
IAM_URL = "https://iam.api.cloud.yandex.net/iam/v1/tokens"


def main() -> int:
    try:
        # Читаем authorized_key.json
        with open(KEY_PATH, "r", encoding="utf-8") as f:
            key = json.load(f)

        # Текущее время в Unix timestamp
        now = int(time.time())

        # Поля JWT по требованиям Yandex Cloud
        payload = {
            "aud": IAM_URL,                        # кому адресован JWT
            "iss": key["service_account_id"],     # ID сервисного аккаунта
            "iat": now,                           # время выпуска
            "exp": now + 3600,                    # срок жизни JWT = 1 час
        }

        # Создаём и подписываем JWT алгоритмом PS256
        encoded_jwt = jwt.encode(
            payload,
            key["private_key"],
            algorithm="PS256",
            headers={"kid": key["id"]},           # ID ключа
        )

        # Отправляем JWT в IAM API и просим выдать iamToken
        resp = requests.post(
            IAM_URL,
            json={"jwt": encoded_jwt},
            timeout=20,
        )

        # Если HTTP-код неуспешный — кидаем исключение
        resp.raise_for_status()

        data = resp.json()
        iam_token = data.get("iamToken")

        # Если токен почему-то не пришёл — печатаем ответ как ошибку
        if not iam_token:
            print(resp.text, file=sys.stderr)
            return 1

        # Успех: печатаем IAM token в stdout
        print(iam_token)
        return 0

    except Exception as e:
        # Любую ошибку отправляем в stderr
        print(str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())