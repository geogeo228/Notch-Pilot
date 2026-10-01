# Форк Георгия (ветка `georgi-hardened`)

Апстрим: https://github.com/devmegablaster/Notch-Pilot (remote `upstream`).

## Что изменено и зачем

| Было в апстриме | В форке |
|---|---|
| Читал OAuth-токен Claude Code из Keychain и ходил в `api.anthropic.com` за лимитами | `UsageAPI` — заглушка, всегда `.failed`; лимиты считаются по локальным jsonl |
| Раз в 30 мин стучался в GitHub за обновлениями; по кнопке качал DMG, снимал карантин, переподписывал | `UpdateChecker` — заглушка, сети нет |
| При нечитаемом `settings.json` перезаписывал его целиком | Не трогает файл, если не смог распарсить |
| Удалял любой чужой хук, оканчивающийся на ` --hook` | Удаляет только свои (`NotchPilot` в пути) |
| Писал `settings.json` без бэкапа и не атомарно | Бэкап `settings.json.bak-notchpilot` (один раз) + атомарная запись |
| «Always allow <Tool>» добавлял инструмент целиком (весь Bash) | Кнопка убрана |
| Глобальные ⌘. / ⌘, разрешали/отклоняли из любого приложения | ⌥⌘. / ⌥⌘, / ⌥⌘\ |
| `build.sh` импортировал самоподписанный сертификат в login keychain | Ad-hoc подпись, Keychain не трогается |
| Zed не знал | Zed добавлен в список терминалов |
| AskUserQuestion: только первый вопрос, один вариант, ответ через «deny» (в терминале «Denied by PermissionRequest hook») | Все вопросы пачки по очереди, мультивыбор, «Свой вариант…» с вводом текста; ответ штатно — allow + `answers` |
| Без live-лимитов пересчитывал 400+ МБ логов каждые 10 с (CPU 100%) | Пересчёт раз в 5 мин |
| «Start at login» через SMAppService — запуск БЕЗ песочницы | Отключено; автозапуск — LaunchAgent в песочнице |
| Хуки указывали в `dist/`, который стирается при сборке | Сборка ставит приложение в `~/Applications`, хуки смотрят туда |

В коде нет ни одного `URLSession`/`URLRequest`.

## Сборка и запуск

```sh
nice -n 10 scripts/build.sh      # собрать (только Command Line Tools) и поставить в ~/Applications
scripts/install-agent.sh         # один раз: автозапуск при входе, всегда в песочнице без сети
scripts/run-offline.sh           # перезапуск после пересборки
scripts/install-agent.sh --uninstall   # убрать автозапуск
```

Песочница — `scripts/sandbox.sb`: весь IP-трафик запрещён, unix-сокет хуков работает.

Плюс LuLu: если он когда-нибудь спросит про NotchPilot — значит, что-то пытается в сеть, блокировать.

## Подтянуть апстрим

```sh
git fetch upstream && git merge upstream/main   # и заново проверить на сеть: grep -rn URLSession Sources
```
