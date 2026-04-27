# KissAssist Lua Migration Plan

Refactoring KissAssist from MacroQuest `.mac` scripting to Lua. Devised 2026-04-27.

## Why Lua

- Full programming language: modules, tables, proper type system
- Run multiple scripts simultaneously
- ImGui support for in-game config panels
- Lua actors system for cleaner cross-character communication
- Better long-term maintainability

## Key Translation Reference

| .mac | Lua |
|---|---|
| `${Me.Level}` | `mq.TLO.Me.Level()` (note the `()`) |
| `#Event name, pattern, Sub` | `mq.event('name', 'pattern', fn)` |
| `#bind /cmd Sub` | `mq.bind('/cmd', fn)` |
| `/doevents` | `mq.doevents()` |
| `#turbo 120` + `delay 1` | `mq.delay(1)` in main loop |
| `delay 500` | `mq.delay(500)` |
| INI read/write | `mq.pickle()` or `/ini` TLO |
| Plugin load/unload | `mq.cmd('/plugin X load')` |
| `Ninjadvloot.inc` | `require('ninjadvloot')` Lua module |
| ~1,079 outer/global vars | Module-level Lua tables |

## Proposed Module Structure

```
kissassist/
├── kissassist.lua       ← entry point (/lua run kissassist)
├── config.lua           ← INI/pickle load-save, startup params
├── state.lua            ← all runtime state tables (replaces ~1079 globals)
├── events.lua           ← all 113 mq.event() registrations
├── binds.lua            ← all 31 mq.bind() registrations
├── cast.lua             ← CastWhat, CastSpell, CastAA, CastDisc, CastItem
├── combat.lua           ← CheckForCombat, Combat, CombatTargetCheck
├── healing.lua          ← CheckHealth, DoGroupHealStuff, CheckCures, RezCheck
├── buffs.lua            ← CheckBuffs, WriteBuffs, CheckBegforBuffs
├── pull.lua             ← FindMobToPull, PullValidate, PullCheck
├── movement.lua         ← DoWeMove, DoWeChase, Stuck
├── pet.lua              ← DoPetStuff, CheckPetBuffs, CastPetToys
├── bard.lua             ← DoBardStuff, song twist management
├── loot.lua             ← port of Ninjadvloot.inc
└── utils.lua            ← shared helpers, debug logging
```

## Milestones

### Milestone 1 — Foundation & State Architecture
**Goal:** Running Lua script that starts, loads config, and exits cleanly.

- Create `kissassist/` directory and `kissassist.lua` entry point
- `utils.lua` — debug logging helpers (replaces `DEBUGN`, `DEBUGCAST` etc.)
- `state.lua` — organize ~1,079 globals into domain tables:
  - `State.combat` (IAmMA, AggroTargetID, MobCount, IAmDead, …)
  - `State.movement` (ReturnToCamp, CampX/Y/Z, CampRadius, …)
  - `State.pull` (PullMob, PullWith, MaxRadius, …)
  - `State.pet`, `State.buffs`, `State.role`, `State.flags`, etc.
- `config.lua` — startup parameter parsing, INI load, `IniCleanup` logic
- `InitPlugins` check at startup
- Skeleton main loop: `while not State.terminate do mq.doevents() mq.delay(1) end`

**Done when:** `/lua run kissassist assist TankName 95` starts, prints role, stops cleanly.

---

### Milestone 2 — Events & Binds
**Goal:** All game text reactions and player commands registered.

- `events.lua` — port all 113 `#Event` handlers; each sets flags in `State.*` tables
- `binds.lua` — port all 31 `#bind` commands (toggles: `/kacampon`, `/kaburn`, etc.)
- Register clean shutdown via `mq.unevent()` / `mq.unbind()` on exit

**Done when:** Toggle commands work in-game; game text events flip correct state flags.

---

### Milestone 3 — Casting Engine
**Goal:** Spell/AA/disc/item dispatcher works.

- `cast.lua` — `CastWhat`, `CastSpell`, `CastAA`, `CastDisc`, `CastItem`, `CastCommand`
- MQ2Cast plugin interaction (cast result event → flag → next cast feedback loop)
- Each cast function takes explicit arguments rather than reading globals directly

**Done when:** Can manually invoke casting functions and observe correct in-game behavior.

---

### Milestone 4 — Combat Core
**Goal:** Script fights when controlling a single character.

- `combat.lua` — `CheckForCombat`, `Combat`, `CombatTargetCheck`, `CombatTargetCheckRaid`
- Target selection, assist-at threshold, MA detection, melee engagement

