# Implementation Backlog — Sync/Async Vertical Framework

*Март 2026 | Синтез идей из brainstorm-сессии*

---

## TL;DR

Полный список реализуемых идей для построения sync/async вертикали поверх nanobot.
Организован по приоритету: от фундамента к продвинутым фичам.

Связанные доки:
- `sync_async_vertical_framework.md` — операционная модель
- `agent_vertical_design_model.md` — ментальная модель вертикалей
- `learning_primitives.md` — идеи самообучения

---

## Фаза 0 — Фундамент (без которого ничего не работает)

### F0.1 — Repo structure: 1 вертикаль = 1 репо

**Проблема:** bias "1 клиент = 1 репо" — ошибочный, нагружает операционно и дублирует глобальные знания.

**Правильная структура:**

```
vertical/
├── AGENTS.md              ← системный промпт агента (глобальный)
├── SOUL.md                ← идентичность агента
├── skills/                ← скиллы: кристаллизованный WM оператора
│   └── site-builder/
│       └── SKILL.md
├── global/
│   └── world_model.md     ← ICP, принципы, рыночные паттерны
├── clients/               ← per-client изолированный контекст
│   ├── acme_corp/
│   │   ├── memory/
│   │   │   └── MEMORY.md  ← client-specific память
│   │   ├── project_state.md
│   │   └── artifacts/
│   └── techstart/
│       └── ...
├── traces/                ← история прогонов (агент пишет, CC читает)
│   └── {run_id}/
│       ├── trace.yaml
│       └── reflection.yaml
├── corrections.md         ← трекинг правок оператора (CC-сессии)
├── attention.md           ← очередь что нужно от оператора
└── .nanobot/
    ├── config.yaml
    └── tenant_map.yaml    ← session_key → client_id
```

**Git log читается как история вертикали:**
```
a1b2c3  skill: auto-crystallized moodboard pattern from acme_corp
d4e5f6  global: updated ICP — added "no e-com under $3k" rule
g7h8i9  clients/acme_corp: completed site build phase
```

---

### F0.2 — Multi-tenant routing в nanobot

**Проблема:** nanobot создаёт один `ContextBuilder(workspace)` на весь инстанс — все клиенты получают одинаковый контекст.

**Что нужно изменить:**

**1. tenant_map.yaml** — маппинг session → client:
```yaml
tenants:
  "telegram:111222333": acme_corp
  "telegram:444555666": techstart
  "default": _global  # для неизвестных сессий
```

**2. TenantResolver** — резолвит client_id из session_key:
```python
class TenantResolver:
    def resolve(self, session_key: str) -> str | None:
        # Прямой lookup в tenant_map.yaml
        # Возвращает client_id или None (global контекст)
```

**3. Dynamic ContextBuilder** — компонует глобальный + клиентский контекст:
```python
# В AgentLoop._process_message():
client_id = self.tenant_resolver.resolve(msg.session_key)

system_prompt = compose_system_prompt(
    global_agents_md=workspace / "AGENTS.md",
    global_soul=workspace / "SOUL.md",
    client_memory=workspace / f"clients/{client_id}/memory/MEMORY.md" if client_id else None,
    client_state=workspace / f"clients/{client_id}/project_state.md" if client_id else None,
    skills=workspace / "skills/",
)
```

**Что меняется в nanobot:**
- `ContextBuilder.__init__` принимает `client_id: str | None`
- `build_system_prompt()` загружает global + client-specific файлы
- `AgentLoop._process_message()` резолвит tenant перед построением контекста
- SessionManager не меняется — уже изолирован по session_key

**Физический доступ агента к чужим файлам** остаётся — tool-уровневая изоляция не приоритет для Phase 0. AGENTS.md инструкция "работай только в своём clients/{client_id}/" достаточна для одного оператора.

---

### F0.3 — Git-safe concurrent commits

**Проблема:** параллельные agent runs (telegram чат + cron) могут делать `git add .` одновременно — украдут чужие изменения в коммит.

**Решение:**

**1. touched_files tracking** — каждый run знает что писал:
```python
class AgentRunContext:
    def __init__(self, client_id: str):
        self.client_id = client_id
        self.touched_files: set[Path] = set()

    def on_file_write(self, path: Path):
        self.touched_files.add(path)

    async def commit(self, message: str):
        if not self.touched_files:
            return
        async with GIT_COMMIT_LOCK:  # asyncio.Lock()
            subprocess.run(["git", "add"] + list(self.touched_files))
            subprocess.run(["git", "commit", "-m", message])
```

**2. Hook в ToolRegistry** — перехватывает write_file/edit_file и регистрирует в RunContext.

**3. Commit convention** — 1 run = 1 коммит:
```
clients/acme_corp: completed requirements phase
skills: auto-crystallized site-builder v3 from acme_corp/run-042
cron: updated world_model ICP signals
```

