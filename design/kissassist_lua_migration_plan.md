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

### Completed — Milestones 1–12

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

### Milestone 13 — Advanced Combat Rotation

**Goal:** Port the remaining `combatCast` features deferred from Milestone 4, plus stuck-gem detection in `castWhat`.

#### Features

- **Per-slot timers** (`ABTimer`, `DPSTimer`, `FDTimer`) — each DPS/ability slot can specify a per-use cooldown; the rotation skips the slot until the timer expires
- **Advanced rotation modes** — `DPSSkip` (HP% floor stops entire rotation), `DPSOn==2` (out-of-combat rotation), `DAMod` (timer duration modifier on the slot), `DPSInterval` (fallback timer for zero-duration spells)
- **Feign-death sequence** (`tType=='feign'`) — cast FD, wait up to 3 s for feign state, suppress slot 60 s, wait up to 10 s to break, stand if still feigning
- **`TargetSwitchingOn`** — after each cast in the rotation, re-check MA's current target; switch assist target if MA changed
- **Stuck-gem detection** — in `castSpell`, verify `Me.Gem(n).Name()` matches the expected spell; re-mem via `castMemSpell` if mismatched; return `CAST_STUCK_GEM` on second failure

**Implemented:** PR #13

- `state.lua`: `state.combat.slotTimers = {}`, `dpsSkip`, `dpsInterval`, `dpsOnOoc`; `state.cast.checkStuckGem`
- `cast.lua`: local `castMemSpell` forward-declared; `Cast.init` loads `[Spells] CheckStuckGem`; `setSlotTimer(spellName, tType, daMod)` computes `os.clock()` expiry with `+N`/`-N`/fixed DAMod arithmetic; per-slot timer skip guard at top of `combatCast` slot loop; `CAST_SUCCESS` block sets timer with `dpsInterval` fallback; feign-death sequence in `CAST_SUCCESS` (`tType=='feign'`, BST/MNK/NEC/SHD only); after-cast `TargetSwitchingOn` retarget check; stuck-gem re-mem block in `castSpell` after gem guard
- `combat.lua`: `Combat.init` wires `DPSOn` (1/2), `DPSSkip`, `DPSInterval`, `TargetSwitchingOn` from `[Melee]` (not `[General]` as plan stated — corrected from mac source mac:14687); `combatReset` clears `slotTimers`
- **Plan deviation — DAMod**: plan described DAMod as "skip slot while disc active"; mac source shows it is a timer-duration modifier (`+N`/`-N` seconds, or fixed `N` seconds). Implemented correctly per mac source.
- **Plan deviation — DPSSkip**: plan described as "skip N ticks"; mac source shows it is an HP% floor that stops the entire rotation pass (`/break` equivalent → `return`). Implemented correctly.
- **Plan deviation — TargetSwitchingOn INI section**: plan listed `[General]`; mac source (mac:14687) loads from `[Melee]`. Implemented correctly.
- **Plan deviation — stuck-gem**: plan placed check in `castWhat`; implementation placed in `castSpell` (after gem guard) for cleaner separation. `castWhat` stub comment updated to reference `castSpell`.

---

### Milestone 14 — Debuff Rotation

**Goal:** Port the `DoDebuffStuff` / `DebuffCast` debuff rotation to a new `debuff.lua` module, giving enchanters, shamans, beastlords, and other debuffing classes the ability to land and maintain debuffs on primary and X-target mobs during combat.

#### Background

Debuff slots are stored in the same `[DPS]` INI section as DPS rotation slots. The second pipe-delimited field distinguishes them: a value **≥ 101** marks a debuff slot; **< 101** is a DPS slot. `DebuffCount` is the count of debuff slots found. Each slot has a per-slot mob-tracking list (`DBOList`) and a re-apply timer (`DBOTimer`). The system supports spell, AA, and item debuffs, checks target buff state by type tag before casting, and iterates X-Target auto-hater slots to debuff all mobs in range — not just the primary target.

`WriteDebuffs` (the `.mac` function that writes self-debuff status to `KissAssist_Buffs.ini` for healer cross-char cure awareness) is **not ported** — the Lua port already covers this via `comms.lua` broadcasting `state.heal.needCuring`.

#### Debuff Features

