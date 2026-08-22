# prediction-protocol

[![release](https://img.shields.io/github/v/release/umar-s/prediction-protocol?display_name=tag&sort=semver)](https://github.com/umar-s/prediction-protocol/releases)
[![check](https://github.com/umar-s/prediction-protocol/actions/workflows/check.yml/badge.svg)](https://github.com/umar-s/prediction-protocol/actions/workflows/check.yml)

Прогноз до действия — плагин для Claude Code. Хук `PreToolUse` отказывает
необратимым shell-командам — миграции, force-push, merge, deploy, рестарт,
удалённое исполнение, мутирующий HTTP, права и секреты, рекурсивное
удаление, — пока у сессии нет **receipt** на эту точную команду: гипотеза,
команда измерения и фальсифицируемое утверждение, записанные до действия.
CLI `predict` открывает receipt, сам исполняет измерение и ставит вердикт
**HIT / MISS / INCONCLUSIVE** в журнал с леджером опровергнутых убеждений.
Промах останавливает пачку. Самогрейдинга нет.

Идея — из скилла для ARC-AGI-3, который отказывался отправить действие без
письменного прогноза следующего кадра и грейдил его кодом. Наш мир
недетерминирован и наблюдаем частично, поэтому единица здесь не «следующий
кадр», а **измерение с командой** — прогноз без команды это намерение.

## Как это работает

```
predict on DEV-512                      # сессия под протоколом; selftest печатает predict-gate: active v1.0.0
predict open --action 'alembic upgrade head' \
  --hypothesis '0042 добавляет индекс, не трогая строки' \
  --observe "psql -tAc 'select count(*) from orders'" --expect 'count=10422'
alembic upgrade head                    # гейт сверяет команду с receipt → в промпте разрешения виден прогноз
predict close 3f9a1c20-1                # исполняет измерение, ставит вердикт, дописывает docs/evidence/DEV-512.md
predict report                          # predictions: 1 HIT / 0 MISS / 0 INCONCLUSIVE / 0 bypass / 0 open · …
```

Без receipt команда получает **deny** — JSON-отказ на stdout и причина на
stderr с exit 2, чтобы дефект одного канала никогда не стал разрешением, —
с точным рецептом `predict open …` в причине. Вне протокола (не было `predict on`) необратимая команда получает
**ask** — правило владельца «спрашивай только при необратимом» как механизм,
а не проза. В headless-прогоне гейт молчит вне протокола и отказывает внутри.
Субагенты необратимых дверей не открывают: им велено отчитаться о команде как
о находке.

| | вне протокола | под протоколом, без receipt | receipt совпал |
|---|---|---|---|
| интерактив | ask | deny + рецепт | ask, прогноз в промпте |
| субагент | ask | deny: отчитаться как о находке | deny |
| headless (`claude -p`) | молчит | deny + рецепт | молчит |

**MISS** (подтверждённый вторым измерением, оба записаны) останавливает все
необратимые действия, пока `predict ack <id> --refuted '…' --where '…'` не
назовёт убеждение и где оно держалось, и не запишет его в
`docs/evidence/REFUTED.md` — файл, который следующая сессия читает до того,
как трогать те же пути; ничто другое этот halt не снимает. **INCONCLUSIVE**
(измерение не отработало чисто или мигает) останавливает так же — до
`predict retry` (повторное измерение) или `predict withdraw`. Один receipt —
один вызов инструмента: гейт помечает его потреблённым, PostToolUse-хук —
исполненным, и `close` отказывает receipt'у, действие которого не выполнилось.
`predict off --reason '…'` — обход: записан в журнал как `bypass`, никогда не
спрятан.

## Что гейтится

Класс вычисляется по строке команды по глаголу после снятия `sudo`, `env`,
`VAR=…`, `time`, `timeout`, `xargs` и глобальных опций инструмента (`git -C`,
`kubectl -n`, `aws --profile`), разбиения по `;`, `&&`, `||`, `|`, `&` и
переводам строки вне кавычек, выбрасывания тел heredoc и извлечения `$(…)`;
`bash -c`, `su -c` и `eval` разворачиваются, shell'ы и интерпретаторы с вводом
из stdin — непрозрачные исполнители, слипшиеся флаги (`psql -tAc`, `curl -sX`)
читаются, dry-run и `--help` проходят. Запуск миграций (alembic, rails db:, artisan, prisma,
flyway, liquibase, manage.py, goose, …); SQL/KV-клиенты с записью, вводом из
`-f`/`<`/heredoc или из pipe; `git push --force*`/`--delete`, `branch -D`,
`gh pr merge`, `glab mr merge`, `gh release create`; `kubectl`, `helm`,
`terraform`, `pulumi`, `docker rm|prune|down`, `systemctl restart|stop`,
`pm2`; `ssh host <cmd>`, `docker|kubectl exec`; `curl`/`http`/`wget` с
мутирующим методом или телом не на localhost; мутации `aws`/`gcloud`/`az`/
`vault`/`gh secret`; `npm publish`, `twine upload`, `docker push`; `rm -r`
вне `/tmp`, `find -delete`, `dd of=/dev/`, `mkfs`. Read-only команды, тесты,
сборка, линт, обычный `git push`, `git reset --hard`, `rm` в `/tmp` проходят.
Обёртки проекта (`make deploy`) объявляются через `predict on --also`; вызовы
самого `predict` не классифицируются никогда; записи в собственное состояние
протокола — классифицируются. Корпуса в `tests/corpus/` — это контракт
(`classify-corpus.sh` печатает счётчик).

## Fail-closed — структурно

Платформа fail-open: хук, который вышел с кодом 1, напечатал битый JSON или
превысил таймаут, пропускает команду (проверено на Claude Code 2.1.239,
`tests/platform-probe.sh`). Поэтому у гейта есть внешняя обёртка, которой для
deny нужен только bash, префильтр словаря на чистом bash, `ERR`-trap,
отвечающий deny, внутренний дедлайн короче таймаута из `hooks.json` (GNU
`timeout`, `gtimeout` или bash-watchdog), экранирование каждого control-байта
в JSON, никакой сети — и он никогда не отвечает `allow`. Состояние receipt'ов
живёт вне репозитория в
`~/.local/state/prediction-protocol/sessions/<session_id>/`, по id сессии,
который платформа передаёт хуку (или по `PP_SESSION`, который runner
экспортирует вокруг `claude -p --session-id`) — без `TASK-ID`, без
зависимости от `cwd`, нечему случайно попасть в коммит, и модели нечего там
править: Edit/Write в этот каталог отказывает второй хук, записи через Bash
классифицируются.

## Структура

```
plugins/prediction-protocol/
  skills/prediction-protocol/SKILL.md        # протокол, область, три команды, дисциплина
  skills/prediction-protocol/references/journal.md          # утверждения, формат записи, REFUTED.md, строка report, lint
  skills/prediction-protocol/references/hook-engineering.md # факты платформы + чеклист для любого хука линейки
  hooks/hooks.json · hooks/predict-gate.sh   # гейт (matcher "Bash", timeout 15)
  hooks/predict-fired.sh                     # PostToolUse: помечает потреблённый receipt исполненным
  hooks/predict-state-guard.sh               # PreToolUse на Edit/Write: каталог состояния не редактируется
  hooks/session-env.sh                       # SessionStart: экспортирует PREDICT=<plugin>/bin/predict потребителям
  bin/predict                                # on | off | status | open | close | ack | retry | withdraw | report | lint | classify | selftest
  lib/classify.sh · lib/common.sh            # классификатор; состояние, утверждения, редакция
  tests/run.sh · tests/classify-corpus.sh · tests/platform-probe.sh · tests/corpus/
```

## Установка

```
/plugin marketplace add umar-s/devpowers
/plugin install prediction-protocol@devpowers
```

Linux, только инструмент `Bash`; `python3` или `jq` для разбора stdin хука
(нет ни того ни другого → необратимый вызов получает deny, никогда не
молчание); предпочтительно GNU `timeout` или `gtimeout`, иначе bash-watchdog.
macOS в 1.0 не тестировался (сьют идёт только на Linux CI). MCP-инструменты
и PowerShell вне 1.x — по объявлению.

## Потребители

- **task-flow `task`** — `predict on <TASK-ID>` в начале фазы 5 (строка
  `predict-gate: active` — доказательство), receipt'ы вокруг state-changing
  шагов реализации, один advisory-цикл на каждый `live`-пункт DoD в фазе 7,
  receipt'ы на merge и deploy в фазе 8 со строкой `predict report` в
  evidence-блоке, чтение `REFUTED.md` в фазе 0. Работает без плагина:
  строки печатают `predict-gate: absent`.
- **loop-foundry** — runner экспортирует один `PP_SESSION=<uuid>`, выполняет
  `predict on <loop> --loop`, затем `claude -p --session-id <uuid>`; `predict
  report --json` вливается в запись тика как второй сигнал на лестнице shadow
  → gated → autonomous, halt — стоп, исполняемый хуком.

## Проверки

```bash
bash scripts/lint.sh                                   # писаные правила как grep'ы: версии, matcher, trap, дедлайн, нет allow, пины SKILL/references, паритет README
bash plugins/prediction-protocol/tests/classify-corpus.sh   # контракт классификатора (одно- и многострочные корпуса)
bash plugins/prediction-protocol/tests/run.sh          # негативные контроли: таблица решений, жизненный цикл receipt, halt, редакция, lint, пути ошибок, корпуса через гейт
bash plugins/prediction-protocol/tests/platform-probe.sh   # через сам Claude Code; вручную, при релизе
claude plugin validate plugins/prediction-protocol
```

## Лицензия

MIT.