**Global файлы** (world_model.md, skills/) — append-only convention в AGENTS.md: "добавляй новый блок с датой, не редактируй существующие блоки." Git merge автоматически разрешает append conflicts.

---

## Фаза 1 — Observability и первый flywheel

### F1.1 — Attention queue

**Проблема:** с multi-tenant оператор не знает что происходит без открытия каждого client state.

**Решение:** `attention.md` — живой файл который агент обновляет:

```markdown
# Attention Queue — обновлено 2026-03-30 14:22

## Blocked — нужно прямо сейчас
- [ ] acme_corp: moodboard готов, нужен апрув перед site build
- [ ] techstart: вопрос по scope pricing секции

## Review — для следующей CC-сессии
- [ ] 4 новых trace с последней сессии
- [ ] skill/site-builder: auto-updated (git diff)
- [ ] corrections.md: 2 новых паттерна

## FYI — без действий
- cron 2026-03-30: обновил ICP сигналы в world_model
```

Агент пишет в attention.md в конце каждого run. Оператор открывает IDE — видит где он нужен. Это точка входа в sync loop.

---

### F1.2 — Bootstrap protocol

**Проблема:** новая вертикаль с пустым repo — откуда берётся начальный WM оператора?

**Решение:** CC-сессия как структурированное интервью:

```
Оператор: "Запускаем новую вертикаль — design agency"

CC ведёт интервью:
  "Каков твой ICP? Кого ты берёшь, кого отказываешь?"
  "Какие решения ты принимаешь одинаково снова и снова?"
  "Что чаще всего идёт не так в первых проектах?"
  "Какие принципы ты хочешь чтобы агент никогда не нарушал?"

→ CC кристаллизует ответы в:
  AGENTS.md (системный промпт с правилами)
  global/world_model.md (ICP, паттерны отказа)
  skills/requirements-gathering/SKILL.md (как брифовать клиента)
  skills/send-to-client/SKILL.md (как и когда коммуницировать)
```

Bootstrap — это экстракция неявной экспертизы оператора в вербализованную форму. Не документирование — перенос знания.

---

### F1.3 — Self-skill creator

**Проблема:** ценные паттерны теряются — каждый run делается заново без кристаллизации.

**Триггер:** завершение agent run (не tool-call count как в hermes).

```
Run завершён с success_score >= 3.5 И tool_calls >= 8
    ↓
Background review (отдельный LLM-вызов):
  "Есть ли паттерн в этом run достойный скилла?
   Если да — создай или обнови SKILL.md.
   Если нет — ничего не делай."
    ↓
Если скилл создан/обновлён:
  git commit: "skill: auto-crystallized X from {client}/{run_id}"
  Добавляет запись в attention.md → Review секция
    ↓
CC-сессия: оператор смотрит git diff, принимает или откатывает
```

**Почему напрямую в skills/ а не в drafts/:**
- Git history — натуральный audit trail
- Если скилл плохой — видно по падению skill fitness со временем
- Оператор всегда может `git revert` или отредактировать
- Держит систему простой

---

### F1.4 — Corrections tracking

**Проблема:** оператор правит одно и то же — система не замечает паттерн.

**Решение:** простой `corrections.md`:

```markdown
# Corrections Log

## 2026-03-28 | skill/site-builder | hero-image-rule
Удалено: "always include hero image above the fold"
Причина: TechStart — жалобы на load time
Паттерн: hero-image-rule (1/3)

## 2026-03-30 | skill/site-builder | hero-image-rule
Удалено снова — восстановилось после auto-update
Паттерн: hero-image-rule (2/3) → ATTENTION: скилл нестабилен
```

**Правило:** после 2+ коррекций с одним паттерном → запись в attention.md:
`"skill/site-builder нестабилен по hero-image-rule — приоритет для CC-ревизии"`

Оператор пишет в corrections.md сам (2-3 строки) после каждой CC-правки. Или CC добавляет автоматически при commit с тегом `[correction]`.

---

## Фаза 2 — Умный flywheel (после 20+ runs)

### F2.1 — Verbalizability score

**Концепция:** главный KPI sync/async вертикали — насколько агент может действовать автономно.

```
verbalizability(skill) = 1 - checkpoint_rate
verbalizability(client) = weighted avg по скиллам
verbalizability(vertical) = avg по всем клиентам
```

Метрика живёт в `traces/metrics.yaml`:
```yaml
date: 2026-03-30
vertical_verbalizability: 0.73  # цель: растёт каждый месяц
skills:
  site-builder: 0.88            # стабильный
  requirements-gathering: 0.65  # работать
  moodboard-review: 0.41        # часто checkpoint → приоритет
```

**Признак хорошей итерации:** verbalizability растёт, operator_interventions_per_run падают.

---

### F2.2 — CausalAnalyzer — tool chain корреляции

**После 20+ runs** — анализ какие последовательности tool calls коррелируют с высоким score.

Каждый trace пишет:
```yaml
tool_sequence: [read_file, web_search, write_file, edit_file]
success_score: 4.5
```