- **`DebuffAllOn` modes** — `0` off, `1` in-combat debuffing only, `2` out-of-combat debuffing enabled
- **Per-slot mob tracking** (`state.debuff.lists[i]`) — tracks which mobs have been debuffed per slot; stale entries (dead or > 200 units) purged each pass
- **Per-slot re-apply timers** (`state.debuff.timers[i]`) — set from spell/AA/item duration on successful land; slot is skipped until timer expires
- **Debuff type tags** — `slow`, `tash`, `malo`, `crip`, `snare`, `root`, `strip`, `always` — before casting, checks if the target already has that debuff type; skips cast if duration remains
- **Multi-mob debuffing** — iterates X-Target auto-hater slots within `MeleeDistance` and LOS; temporarily suspends melee to retarget off-mob, then restores
- **`FWait` flag** — in chain-pull path, waits briefly for spell/AA/item to come off cooldown; in normal DPS path, skips and lets combat continue
- **KConditions gate** — `|cond` tag in DPS slot entries evaluated via `Cond.eval` (M11)
- **Fight reset** — all timers and mob lists cleared in `Combat.combatReset`

#### Debuff Steps

**Step 14.1 — `state.debuff` sub-table**

Add to `state.lua`:

```lua
State.debuff = {
    on     = 0,   -- DebuffAllOn (0/1/2)
    count  = 0,   -- number of debuff slots in DPS array
    slots  = {},  -- array of slot defs: { spell, tag1, tag2, condNo }
    timers = {},  -- slot index → expiry timestamp (mq.gettime())
    lists  = {},  -- slot index → table of debuffed spawn IDs
}
```

**Step 14.2 — Config loading in `config.lua`**

When parsing `[DPS]` INI slots in `Config.parseDPSArray()`:

- If `Arg[2,|]` (as integer) **≥ 101**, it is a debuff slot — append to `state.debuff.slots` and increment `state.debuff.count`.
- If **< 101**, it remains a DPS slot (existing behavior).

Read `DebuffAllOn` from `[General]` via `Config.get` → `state.debuff.on`.

**Step 14.3 — `debuff.lua` module**

Create `modules/debuff.lua` with:

