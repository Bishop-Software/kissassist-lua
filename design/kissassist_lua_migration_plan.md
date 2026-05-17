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

### Completed — Milestones 1–9 (all PRs merged to `main`)

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

---

### Milestone 10 — Full Integration & Parallel Validation

**Goal:** Feature parity with `kissassist.mac` v12.002.

**Done when:** Lua script is behaviorally equivalent across all roles; mixed Lua/`.mac` group runs content without coordination failures.

---

#### Step 10.1 — Complete remaining stub binds

14 binds were registered in M2 as stubs. Implement all except `/kasettings` (M11/ImGui):

**Config binds** — implement logic in `config.lua`, wire from `binds.lua`:

- `/kisscheck` — print runtime config summary: role, MA name, assist-at %, key thresholds, which systems are on/off
- `/writespells` — write current spell set back to pickle (calls `Config.save()`)
- `/iniwrite` — force flush entire config pickle to disk
- `/changevarint <key> <value>` — mutate an integer config field at runtime (e.g. `/changevarint AssistAt 90`)
- `/togglevariable <key>` — toggle a boolean config field at runtime

**Cast/combat binds** — implement in respective modules:

- `/kisscast <spellname>` — immediate single cast via `Cast.castSpell`; bypasses rotation
- `/switchma <name>` — update `State.session.mainAssist` and re-run `AssignMainAssist`
- `/switchnow` — already partially sets `calledTargetID`; wire the target-switch logic in `combat.lua`

**Misc binds:**

- `/campfire` — place campfire at current position using `/usefinditem` or `/useitem`; set `State.misc.campfireOn`
- `/parse <expr>` — evaluate a MQ2 expression string and print result (debug utility)
- `/mycmds` — execute a custom slash command string stored in `State.misc.myCmd` (from INI `[General] MyCmd`)

**Done when:** All stubs replaced; each bind performs its action in-game with no `printf` TODO output.

---

#### Step 10.2 — `comms.lua` — Cross-character messaging

Create `modules/comms.lua` implementing Architectural Decision #3 (actors-first, DanNet shim).

**Module API:**

```lua
Comms.init(state, utils)          -- detect backend, register mailbox
Comms.send(targetChar, msgType, data)   -- unicast
Comms.broadcast(msgType, data)    -- all KissAssist instances
Comms.tick()                      -- poll DanNet mailbox if actors unavailable
```

**Backend detection order at `Comms.init()`:**

1. Lua actors (built-in, always available) — primary
2. DanNet (`/dquery` + mailbox) — shim for chars still on `.mac`
3. Set `State.session.danNetOn = true` when DanNet shim is active (existing flag used by `Buffs.writeBuffs` guard)

**Message types to handle:**

| Type | Sender triggers | Receiver action |
| --- | --- | --- |
| `CAMP` | `/makecamphere` bind | update `State.movement.camp*` on receiving chars |
| `STAY` | `/stayhere` bind | set `State.movement.returnToCamp = true`, clear chase on receivers |
| `CHASE` | `/chaseme` bind | set `State.session.chaseAssist = true`, set `WhoToChase` on receivers |
| `BUFFS` | `Buffs.writeBuffs()` | update `State.buffs.remote[charName]` (replaces `KissAssist_Buffs.ini` reads) |

**Wiring:**

- Wire `Comms.init()` into `init.lua` after all other module inits
- Wire `Comms.tick()` into the main loop (call every iteration before `mq.delay`)
- Wire `/stayhere` and `/chaseme` binds to call `Comms.broadcast`
- Wire `/makecamphere` bind to also broadcast `CAMP` after setting local camp state
- Wire `Buffs.writeBuffs()` to call `Comms.broadcast('BUFFS', buffTable)` when DanNet is not active

**Done when:** Two Lua chars exchange `/stayhere` and `/chaseme` correctly; buff tables sync cross-char without touching `KissAssist_Buffs.ini`.

---

#### Step 10.3 — Main loop order audit

Compare `init.lua` main loop phase order against the `.mac` `Sub Main` while loop (read `kissassist.mac` directly as the reference).

Current Lua order: `Combat → Buffs → Pet → Heal → Bard → Movement → Loot → Pull`

`.mac` order to verify against (from source): `doevents → Combat → Heal/Cure/Rez → Pull → Buffs → Pet → Movement → Loot`

**Known divergence to investigate:** Lua currently runs Buffs before Healing. The `.mac` runs Healing before Buffs and Pull. Determine if this ordering difference causes behavioral issues under combat conditions (e.g. a group member dying before heals run because buffs consumed the tick).

**Deliverable:** Update `init.lua` main loop to match `.mac` phase order; add a comment block labeling each phase. If a reorder is intentional (e.g. Bard medley before movement is correct), document why.

**Done when:** `init.lua` loop order is verified against `.mac` source with any divergences either fixed or explicitly documented as intentional.

---

#### Step 10.4 — Single-character integration test

Run the Lua script on one **melee DPS** character (lowest-stakes role per Decision #5) through a full play session.

**Checklist:**

- Script starts cleanly; all modules load; no Lua errors in console
- Combat loop engages on assist target; melee/spell rotation fires
- Buffs apply on self and group members
- Heals fire when group HP drops; `/addimmune` and cure logic works
- `/makecamphere` sets camp; character returns to camp between pulls
- `/burn` toggles burn state; burn spells fire during burn window
- `/lua stop` exits cleanly — no orphaned event handlers or bind registrations

Fix any runtime errors before proceeding to 10.5.

**Done when:** Character completes a full session (pulls, combat, buffs, heals, camp return) with zero Lua errors.

---

#### Step 10.5 — Multi-character parallel validation

Run **one character on Lua** alongside the rest of the group on `.mac`. Validate cross-script coordination.

**Test scenarios:**

- Lua char receives buffs from `.mac` chars (buff state visible in `State.buffs.remote`)
- Lua char's buffs are visible to `.mac` chars (via DanNet shim broadcast)
- MA on `.mac` — Lua assist char engages correct target
- `/stayhere` sent from `.mac` MA — Lua chars stop and camp
- `/chaseme` sent from `.mac` MA — Lua chars begin chasing
- Puller on `.mac`, assisters on Lua — pull coordination and ramp-pet gating work
- Healer on Lua — heals fire for both Lua and `.mac` group members

Document any behavioral divergence; fix before sign-off.

**Done when:** Mixed Lua/`.mac` group completes a content session without coordination failures.

---

#### Step 10.6 — INI backward compatibility + production validation

Test the full INI→pickle migration with real production character config files.

**Checklist:**

- First launch with existing `.ini` produces a `.lua` pickle and a `.ini.bak` rename
- All 18 INI sections round-trip correctly (no keys dropped, no defaults incorrectly applied)
- Second launch loads pickle directly; `.ini.bak` is untouched
- `/iniwrite` flushes current runtime state back to pickle without data loss
- Test with configs for each validated role (melee DPS, pet class, puller, healer)

**Done when:** No config regression from INI migration across all tested roles; production configs load correctly with no missing or corrupted values.

---

### Milestone 11 — ImGui UI (Optional)

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