**Done when:** Script assists a main tank and fights using melee and combat disciplines.

---

### Milestone 5 — Healing & Recovery
**Goal:** Character keeps self and group alive.

- `healing.lua` — `CheckHealth`, `DoGroupHealStuff`, `CheckCures`, `RezCheck`, `RezWithCheck`
- Health threshold triage, MQ2Rez plugin event handling

**Done when:** Healer classes heal group members and rez dead players.

---

### Milestone 6 — Buff System
**Goal:** Self-buffing and group buffing work.

- `buffs.lua` — `CheckBuffs`, `WriteBuffs`, `CheckBegforBuffs`, `CheckPetBuffs`
- Cross-character state tracking via MQ2DanNet/EQBC (or Lua actors — see architectural decisions)

**Done when:** Characters self-buff on startup and respond to buff requests.

---

### Milestone 7 — Pulling & Movement
**Goal:** Puller roles work; all characters return to camp.

- `pull.lua` — `FindMobToPull`, `PullValidate`, `PullCheck` (melee/ranged/spell/pet/nav)
- `movement.lua` — `DoWeMove`, `DoWeChase`, `Stuck`, MQ2Nav/MQ2AdvPath integration

**Done when:** Puller finds mobs, pulls safely, characters return to camp after combat.

---

### Milestone 8 — Pet & Bard
**Goal:** Pet classes and Bards function correctly.

- `pet.lua` — `DoPetStuff`, `CheckPetBuffs`, `CastPetToys`, pet hold/resume
- `bard.lua` — `DoBardStuff`, MQ2Twist integration, song twist rotation

**Done when:** Necro/Mage/BST pets engage; Bard twists songs correctly.

---

### Milestone 9 — Looting
**Goal:** Loot system works with existing loot rules.

- `loot.lua` — port of `Ninjadvloot.inc`
- Load per-item rules from existing `Loot.ini` format (preserve compatibility)

**Done when:** Characters loot corpses per existing rules.

---

### Milestone 10 — Full Integration & Parallel Validation
**Goal:** Feature parity with `kissassist.mac` v12.002.

- Wire all modules into main loop in correct order (mirrors existing `.mac` iteration)
- Run Lua script alongside `.mac` on separate test characters for behavior comparison
- Fix behavioral divergences
- Verify backward compatibility with existing `.ini` config files

**Done when:** Lua script is behaviorally equivalent across all roles.

---

### Milestone 11 — ImGui UI (Optional)
**Goal:** In-game configuration panel.

- Status display: role, MA, combat state, camp location
- Toggle buttons for HealsOn, BuffsOn, CuresOn, PullOn, etc.
- Live config editing (spell assignments, thresholds)

**Done when:** Users can configure and monitor via UI panel instead of chat commands.

---

## Open Architectural Decisions

These must be resolved before writing code (Milestone 1):

### 1. State Table Partitioning — DECIDED: Option A
Single `State` table exported from `state.lua` with domain sub-tables:

| Sub-table | Key variables |
|---|---|
| `State.session` | IAmMA, IAmDead, IAmABard, MainAssist, Role, ZoneName |
| `State.combat` | AggroTargetID, MyTargetID, MobCount, Attacking, BurnActive, EventFlag |
| `State.cast` | castReturn, CastResult, MiscGem, GemSlots, SpellSetName, ReMemCast |
| `State.pull` | PullMob, Pulling, PullRange, PullWithAlt, PullIgnore, MobsToPullFirst |
| `State.movement` | CampX/Y/Z, WhoToChase, StickDist, AdvpathPoint, DontMoveMe |
| `State.heal` | SHealPct, NeedCuring, HealAgain, HealRemChk, Medding |
| `State.buffs` | ForceBuffs, KABegActive, ExtendedBuffList |
| `State.pet` | PetOn, PetCombatOn, PetHold, PetToyList, PetSuspendState |
| `State.mez` | MezOn, MezBroke, MezImmuneIDs, MezMobCount |
| `State.bard` | TwistOn, TwistWhat, Twisting, GoMActive, MeleeTwistOn |
| `State.loot` | BagNum, CursorID, LooterAssigned, DragCorpse |
| `State.dps` | DPSPaused, DPSTarget, LastDPSCast |
| `State.debug` | On, All, Combat, Pull, Heals, Cast, Move, Pet, Mez |
| `State.timers` | All ~30 timer vars as os.clock() expiry timestamps |

**Timer helpers in utils.lua:**
```lua
function Utils.timerExpired(t) return os.clock() >= t end
function Utils.setTimer(seconds) return os.clock() + seconds end
```

