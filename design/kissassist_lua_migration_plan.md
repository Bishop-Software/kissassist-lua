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
| --- | --- |
| `${Me.Level}` | `mq.TLO.Me.Level()` (note the `()`) |
| `#Event name, pattern, Sub` | `mq.event('name', 'pattern', fn)` |
| `#bind /cmd Sub` | `mq.bind('/cmd', fn)` |
| `/doevents` | `mq.doevents()` — direct equivalent; call once per main loop iteration |
| `#turbo 120` + `delay 1` | `mq.doevents()` + `mq.delay(50)` in main loop |
| `delay 500` | `mq.delay(500)` |
| INI read/write | `mq.pickle()` or `/ini` TLO |
| Plugin load/unload | `mq.cmd('/plugin X load')` |
| `Ninjadvloot.inc` | `require('ninjadvloot')` Lua module |
| ~1,079 outer/global vars | Module-level Lua tables |

## Proposed Module Structure

Run with: `/lua run kissassist-lua`

```text
kissassist-lua/              ← repo root (this folder lives in MQ2's lua/ directory)
├── init.lua                 ← entry point
└── modules/                 ← all domain modules
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
    ├── bard.lua             ← DoBardStuff, MQ2Medley integration, song medley management
    ├── loot.lua             ← MQ2AutoLoot delegation (replaces Ninjadvloot.inc port)
    └── utils.lua            ← shared helpers, debug logging
```

## Milestones

### Completed — Milestones 1–11

| Milestone | PR | What was built |
| --- | --- | --- |
| 1 — Foundation | #1 | `init.lua`, `utils.lua`, `state.lua`, `config.lua`, plugin validation, main loop skeleton |
| 2 — Events & Binds | #2 | All 113 `mq.event()` handlers in `events.lua`; all 31 `mq.bind()` commands in `binds.lua` |
| 3 — Casting Engine | #3 | `cast.lua`: full `CastWhat` dispatcher, gem memory, cast state machine |
| 4 — Combat Core | #4 | `combat.lua`: combat detection, melee/spell rotation, burn system |
| 5 — Healing | #5 | `healing.lua`: heals, cures, rez; wired into combat loop |
| 6 — Buffs | #6 | `buffs.lua`: self/group buffs, beg-for-buffs, `CheckPetBuffs` |
| 7 — Pulling & Movement | #7 | `pull.lua`, `movement.lua`: full pull/movement loop, all pull/movement binds |
| 8 — Pet & Bard | #8 | `pet.lua`: pet control, rampage-pet pull gating; `bard.lua`: MQ2Medley context switching |
| 9 — Looting | #9 | `loot.lua`: MQ2AutoLoot delegation, sell/deposit/barter helpers; loot binds; `MQ2AutoLoot` required plugin |
| 10 — Full Integration & Parallel Validation | #10 | Remaining stub binds (`/kisscheck`, `/campoff`, etc.); `comms.lua` cross-char messaging (actors + DanNet shim); main loop phase audit against `.mac`; in-game testing (steps 10.4–10.6) deferred to production rollout |
| 11 — Condition Evaluation (KConditions) | — | `cond.lua` evaluator (`mq.parse`, TARGETCHECK sentinel); `Config.parseCondArray()` strips condNNN suffix; `Cond.eval()` wired into all rotation modules and `CastWhat` condNumber gate; burn condNo/abortFlag; ConOn bind and integration test deferred |
| 12 — Mez System | #12 | `mez.lua`: full mez subsystem — `Mez.init` (Config load), local `mezRadar`, `mezMobsAE`, `mezMobs`, public `Mez.check`, `Mez.aeCheck`, `Mez.breakMez`; `state.mez` expanded to 20 fields; `MezBroke` event enhanced with per-slot timer-clearing; `/addimmune` bind fully implemented; `[Mez]` + `PetBreakMezSpell` config loaded in `Mez.init`; wired into `combat.lua` fight loop, `checkForCombat`, and `combatPet` (pettank BreakMez); precedence bug fixed in `Combat.assist` and `Combat.getCombatTarget` |

### Milestone 12 — Mez System (`MezCheck`, `AECheck`, `BreakMez`)

**Goal:** Port the full mez subsystem so crowd-control classes can automatically mezmerize adds while the group fights the main target.

#### Mez System Overview

The `.mac` mez system has three subs and one event:

