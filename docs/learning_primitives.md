# Learning Primitives — идеи для Sync/Async вертикали

*Март 2026 | Источники: анализ hermes-agent и cognithor, синтез с sync/async концепцией*

---

## TL;DR

Два проекта реализуют самообучение принципиально по-разному:
- **Hermes** — external RL pipeline (собирает trajectory data → fine-tuning вне агента). Внутри — только nudge-based skill creation.
- **Cognithor** — embedded multi-layer learning: reward calculator, causal analyzer, prompt evolution A/B, correction memory, skill success rate.

Для sync/async вертикали подходят cognithor-паттерны, адаптированные под "оператор в петле" философию. Главный инсайт: каждый из этих примитивов можно реализовать git-нативно — без отдельных БД.

---

## Три уровня обучения

```
Run-level      → что произошло в конкретном прогоне
Pattern-level  → паттерны поперёк прогонов (10-100 runs)
Policy-level   → как меняется поведение агента со временем
```

Ниже — идеи сгруппированы по уровням, с оценкой сложности и приоритетом.

---

## Run-level

### 1. Reflector — оценка прогона после завершения

**Источник:** cognithor `reflector.py` (36KB, LLM-based session evaluation)

После каждого agent run — небольшой LLM-вызов оценивает что произошло:

```
После завершения run:

Reflector prompt:
  "Оцени этот agent run по истории инструментов и результатов:
   1. success_score (0-5): насколько задача выполнена
   2. checkpoint_count: сколько раз агент остановился из-за неуверенности
   3. extracted_facts: что нового узнали о клиенте или домене
   4. skill_candidate: есть ли паттерн достойный кристаллизации в скилл?
   5. operator_needed: нужна ли CC-сессия — и почему?"

Результат → пишется в traces/{run_id}/reflection.yaml
```

Reflector — это автоматизированная версия анализа который оператор делает в CC-сессии. Не заменяет, но готовит материал.

**Почему это важно:** без structured reflection traces — просто логи. С reflection — каждый run создаёт сигнал который накапливается в паттерны.

**Сложность:** низкая. Один LLM-вызов после run, output в файл.

---

### 2. Skill fitness — git-native трекинг

**Источник:** cognithor `procedural.py` — EMA success rate влияет на skill selection score.

Не нужна отдельная БД. YAML frontmatter в каждом `SKILL.md`:

```yaml
---
name: site-builder
version: 3
success_count: 23
failure_count: 3
checkpoint_rate: 0.12   # checkpoint_count / total_decisions в прогонах где скилл использован
avg_score: 4.1          # EMA от reflector success_score
last_used: 2026-03-29
last_updated: 2026-03-28
---

# Site Builder

...инструкции...
```

После каждого run который использовал скилл — агент обновляет frontmatter → git commit. История fitness скилла живёт в git log.

**checkpoint_rate** — ключевая метрика. Низкий = высокая verbalizability = скилл хорошо вербализован. Высокий = скилл нуждается в улучшении → приоритет для следующей CC-сессии.

**Влияние на поведение:**
```python
# При выборе скилла в ContextBuilder
if skill.checkpoint_rate > 0.3:
    # помечаем как "требует внимания" в attention queue
if skill.avg_score < 2.5 and skill.success_count >= 5:
    # понижаем приоритет инъекции в промпт
```

**Сложность:** низкая. Агент уже пишет файлы — добавить update frontmatter.

---

### 3. Self-skill creator — автоматическая кристаллизация

**Источник:** hermes — nudge каждые 10 tool calls, background fork.

Адаптация под async nanobot: триггер — завершение agent run (не tool-call count).

```
Run завершён
    ↓
Если run_score > 3.5 И tool_calls > 8:
    Background review: "есть ли паттерн достойный скилла?"
    → пишет напрямую в skills/ (не draft)
    → git commit: "skill: auto-crystallized X from {client}/{run_id}"
    ↓
Следующая CC-сессия оператор видит новый коммит в git log
```

Вместо draft-папки — git diff как review механизм. Оператор видит что агент кристаллизовал, может принять (`git log`), отредактировать или откатить (`git revert`).

