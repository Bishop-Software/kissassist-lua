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

### Completed — Milestones 1–15 (of 23)

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
| 11 — Condition Evaluation (KConditions) | #11 | `cond.lua` evaluator (`mq.parse`, TARGETCHECK sentinel); `Config.parseCondArray()` strips condNNN suffix; `Cond.eval()` wired into all rotation modules and `CastWhat` condNumber gate; burn condNo/abortFlag; ConOn bind and integration test deferred |
| 12 — Mez System | #12 | `mez.lua`: full mez subsystem — `Mez.init` (Config load), local `mezRadar`, `mezMobsAE`, `mezMobs`, public `Mez.check`, `Mez.aeCheck`, `Mez.breakMez`; `state.mez` expanded to 20 fields; `MezBroke` event enhanced with per-slot timer-clearing; `/addimmune` bind fully implemented; `[Mez]` + `PetBreakMezSpell` config loaded in `Mez.init`; wired into `combat.lua` fight loop, `checkForCombat`, and `combatPet` (pettank BreakMez); precedence bug fixed in `Combat.assist` and `Combat.getCombatTarget` |
| 13 — Advanced Combat Rotation | #13 | `cast.lua` + `combat.lua`: per-slot `slotTimers[]`, `setSlotTimer()` with `DAMod` arithmetic; `DPSSkip` HP floor; `DPSOn==2` OOC mode; `DPSInterval` zero-duration fallback; feign-death sequence (`tType=='feign'`); `TargetSwitchingOn` mid-rotation retarget (from `[Melee]`); `CheckStuckGem` re-mem in `castSpell` |
| 14 — Debuff Rotation | #14 | `debuff.lua`: `Debuff.init`, `debuffRadar`, `Debuff.cast`, `Debuff.check`, `Debuff.resetFight`; `state.debuff` sub-table; `[DPS]` threshold≥101 split; `FaceMobOn` integer fix; `Me.State()` face guard; `/peton` `/petoff` binds; `combatReset` clears debuff state |
| 15 — Buff System Extensions | #15 | `buffs.lua`: `Buffs.castMount()` scans buffsArray for `\|Mount` tag (FeetWet + cond guards); `Buffs.castMana()` scans for `\|mana` tag (invis/justZoned/Revival Sickness guards, Bard Dichotomic Psalm endurance check, Druid Growth per-slot cooldown); `castMana` wired into `Combat.fight()` and OOC main loop; `castMount` wired into Phase 3 post-rez; `/mounton` `/mountoff` binds; `MountSpell` config key removed |

### Milestone 15 — Buff System Extensions

**Goal:** Add mount and mana item casting to the buff rotation.

- `CastMount` — auto-cast mount from `[Buffs]` INI using `|Mount` type tag; dismount on combat entry
- `CastMana` — auto-cast mana restoration items (Canni, Paragon, Harvest, Managroup type tags from `[Buffs]` INI)

**Done when:** Characters auto-mount when out of combat and auto-use mana items when mana is low, driven entirely by INI config.

---

### Milestone 16 — Combat Extensions

**Goal:** Fill three remaining combat gaps present in the `.mac` but not yet ported.

- `AutoFireOn` ranged auto-fire branches in `combat.lua` — gates ranged attack on range/arc conditions
- `combatPet` Summon Companion AA — in-combat pet resummon when pet dies (extends `pet.lua`)
- `BroadCast` burn/add/tank-announce — chat announces on burn activation, add detection, MA death (extends `comms.lua`)

**Done when:** Rangers/casters use ranged auto-fire correctly; pets auto-resummon mid-fight; group sees burn/add chat notifications.

---

### Milestone 17 — Named Watch List

**Goal:** Port `namedWatchList` / `NamedWatch` — the named mob radar that prioritizes kills by name.

- Load named mob list from `KissAssist_Info.ini` (INI loader not yet implemented for this file)
- `namedRadar` scans nearby spawns against the watch list
- Priority targeting: named mobs jump the assist queue ahead of normal mobs

**Done when:** Named mobs on the watch list are pulled and killed first when in camp radius.

---

### Milestone 18 — Safety & Escape Systems

**Goal:** Port two defensive recovery systems gated behind class checks.

- `GroupEscape` — DRU/WIZ emergency group evac (Exodus/Succor/Evacuate) when MA dies mid-combat
- `RecoverCorpses` / `GrabCorpse` — SHD/NEC/ROG auto-summon own/group corpses using Tiny Jade Inlaid Coffin; class-gated

**Done when:** Druid/Wizard characters auto-evac the group on MA death; Shadowknight/Necro/Rogue characters auto-summon corpses after a wipe.

---

### Milestone 19 — AFK Tools

**Goal:** Port the `AFKTools` subsystem for safe AFK play.

- Stranger-in-camp detection via MQ2Posse — pause automation when unknown player enters camp radius
- GM detection with configurable response action: `hold` (pause), `endmacro` (stop), `unload` (unload MQ2), `quit` (exit EQ)
- Configurable from `[AFKTools]` INI section

**Done when:** Script auto-pauses on strangers and responds to GM presence per configured action.

---

### Milestone 20 — Merc Control