- **`Sub MezCheck(sentFrom)`** (line 8074) — core mez loop; called from `CheckForCombat`, `Combat`, `CombatCast`, and `CheckBeforeCombat` with different `sentFrom` strings to control behavior. Maintains a `MezArray` of tracked mezzed mob IDs, checks readiness/mana/HP-threshold/immune-list guards, and casts the configured single or AE mez spell.
- **`Sub AECheck(int prm_ListMobs)`** (line 12473) — separate AE mez threshold check; fires when mob count in AE range meets `MezAECount`.
- **`Sub BreakMez`** (line 2123) — intentionally casts `PetBreakMezSpell` on the target; only called for `pettank`/`pullerpettank`/`hunterpettank` roles to let the pet engage.
- **`#Event MezBroke`** — "#1# has been awakened by #2#." — sets `MezBroke` flag and re-triggers the mez loop.

**`MezOn` modes:** 0=Off / 1=Single & AE / 2=Single only / 3=AE only.

Key state: `MezOn`, `MezBroke`, `MezImmuneIDs` (pipe-delimited mob IDs), `MezMobCount`, `MezSingleCount`, `MezAECount`, `MezAETimer`, `MezArray[i,1]`, `MezMobFlag`, `MezSpell`, `MezAESpell`, `PetBreakMezSpell`. All map into the existing `state.mez` sub-table.

#### Step 12.1 — `mez.lua` module

Create `modules/mez.lua` with:

- `Mez.init(state, utils, cast)` — stores refs
- `Mez.check(sentFrom)` — port of `Sub MezCheck`: guard checks (MezOn, hovering, DMZ), mob count vs `MezSingleCount`/`MezAECount` thresholds, immune-list pruning, HP-threshold skip, mana check, spell-ready check, single and AE cast dispatch via `_cast.castWhat`
- `Mez.aeCheck()` — port of `Sub AECheck`: count NPCs in AE range, gate on `MezAECount`, dispatch AE cast
- `Mez.breakMez()` — port of `Sub BreakMez`: pettank-only, casts `PetBreakMezSpell` on current target

Add `state.mez` fields to `state.lua` (already has sub-table stub; populate):

```lua
mez = {
    on = 0, broke = false,
    immuneIDs = {}, mobCount = 0,
    singleCount = 1, aeCount = 2,
    aeTimer = 0, mobArray = {},
    mobFlag = false, mobDone = false,
    spell = "", aeSpell = "", petBreakSpell = "",
}
```

Wire `mez.lua` into `init.lua` require/init order (after combat, before healing).

**Done when:** `Mez.check()` runs without error with `MezOn=0` (no-op path).

**Implemented:** `modules/mez.lua` created with `Mez.init(state, utils, cast)`, local `mezRadar` (XTarget hater scan), local `mezMobsAE` (BRD/ENC AE dispatch), local `mezMobs` (single mez cast with per-slot timer), `Mez.check` (full 14-guard-per-slot port of `DoMezStuff`), `Mez.aeCheck` (AE threshold gate), `Mez.breakMez` (pettank only). `state.mez` expanded to 20 fields (`on` int 0–3, `broke`, `immuneIDs`, `radius`, `minLevel`, `maxLevel`, `stopHPs`, `spell`, `aeSpell`, `petBreakSpell`, `mezDebuffSpell`, `mezDebuffOnResist`, `mobCount`, `mobAECount`, `aeClosest`, `singleCount`, `aeCount`, `mobDone`, `mobFlag`, `debuffCount`). Wired into `init.lua` at line 104 (after `Loot.init`).

#### Step 12.2 — `MezBroke` event and `/addimmune` bind

In `events.lua`, register the MezBroke event:

```lua
mq.event("MezBroke", "#1# has been awakened by #2#.", function(_, mobName, _)
    state.mez.broke = true
    -- mez loop will re-fire on next tick
end)
```

In `binds.lua`, wire `/addimmune` (already registered as a stub in M2):

- Add current target's ID to `state.mez.immuneIDs`; print confirmation.

**Done when:** Waking a mezzed mob sets `state.mez.broke`; `/addimmune` appends to the immune list.

**Implemented:** `onMezBroke` in `events.lua` already registered for pattern `"#1# has been awakened by #2#."` — enhanced to scan `state.arrays.mezArray` slots 1–50, find the awoken mob by name, and clear `state.timers['mezTimer'..i]` so re-mez fires immediately (port of mac:8166/8180). `onAddMezImmune` in `binds.lua` already fully implemented and registered as `/addimmune`; adds target ID to `state.mez.immuneIDs` pipe-delimited string and persists name to InfoFileName INI under zone key.

#### Step 12.3 — Config: load `[Mez]` INI section

In `config.lua`, load `[Mez]` into `state.mez`:

- `MezOn`, `MezSpell`, `MezAESpell`, `MezSingleCount`, `MezAECount`, `PetBreakMezSpell`
- Mez HP threshold (`MezPct` — skip mezzing if mob HP below this)

**Done when:** `state.mez.spell` and `state.mez.on` load correctly from pickle.