**Dependency rule:** Every module imports only `state` and `utils`. No module imports another domain module. Cross-module communication happens through `State` exclusively (star topology, no circular deps).

### 2. INI Backward Compatibility — DECIDED: Option C (Hybrid auto-migration)

First-run flow in `config.lua`:
1. Check for `KissAssist_Server_Toon_Class.lua` (pickle config)
2. If absent → read existing `.ini` via `/ini` TLO, convert all sections/keys 1:1 into `Config` table, write via `mq.pickle()`, rename `.ini` to `.ini.bak`
3. Subsequent runs → load `.lua` directly; old `.ini` kept as `.bak` rollback safety net

`migrateFromIni()` is a one-time lookup table mapping INI section+key → `Config` table path (mechanical, since all key names are already known from the `.mac` source).

**Exception:** `KissAssist_Buffs.ini` and `KissAssist_Info.ini` (cross-character shared files) stay as `.ini` for the duration of the port — simultaneous multi-client write access makes pickle conversion risky until the core is stable.

### 3. Cross-Character Messaging — DECIDED: Option C (actors-first, DanNet shim during migration, EQBC deprecated)

Primary transport is **Lua actors** (built into MQ2Lua — no extra plugin required, works cross-process and cross-LAN via UDP multicast).

A thin `comms.lua` module abstracts the transport so no other module cares which backend is running:
```lua
Comms.send(targetChar, data)   -- unicast to one character
Comms.broadcast(data)          -- all kissassist instances
Comms.init()                   -- detect available backend, register mailbox
```

**Backend detection order at startup:**
1. Actors (always available) — primary
2. DanNet — shim kept during migration window for chars still on `.mac`
3. EQBC — **explicitly deprecated; to be removed after migration is complete**

**Key rule:** Actors message handlers never call `mq.delay()` — set `State` flags only, let the main loop act on them.

**Buff state change:** `WriteBuffs` no longer writes to `KissAssist_Buffs.ini`. Each character broadcasts its buff table via `Comms.broadcast()` on a timer. Other characters receive it and update their local `State.buffs.Remote[charName]`. This replaces the shared file approach entirely once all chars are on Lua.

### 4. MQ2Cast Interaction — DECIDED: Option A (polling loop) + cast state machine

`cast.lua` uses a blocking poll loop after initiating a cast:
```lua
function M.castSpell(gem, spellName, targetID)
    State.cast.status = 'CASTING'
    mq.cmdf('/cast %d', gem)
    local timeout = Utils.setTimer(30)

    while State.cast.status == 'CASTING' and not Utils.timerExpired(timeout) do
        mq.doevents()
        mq.delay(100)
    end
    return State.cast.status  -- 'SUCCESS', 'FIZZLE', 'INTERRUPT', 'RESIST', 'TIMEOUT'
end
```

**Cast status enum** (replaces four .mac flags: `castReturn`, `CastResult`, `castCheck`, `CheckResisted`):
- `IDLE` → `CASTING` → `SUCCESS` / `FIZZLE` / `INTERRUPT` / `RESIST` / `TIMEOUT`
- Set by event handlers in `events.lua` reading game text
- Read by `cast.lua` poll loop

**Rule:** `mq.doevents()` is called in exactly two places — the main loop and inside active cast wait loops. Nowhere else. Blocking during a cast is intentional — prevents pull/buff/movement systems issuing conflicting commands mid-cast (same behavior as .mac).

### 5. Incremental Migration — DECIDED: Option B (character-by-character)

Migrate one character at a time while the rest stay on `.mac`. Suggested order by risk:

| Order | Role | Why this order |
|---|---|---|
| 1 | Melee DPS | Combat + buffs only; no healing responsibility; cheapest death |
| 2 | Pet class | Adds pet system validation in low-stakes role |
| 3 | Puller | Validates pull system in isolation |
| 4 | Healer | Highest stakes — validate last when everything else is proven |

**Rules:**
- `kissassist.mac` stays untouched throughout — any character can `/mac kissassist` back at any time with zero friction
- DanNet shim in `comms.lua` stays active until the last character migrates
- **Deleting the DanNet/EQBC shim is the explicit end-of-migration milestone**

---

## Biggest Risks

| Risk | Impact | Notes |
|---|---|---|
| State table design | High | Wrong in M1 = pain in every milestone |
| MQ2Cast feedback loop | High | Subtle cast result event handling |
| INI compatibility | Medium | User config migration burden |
| Cross-char comms | Medium | DanNet/EQBC vs actors system |
| In-game validation time | High | No automated tests; must play to verify |