- `Debuff.init(state, utils, cast, healing, cond)` — store peer refs, call config load
- Local `debuffRadar()` — iterate `mq.TLO.Me.XTarget` slots 1–`XSlotTotal`; collect IDs that are: auto-hater type, alive (not Corpse), not PC/PC-pet, within `MeleeDistance`, and have LOS. Return list. (Same pattern as `mez.lua`'s `mezRadar`.)
- `Debuff.cast(debuffTargetID, fWait)` — port of `DebuffCast`:
  - Iterate `state.debuff.slots`; skip slots where the mob is already on `state.debuff.lists[i]` and `state.debuff.timers[i]` has not expired
  - Check target's existing debuff by tag1 type (`Target.Slowed`, `Target.Tashed`, `Target.Maloed`, `Target.Crippled`, `Target.Snared`, `Target.Rooted`); if present and duration > 0, set timer and skip
  - Evaluate KCondition via `Cond.eval(slot.condNo)` if set
  - Call `Cast.castWhat(spell, targetID, 'DebuffCast', 0, 0)`; on `CAST_SUCCESS` set timer from spell/AA/item duration; on `CAST_IMMUNE` / `CAST_TAKEHOLD` set long suppress timer
  - Intersperse `Healing.checkHealth('DebuffCast')` during wait loops when `HealsOn` is set
  - `fWait = true`: wait up to ~3.5 s for spell/AA/item to come off cooldown before giving up; `fWait = false`: skip immediately and return to DPS
- `Debuff.check(firstMobID)` — port of `DoDebuffStuff`:
  - Guard: `state.debuff.on == 0`, `state.debuff.count == 0`, `state.session.DPSPaused`, respawn window open, or (mez on and `state.mez.mezMobDone == false`) → return
  - Bard + MA + in combat guard (bards skip debuff when acting as MA)
  - Purge stale entries from all `state.debuff.lists[i]` (dead or > 200 units)
  - Call `Debuff.cast(firstMobID, true)` for primary target
  - Iterate X-Target auto-hater mobs via `debuffRadar()`; for each mob (skip `firstMobID`): temporarily suspend melee if needed, call `Debuff.cast(mobID, DebuffAllOn==2)`, restore target and melee
- `Debuff.resetFight()` — zero all `state.debuff.timers` and clear all `state.debuff.lists`

**Step 14.4 — Wire into `combat.lua`**

- `Combat.init` receives `debuff` peer reference alongside existing peers
- In the main fight loop after the mez check block: call `Debuff.check(state.session.assistTarget)` when `state.debuff.on > 0`
- In the chain-pull path: call `Debuff.cast(targetID, true)` instead of `Debuff.check` (mirrors mac's `DebuffCast` with `FWait=1` at mac:1262)
- Out-of-combat debuff path (after `CheckForCombat` returns no target): if `state.debuff.on == 2` and `state.session.assistTarget` exists, call `Debuff.check`
- In `Combat.combatReset`: call `Debuff.resetFight()`

**Step 14.5 — Wire into `init.lua`**

- `require` and instantiate `debuff.lua`; pass to `Combat.init`

**Done when:** Debuff slots in `[DPS]` INI with tag ≥ 101 land on the primary and X-target mobs during combat, timers suppress re-casting while the debuff is active, and the fight-end reset clears all tracking state.

---

### Milestone 15 — ImGui UI (Optional)

**Goal:** In-game configuration panel.

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

Features present in the original `.mac` that are not ported to Lua and will not be tested.

| Area | Mac location | Notes |
| --- | --- | --- |
| `CombatTargetCheckRaid` | mac:1420 | Raid/cross-char target selection; not ported |
| `MercsDoWhat` | mac:8569 | Merc control; not ported |
| `AutoFireOn` branches | in `CombatCast` | Ranged auto-fire logic; not ported |
| `namedWatchList` / `NamedWatch` | mac:12886 | Named mob watch list from `KissAssist_Info.ini`; INI loader not implemented |
| `SwitchMA` on offtank / MA-dead path | `Bind_SwitchMA` | Cross-char MA failover; not ported |
| `BroadCast` burn/add/tank-announce | mac:12820 | In-group announce on burn/add events; not ported |
| `combatReset`: DPS meter output (`MQ2DPSAdv`) | mac:2144 | End-of-fight parse output; requires MQ2DPSAdv plugin; not in scope |
| `combatPet` Summon Companion AA | mac:2056 | In-combat pet resummon; not ported |
| **`AFKTools`** | mac:11665 | AFK automation: pause on stranger in camp radius (MQ2Posse); GM detection with configurable action (hold / endmacro / unload / quit); not ported |
| **Corpse recovery** (`RecoverCorpses`, `GrabCorpse`) | mac:15331 | SHD/NEC/ROG: auto-summons own/group corpses using Tiny Jade Inlaid Coffin; not ported |
| **`GroupEscape`** | mac:6335 | DRU/WIZ emergency group evac (Exodus/Succor/Evacuate) when MA dies mid-combat; not ported |
| **KissTrack integration** (`Event_KTDismount/Target/Hail/Say/DoorClick/Invite`) | mac:14313–14459 | Six event handlers for cross-macro NPC interaction with KissTrack; not ported |
| **`CastMount`** | mac:13875 | Auto-mount from `[Buffs]` INI using `\|Mount` type tag; not ported |
| **`CastMana`** | mac:13892 | Auto-cast mana restoration items (Canni, Paragon, Harvest, Managroup type from `[Buffs]` INI); not ported |
| **EQBC events** (`Event_GUEQBC`, `Event_FSEQBC`, `Event_EQBCIRC`) | mac:11588–11664 | Group/server EQBC broadcast and IRC-style command handling; intentionally dropped — EQBC deprecated per Arch Decision 3 |
| **`Roguestuff`** | mac:15205 | Rogue-specific stealth/hide management; not ported |

---

## Biggest Risks

| Risk | Impact | Notes |
| --- | --- | --- |
| State table design | High | Wrong in M1 = pain in every milestone |
| MQ2Cast feedback loop | High | Subtle cast result event handling |
| INI compatibility | Medium | User config migration burden |
| Cross-char comms | Medium | DanNet/EQBC vs actors system |
| In-game validation time | High | No automated tests; must play to verify |