**Implemented:** Config loading moved into `Mez.init()` (same effect as loading in `config.lua`). Added `local Config = require('modules.config')` to `mez.lua`. `Mez.init` loads all `[Mez]` keys (`MezOn`, `MezRadius`, `MezMinLevel`, `MezMaxLevel`, `MezStopHPs`, `MezSpell`, `MezDebuffOnResist`, `MezDebuffSpell`, `MezAESpell`) and `PetBreakMezSpell` from `[Pet]`. Mac defaults used as fallbacks (radius=50, stopHPs=80). `config.lua` `cfg.Mez` block and `defaultCfg` Mez defaults were already present from an earlier migration step.

#### Step 12.4 — Wire into combat loop

In `combat.lua`:

- `checkForCombat`: after mob-count update, call `_mez.check("CheckForCombat")` when `MezOn > 0`
- `combat` main loop: call `_mez.check("Combat")` and `_mez.check("Combat1")` at appropriate points
- `combatCast`: call `_mez.check("CombatCast")` before casting; skip cast if target is mezzed and char is not MA
- `checkBeforeCast`: call `_mez.check("CheckBeforeCombat")` when `sentFrom == "CombatCast"`

In `combat.lua` pet-tank target engagement path: call `_mez.breakMez()` for pettank roles.

**Done when:** Mez fires before the group attacks an add; mezzed mobs are not accidentally woken by non-MA casters.

**Implemented:** `Combat.init` signature extended to accept `mez` (8th param), stored as `_mez`. `init.lua` updated to pass `Mez` to `Combat.init`. Three call sites wired: (1) `fight()` inner spell loop — `_mez.check('Combat')` + `_mez.aeCheck()` (mac:1162/1164); (2) `fight()` pet/mez tail — `_mez.check('Combat')` (mac:1323); (3) `checkForCombat()` post-fight — `_mez.check('checkForCombat')` + `_mez.aeCheck()` (mac:543). `combatPet()` wired with role-gated `_mez.breakMez()` for pettank/pullerpettank/hunterpettank (mac:2080). Precedence bug fixed: `not _state.mez.on > 0` → `_state.mez.on == 0` in `Combat.assist` and `Combat.getCombatTarget`.

#### Step 12.5 — Integration test

See Section 12 of the test plan. Key checks:

- `MezOn=1`; two mobs aggro; second mob gets mezzed automatically
- Waking a mezzed mob triggers `MezBroke` event and re-mez fires
- `/addimmune` prevents re-mezzing the target
- `MezOn=0` — no mez fires regardless of mob count
- Pettank role — `BreakMez` fires to let pet engage

**Done when:** Mez system gates correctly in live multi-mob combat.

**Implemented:** Manual in-game validation required — no automated test suite. See Section 12 of the test plan for the five key checks.

---

### Milestone 13 — Advanced Combat Rotation

**Goal:** Port the remaining `combatCast` features deferred from Milestone 4, plus stuck-gem detection in `castWhat`.

#### Features

- **Per-slot timers** (`ABTimer`, `DPSTimer`, `FDTimer`) — each DPS/ability slot can specify a per-use cooldown; the rotation skips the slot until the timer expires
- **Advanced rotation modes** — `DPSSkip` (skip N ticks between fires), `DPSOn==2` (out-of-combat rotation), `DAMod` (skip slot while a damage-avoidance disc is active), `DPSInterval` (minimum ms between any two casts)
- **Feign-death sequence** (`FDTimer`) — FD pull cycling: cast FD, wait FDTimer ms, then re-engage or abort
- **`TargetSwitchingOn`** — after each cast in the rotation, re-check MA's current target; switch assist target if MA changed
- **Stuck-gem detection** — in `castWhat`, confirm the expected spell is in its gem slot before casting; eject and re-mem if mismatched or empty

#### Steps

**Step 13.1 — Per-slot timers in `combat.lua`**

Add `State.combat.slotTimers = {}` (slot index → expiry timestamp). In `combatCast`, skip any slot whose timer has not expired. Start the timer on successful cast.

Read `ABTimer`, `DPSTimer`, and `FDTimer` from each `[DPS]` and `[Melee]` INI slot entry in `config.lua`.

**Step 13.2 — Advanced rotation modes in `combat.lua`**

Port four flags read from the `[DPS]` INI section per slot:

- `DPSSkip` — integer; slot skipped this many ticks after last fire before re-attempting
- `DPSOn==2` — slot fires even when not in combat
- `DAMod` — slot skipped while a damage-avoidance disc is active (`Me.ActiveDisc` check)
- `DPSInterval` — minimum milliseconds between any two casts in the rotation; enforced via `State.combat.lastCastTime`

**Step 13.3 — Feign-death sequence in `combat.lua`**