CC-скрипт (запускается вручную раз в месяц):
```
python analyze_traces.py --runs=traces/ --min_runs=20
→ "read_file → web_search → write_file": avg_score 4.3 (n=23)
→ "read_file → write_file" (без поиска): avg_score 3.1 (n=15)
→ Рекомендация: добавить в AGENTS.md hint про web_search перед write
```

---

### F2.3 — Skill A/B testing

**При major update скилла** — эмпирически подтверждать что v2 лучше v1.

YAML frontmatter в SKILL.md:
```yaml
ab_test:
  active: true
  version_a: "v1-content-here"
  version_b: "v2-content-here"
  runs_a: 0
  score_a: null
  runs_b: 0
  score_b: null
  min_runs_to_decide: 10
```

Агент выбирает версию детерминированно (hash от run_id → 50/50). После 10 runs на каждой — CC-сессия: смотрим score_a vs score_b, winner становится основной, проигравший в git архив.

---

## Фаза 3 — Продвинутые идеи (исследовательские)

### F3.1 — Honcho — client profiles через наблюдение

**Что это:** self-hosted сервис (Docker) для накопления user representation. Вместо явной записи в MEMORY.md — наблюдение всех взаимодействий → on-demand синтез.

```bash
docker run -p 8000:8000 honcho-ai/honcho
# HONCHO_BASE_URL=http://localhost:8000 (API ключ не нужен)
```

Каждый клиент = отдельный peer в Honcho. После 10+ взаимодействий:
```python
client_peer.chat(
    "What are this client's aesthetic preferences?",
    reasoning_level="high"
)
# → LLM синтезирует из всей истории
```

**Когда добавлять:** когда explicit MEMORY.md перестаёт покрывать нужды. Honcho не заменяет MEMORY.md — дополняет on-demand синтезом неявных паттернов.

---

### F3.2 — Reactive Background Evolution

**Механика:** раз в неделю SessionAnalyzer смотрит traces, находит повторяющиеся checkpoints → gap → фоновое исследование → скилл.

```
Еженедельный анализ traces:
  "moodboard-review checkpoint встречается 4 раза за неделю"
    ↓
  Gap: "агент не знает как выбирать типографику под бренд"
    ↓
  Background research (idle time):
    web_search: "typography brand identity principles"
    → crystallizes в update skill/moodboard-review
    → git commit + attention.md entry
```

**Отличие от cognithor:** нет CuriosityEngine. Только reactive — источник всегда реальный паттерн из traces. Меньше шума.

---

### F3.3 — Trace как training data

**Не нужно сейчас. Но спроектировать формат с первого дня.**

Если trace пишется структурированно:
```jsonl
{"run_id":"...", "turn":1, "role":"assistant", "content":"...", "tool_calls":[...]}
{"run_id":"...", "turn":1, "role":"tool", "name":"write_file", "success":true}
{"run_id":"...", "meta": {"score":4.2, "corrections":0, "skills":["site-builder"]}}
```

→ После 100+ runs — готовый датасет для SFT или preference learning.

---

## Что НЕ реализуем (и почему)

| Идея | Причина |
|---|---|
| Hard isolation (no cross-client file access) | Сложность без value для одного оператора |
| Telegram inline keyboards (да/нет кнопки) | Текстовые ответы достаточны для Phase 0-1 |
| Blocking actions в коде | Prompt-level ("жди апрува") достаточно для прототипа |
| Proactive gap-finding (cognithor style) | Риск шума; reactive лучше для старта |
| Fine-tuning pipeline | Нет смысла до 100+ runs и доказанной ценности |
| Per-client git submodules | Избыточная сложность |

---

## Зависимости между идеями

```
F0.1 (repo structure)
    └── F0.2 (multi-tenant routing)
            ├── F0.3 (git-safe commits)
            ├── F1.1 (attention queue)
            └── F1.3 (self-skill creator)
                    └── F2.1 (verbalizability score)
                            └── F2.3 (A/B testing)

F1.2 (bootstrap)     — независимо, делать при старте вертикали
F1.4 (corrections)   — независимо, начинать сразу

F2.2 (causal)        — требует 20+ traces
F3.1 (honcho)        — требует 10+ client interactions
F3.2 (reactive evo)  — требует F1.4 (corrections) + 20+ traces
```

---

## Минимальный эксперимент (Фаза 0)

Что сделать чтобы система заработала минимально:

1. **Repo structure** — создать `clients/`, `global/`, `skills/`, `traces/`
2. **tenant_map.yaml** — добавить первого клиента
3. **TenantResolver** — простой lookup из tenant_map
4. **touched_files + GIT_LOCK** — безопасные коммиты
5. **attention.md** — агент пишет что требует внимания

После 5 runs: открыть с CC, спросить "что менять в инструкциях?". Если CC-анализ traces даёт конкретные изменения в AGENTS.md — flywheel работает.