**Почему напрямую, не draft:** держит систему простой. Git history — натуральный audit trail. Если скилл плохой — видно по падению skill fitness.

**Сложность:** средняя. Нужен triggered background runner после run completion.

---

## Pattern-level

### 4. CorrectionMemory — коррекции оператора как сильнейший сигнал

**Источник:** cognithor `correction_memory.py` — хранит пользовательские коррекции, proactive asking после 3 похожих.

В sync/async контексте: коррекция — это CC-сессия в которой оператор редактирует скилл или AGENTS.md.

```markdown
# corrections.md (global/)

## 2026-03-28
- skill/site-builder: удалено "always include hero image"
  trigger: клиент TechStart пожаловался на load time
  pattern: hero-image-rule

## 2026-03-30
- skill/site-builder: снова удалено про hero image (восстановилось после auto-update)
  trigger: та же проблема у acme_corp
  pattern: hero-image-rule (2/3)
```

После 2+ коррекций с одним pattern-тегом → агент добавляет в attention queue: "скилл site-builder повторно откатывался по hero-image — приоритет для ревизии в CC-сессии."

Это делает feedback loop оператора измеримым: не просто "что-то правил", а "вот что правил снова и снова."

**Откуда берётся correction запись:** сам оператор добавляет после CC-сессии (2 строки), или CC автоматически при commit с определённым форматом.

**Сложность:** низкая. Один markdown файл + простой parser в attention queue.

---

### 5. Verbalizability score — измеримый flywheel

**Это новая идея — нет прямого аналога ни в hermes ни в cognithor.**

Метрика которая делает "verbalizability растёт" измеримым:

```
verbalizability_score(skill) = 1 - checkpoint_rate
verbalizability_score(client) = weighted avg по используемым скиллам
verbalizability_score(vertical) = avg по всем клиентам и скиллам
```

Трекинг во времени:
```yaml
# traces/{date}/vertical_metrics.yaml
date: 2026-03-30
vertical_verbalizability: 0.73  # растёт со временем
skills:
  site-builder: 0.88
  requirements-gathering: 0.65  # нуждается в работе
  moodboard-review: 0.41        # часто checkpoint → хороший кандидат для улучшения
```

**Что это даёт:**
- Видно на каком этапе/скилле оператор вмешивается чаще всего
- Можно ставить цели: "к концу месяца requirements-gathering > 0.8"
- Признак хорошей итерации: verbalizability растёт, operator involvement падает

**Сложность:** низкая если checkpoint_rate уже трекается в skill frontmatter.

---

### 6. CausalAnalyzer — корреляция tool-sequence и исхода

**Источник:** cognithor `causal.py` — записывает (tool_sequence, success_score), учится какие цепочки работают.

Упрощённая git-нативная версия:

В каждом trace записываем ordered список инструментов + score:

```yaml
# traces/{run_id}/trace.yaml
tool_sequence: [read_file, web_search, write_file, edit_file, write_file]
success_score: 4.5
skill_used: site-builder
```

После 20+ runs — анализ: какие subsequences коррелируют с высоким score?

Простой вариант: "read_file → write_file без web_search" → score 3.1 среднее. "read_file → web_search → write_file" → score 4.3 среднее.

Вывод попадает в AGENTS.md как hint: "для site-build фазы всегда начинай с чтения brief перед поиском референсов."

**Когда это полезно:** после 20+ agent runs. Не нужно раньше.

**Сложность:** средняя. Нужен скрипт анализа traces, запускается через CC.

---

## Policy-level

### 7. PromptEvolution — A/B тест версий скиллов

**Источник:** cognithor `prompt_evolution.py` — статистический A/B тест, LLM-генерация variant C если B побеждает.

При major update скилла (v1 → v2):

```yaml
# skills/site-builder/SKILL.md frontmatter
ab_test:
  active: true
  version_a: "v1"  # старый
  version_b: "v2"  # новый
  runs_a: 0
  runs_b: 0
  score_a: null
  score_b: null
  min_runs_to_decide: 10
```

Агент deterministически выбирает версию (hash от run_id → 50/50). После 10 runs на каждой — сравниваем средний score. Победитель становится основной версией, проигравший архивируется в git.