**Goal:** Port `MercsDoWhat` — automated mercenary management.

- New module: `merc.lua`
- Suspend/resume merc based on group composition and combat state
- Set merc stance (passive, balanced, aggressive) based on context
- Wired into the main loop alongside pet and combat phases

**Done when:** Mercs automatically adjust stance and active state based on fight context.

---

### Milestone 21 — Rogue

**Goal:** Port `Roguestuff` — rogue-specific stealth and hide automation.

- Auto-hide when out of combat and not moving
- Stealth management during pull approach
- Class-gated to ROG only; no-op for all other classes

**Done when:** Rogue characters auto-hide between fights and manage stealth correctly during pulls.

---

### Milestone 22 — Raid Support

**Goal:** Port raid-mode targeting and MA failover.

- `CombatTargetCheckRaid` — raid-mode cross-character target selection (mac:1420)
- `SwitchMA` on offtank / MA-dead path — cross-character MA failover via `comms.lua` actors

**Done when:** Script operates correctly in a raid context with proper target selection and auto-reassigns MA when the primary goes down.

---

### Milestone 23 — ImGui UI

**Goal:** In-game configuration and status panel.

- Status display: role, MA, combat state, camp location
- Toggle buttons for HealsOn, BuffsOn, CuresOn, PullOn, etc.
- Live config editing (spell assignments, thresholds)

**Done when:** Users can configure and monitor via UI panel instead of chat commands.

---

## Architectural Decisions (all resolved before Milestone 1)

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

### 6. Bard Song Plugin — DECIDED: MQ2Medley (replaces MQ2Twist)

`bard.lua` uses MQ2Medley instead of MQ2Twist. Key rules:

- Song sets are defined as named medleys in the character INI (`[MQ2Medley-melee]`, `[MQ2Medley-burn]`, `[MQ2Medley-oor]`)
- `bard.lua` calls `/medley <setname>` on context transitions — no gem-list management in Lua code
- Event-driven one-shot songs use `/medley queue <song>` without tearing down the active medley
- Query `Medley.Active` and `Medley.TTQE` for state; do not use Twist TLO members
- `MQ2Medley` is required for Bard roles only; no-op for all other classes
- `MQ2Twist` is removed from the required plugin list entirely

**Bard INI migration:** `[MQ2Twist]` sections are not forward-compatible. Bard users must define `[MQ2Medley-*]` sections — one-time manual migration.

**Rules:**

- `kissassist.mac` stays untouched throughout — any character can `/mac kissassist` back at any time with zero friction
- DanNet shim in `comms.lua` stays active until the last character migrates
- **Deleting the DanNet/EQBC shim is the explicit end-of-migration milestone**

---

## Not Ported / Out of Scope

Features present in the original `.mac` that are explicitly out of scope and will not be tested.

| Area | Mac location | Notes |
| --- | --- | --- |
| `combatReset`: DPS meter output (`MQ2DPSAdv`) | mac:2144 | End-of-fight parse output; requires MQ2DPSAdv plugin; dropped |
| **EQBC events** (`Event_GUEQBC`, `Event_FSEQBC`, `Event_EQBCIRC`) | mac:11588–11664 | EQBC deprecated per Arch Decision 3; dropped |
| **KissTrack integration** (`Event_KTDismount/Target/Hail/Say/DoorClick/Invite`) | mac:14313–14459 | Requires external KissTrack macro; no Lua port exists; dropped |

## Planned — Future Milestones (15–23)

Features from the original `.mac` deferred from the initial port; planned for implementation.

| Area | Mac location | Milestone |
| --- | --- | --- |
| `CastMount` | mac:13875 | 15 — Buff System Extensions |
| `CastMana` | mac:13892 | 15 — Buff System Extensions |
| `AutoFireOn` branches | in `CombatCast` | 16 — Combat Extensions |
| `combatPet` Summon Companion AA | mac:2056 | 16 — Combat Extensions |
| `BroadCast` burn/add/tank-announce | mac:12820 | 16 — Combat Extensions |
| `namedWatchList` / `NamedWatch` | mac:12886 | 17 — Named Watch List |
| `GroupEscape` | mac:6335 | 18 — Safety & Escape Systems |
| Corpse recovery (`RecoverCorpses`, `GrabCorpse`) | mac:15331 | 18 — Safety & Escape Systems |
| `AFKTools` | mac:11665 | 19 — AFK Tools |
| `MercsDoWhat` | mac:8569 | 20 — Merc Control |
| `Roguestuff` | mac:15205 | 21 — Rogue |
| `CombatTargetCheckRaid` | mac:1420 | 22 — Raid Support |
| `SwitchMA` on offtank / MA-dead path | `Bind_SwitchMA` | 22 — Raid Support |

---

## Biggest Risks

| Risk | Impact | Notes |
| --- | --- | --- |
| State table design | High | Wrong in M1 = pain in every milestone |
| MQ2Cast feedback loop | High | Subtle cast result event handling |
| INI compatibility | Medium | User config migration burden |
| Cross-char comms | Medium | DanNet/EQBC vs actors system |
| In-game validation time | High | No automated tests; must play to verify |