When `FDTimer` is set on a DPS slot and FD cast succeeds, pause the rotation for `FDTimer` ms before re-engaging. Abort cleanly if the character dies during the wait.

**Step 13.4 — `TargetSwitchingOn` mid-rotation retarget**

After each cast in `combatCast`, if `State.combat.targetSwitchingOn` is true, re-query MA's current target. If it differs from the current assist target, update `State.session.assistTarget` and restart the rotation from slot 1.

Read `TargetSwitchingOn` from `[General]` INI section in `config.lua`.

**Step 13.5 — Stuck-gem detection in `cast.lua`**

Before casting a spell gem in `castWhat`:

1. Confirm `mq.TLO.Me.Gem(n).Name()` matches the expected spell name
2. If mismatched or nil, `/memspell n <spellName>` and wait for memorization (reuse existing gem-mem logic)
3. Log a warning; retry once; return `CAST_STUCK_GEM` on second failure

**Done when:** All five features pass test plan Section 13.

---

### Milestone 14 — ImGui UI (Optional)

**Goal:** In-game configuration panel.

- Status display: role, MA, combat state, camp location
- Toggle buttons for HealsOn, BuffsOn, CuresOn, PullOn, etc.
- Live config editing (spell assignments, thresholds)

**Done when:** Users can configure and monitor via UI panel instead of chat commands.

---

## Architectural Decisions (all resolved before Milestone 1)

### 6. Bard Song Plugin — DECIDED: MQ2Medley (replaces MQ2Twist)

`bard.lua` uses MQ2Medley instead of MQ2Twist. Key rules:

- Song sets are defined as named medleys in the character INI (`[MQ2Medley-melee]`, `[MQ2Medley-burn]`, `[MQ2Medley-oor]`)
- `bard.lua` calls `/medley <setname>` on context transitions — no gem-list management in Lua code
- Event-driven one-shot songs use `/medley queue <song>` without tearing down the active medley
- Query `Medley.Active` and `Medley.TTQE` for state; do not use Twist TLO members
- `MQ2Medley` is required for Bard roles only; no-op for all other classes
- `MQ2Twist` is removed from the required plugin list entirely

**Bard INI migration:** `[MQ2Twist]` sections are not forward-compatible. Bard users must define `[MQ2Medley-*]` sections — one-time manual migration.

---

Decisions 1–5 were set before Milestone 1:

### 1. State Table Partitioning — DECIDED: Option A

Single `State` table exported from `state.lua` with domain sub-tables:

| Sub-table | Key variables |
| --- | --- |
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
| `State.loot` | on, radius, spamInfo |
| `State.dps` | DPSPaused, DPSTarget, LastDPSCast |
| `State.debug` | On, All, Combat, Pull, Heals, Cast, Move, Pet, Mez |
| `State.timers` | All ~30 timer vars as os.clock() expiry timestamps |

**Timer helpers in utils.lua:**

```lua
function Utils.timerExpired(t) return os.clock() >= t end
function Utils.setTimer(seconds) return os.clock() + seconds end
```

**Dependency rule:** Every module receives `state` and `utils` at `init()` time. No module imports another domain module. Cross-module communication happens through `State` exclusively (star topology, no circular deps). Selected modules also receive peer references at init (e.g. `Combat.init(state, utils, cast, healing, buffs, bard)`).

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
        mq.delay(100)  -- delay() processes events internally
    end
    return State.cast.status  -- 'SUCCESS', 'FIZZLE', 'INTERRUPT', 'RESIST', 'TIMEOUT'
end
```

**Cast status enum** (replaces four .mac flags: `castReturn`, `CastResult`, `castCheck`, `CheckResisted`):

- `IDLE` → `CASTING` → `SUCCESS` / `FIZZLE` / `INTERRUPT` / `RESIST` / `TIMEOUT`
- Set by event handlers in `events.lua` reading game text
- Read by `cast.lua` poll loop

**Rule:** The main loop calls `mq.doevents()` then `mq.delay(50)` each iteration — same pattern as `.mac`'s `/doevents` + `delay 1`. Cast wait loops use `mq.delay(100)` without a separate `mq.doevents()` call since blocking during a cast is intentional — prevents pull/buff/movement systems issuing conflicting commands mid-cast (same behavior as .mac).

### 5. Incremental Migration — DECIDED: Option B (character-by-character)

Migrate one character at a time while the rest stay on `.mac`. Suggested order by risk:

| Order | Role | Why this order |
| --- | --- | --- |
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
| --- | --- | --- |
| State table design | High | Wrong in M1 = pain in every milestone |
| MQ2Cast feedback loop | High | Subtle cast result event handling |
| INI compatibility | Medium | User config migration burden |
| Cross-char comms | Medium | DanNet/EQBC vs actors system |
| In-game validation time | High | No automated tests; must play to verify |