**Почему это важно:** делает "эта версия скилла лучше" эмпирическим фактом, а не интуицией оператора.

**Сложность:** средняя. Нужна логика выбора версии + сбор метрик.

---

### 8. Background Reactive Evolution — пробел → исследование → скилл

**Источник:** cognithor Evolution Engine (Scout → Research → Build → Reflect), адаптировано под reactive (не proactive).

Reactive версия — триггер из реального опыта, не из curiosity:

```
SessionAnalyzer (еженедельно):
    Смотрит на traces за неделю
    Ищет паттерн: "один и тот же checkpoint 3+ раза"
        ↓
    Формулирует gap: "агент не знает как выбирать шрифт под бренд"
        ↓
    Background research (idle time):
        web_search: "typography for brand identity principles"
        → кристаллизует в новый скилл или обновляет существующий
        → git commit + добавляет в attention queue для оператора
```

**Отличие от cognithor proactive:** нет CuriosityEngine. Источник всегда — реальный паттерн из traces. Меньше шума, больше relevance.

**Сложность:** высокая. Требует SessionAnalyzer + background runner + gap detection.

---

### 9. Trace как training data — проектируй с нуля правильно

**Источник:** hermes `batch_runner.py` — trajectory collection для fine-tuning. Не используется online.

Не нужно для fine-tuning сейчас. Но если trace format спроектирован правильно с первого дня — данные накапливаются сами.

Минимальный структурированный формат:

```jsonl
{"run_id":"...", "client_id":"acme", "turn": 1, "role":"user", "content":"..."}
{"run_id":"...", "client_id":"acme", "turn": 1, "role":"assistant", "content":"...", "tool_calls":[...]}
{"run_id":"...", "client_id":"acme", "turn": 1, "role":"tool", "tool_name":"write_file", "result":"...", "success":true}
{"run_id":"...", "meta": {"success_score": 4.2, "operator_corrections": 0, "skills_used": ["site-builder"]}}
```

После 100+ runs эти файлы — готовый датасет для SFT или preference learning.

**Сложность:** низкая если закладывать сразу. Высокая если переделывать потом.

---

## Идеи которые НЕ берём (и почему)

| Идея | Источник | Причина отказа |
|---|---|---|
| ResponseValidator (anti-hallucination) | cognithor | Добавляет latency, неясна ценность в вертикальном контексте |
| KnowledgeValidator | cognithor | Сложно, нужна web research инфраструктура |
| Hermes external RL training | hermes | Мы не fine-tuning модели |
| Proactive CuriosityEngine | cognithor | Риск шума без grounding в реальном опыте |
| SearchWeightOptimizer (BM25/vector) | cognithor | Нет vector search в нашей архитектуре |

---

## Приоритет реализации

```
Фаза 0 — закладываем фундамент
  ✓ Trace format — структурированный, extensible
  ✓ Reflector — LLM eval после каждого run
  ✓ Skill fitness frontmatter — success_count, checkpoint_rate, avg_score

Фаза 1 — после multi-tenant и первых 10+ runs
  ✓ CorrectionMemory — трекинг CC-сессий
  ✓ Verbalizability score — метрика flywheel
  ✓ Self-skill creator — auto-crystallization из run

Фаза 2 — после 50+ runs
  ✓ CausalAnalyzer — tool sequence корреляции
  ✓ PromptEvolution — A/B тест версий скиллов

Фаза 3 — если актуально
  ✓ Reactive Evolution — gap detection + background research
  ✓ Fine-tuning pipeline — если trace data накопились
```

---

## Ключевой принцип

Cognithor строит learning как инфраструктуру — много компонентов, сложно, впечатляюще. Hermes строит как feature — simple nudge, работает сразу.

Для sync/async вертикали правильный путь — hermes-скорость, cognithor-идеи:

> Каждый примитив должен начинать работать в день 1 и добавлять ценность сразу, а не "когда накопится достаточно данных." Reflector с первого run даёт structured output. Skill fitness с первого коммита создаёт историю. CorrectionMemory с первой CC-правки начинает трекинг.

Сложность приходит не от количества компонентов — а от качества сигнала который они производят.
