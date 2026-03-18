# MeshChat — Полная инструкция

---

## Шаг 1 — Установка Flutter

Скачай Flutter SDK: https://docs.flutter.dev/get-started/install/windows/desktop
Распакуй в `C:\flutter` (без пробелов в пути, НЕ в Program Files).

Добавь в PATH:
  Win+S → "переменные среды" → Path → Создать → `C:\flutter\bin` → OK

Проверь в новом терминале:
```
flutter --version
```

Установи Android Studio (нужен только для SDK): https://developer.android.com/studio
После установки: More Actions → SDK Manager → убедись что Android SDK 33+ есть.

Прими лицензии:
```
flutter doctor --android-licenses
```
Жми y на всё.

Проверь итог:
```
flutter doctor
```
Нужны галочки напротив Flutter, Windows Version, Android toolchain.

---

## Шаг 2 — VS Code расширения

Extensions (Ctrl+Shift+X) → установи: Flutter (от Dart Code)
Dart установится автоматически.

---

## Шаг 3 — Открыть проект

Распакуй mesh_chat.zip, например в C:\Projects\mesh_chat
VS Code → File → Open Folder → выбери mesh_chat

В терминале (Ctrl+`):
```
flutter pub get
```

---

## Шаг 4 — GitHub репозиторий

Создай приватный репо на GitHub, затем:
```
git init
git add .
git commit -m "initial commit"
git remote add origin git@github.com:MihailKashintsev/mesh_chat.git
git push -u origin main
```

Settings → Secrets and variables → Actions → добавь:

| Секрет            | Значение |
|-------------------|----------|
| UPDATE_PAT        | Fine-grained PAT: Contents Read-only |
| KEYSTORE_BASE64   | keystore в base64 (см. Шаг 5) |
| KEYSTORE_PASSWORD | пароль keystore |
| KEY_PASSWORD      | пароль ключа |
| KEY_ALIAS         | например: meshchat |

---

## Шаг 5 — Keystore для подписи APK (RuStore)

Создай keystore (один раз):
```
keytool -genkey -v -keystore meshchat.jks -keyalg RSA -keysize 2048 -validity 10000 -alias meshchat
```

Закодируй для GitHub (PowerShell):
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("meshchat.jks")) | Set-Clipboard
```
Вставь результат как KEYSTORE_BASE64.

В android/app/build.gradle добавь signing config (см. документацию Flutter signing).

---

## Шаг 6 — Запуск на устройстве

Телефон: Настройки → О телефоне → Номер сборки (7 раз) → Для разработчиков → Отладка по USB
Подключи USB → в VS Code внизу выбери устройство → F5

---

## Шаг 7 — Релиз

```powershell
.\release.ps1 1.0.0
```

Через ~10 минут в GitHub Releases появятся:
- mesh_chat_v1.0.0_rustore.aab  → загружай в RuStore
- mesh_chat_v1.0.0_android.apk  → для ручной установки
- mesh_chat_v1.0.0_windows.zip  → Windows с автообновлением
- mesh_chat_v1.0.0_macos.zip    → macOS с автообновлением

---

## Шаг 8 — RuStore

1. Зарегистрируйся: https://dev.rustore.ru
2. Создай приложение → загрузи .aab
3. Описание, скриншоты → модерация

При следующих релизах просто загружай новый .aab.
Пользователи Windows получают обновление прямо в приложении.
