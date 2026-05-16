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
| `/doevents` | `mq.doevents()` — direct equivalent; call once per main loop iteration |
| `#turbo 120` + `delay 1` | `mq.doevents()` + `mq.delay(50)` in main loop |
| `delay 500` | `mq.delay(500)` |
| INI read/write | `mq.pickle()` or `/ini` TLO |
| Plugin load/unload | `mq.cmd('/plugin X load')` |
| `Ninjadvloot.inc` | `require('ninjadvloot')` Lua module |
| ~1,079 outer/global vars | Module-level Lua tables |

## Proposed Module Structure

Run with: `/lua run kissassist-lua`

```
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
    ├── loot.lua             ← port of Ninjadvloot.inc
    └── utils.lua            ← shared helpers, debug logging
```

## Milestones

### Milestone 1 — Foundation & State Architecture ✅ COMPLETE
**Goal:** Running Lua script that starts, loads config, and exits cleanly.

**Done when:** `/lua run kissassist-lua assist TankName 95` starts, prints role, stops cleanly.

#### Step 1.1 — Project scaffold (`init.lua`) ✅
Create `init.lua` at the repo root and the `modules/` directory. Entry point prints a startup message and exits cleanly. No other modules yet.

**Done when:** `/lua run kissassist-lua` prints `KissAssist starting` with no errors.

---

#### Step 1.2 — `utils.lua` — logging helpers ✅
Implement debug logging functions replacing `.mac`'s `DEBUGN`, `DEBUGCAST`, `DEBUGCOMBAT`, etc. preprocessor macros. Takes a category string and message, prints conditionally. No dependency on state or config.

**Done when:** `require('modules.utils')` loads and `Utils.debug('combat', 'msg')` works in-game without error.

---

#### Step 1.3 — `state.lua` — domain state tables ✅
Define all 14 `State.*` sub-tables with default values sourced from the ~1,079 `DeclareOuters` variables in `kissassist.mac`. No logic — pure data structure. Largest step; the `.mac` source is the reference for mechanical mapping.

Sub-tables: `session`, `combat`, `cast`, `pull`, `movement`, `heal`, `buffs`, `pet`, `mez`, `bard`, `loot`, `dps`, `debug`, `timers`, `misc`, `arrays`

**Done when:** `require('modules.state')` returns a fully initialized `State` table with all sub-tables populated with defaults.

---

#### Step 1.4 — `config.lua` — startup params + INI migration
Two sub-tasks (can be split further):

- **1.4a ✅** Parse command-line args (role, MA name, assist-at %) into `State.session` / `State.role`
- **1.4b ✅** INI auto-migration: on first run reads all 18 INI sections via `mq.TLO.Ini`, writes pickle to `mq.configDir/kissassist-lua/`, renames `.ini` → `.ini.bak`. Subsequent runs load pickle via `dofile`. `Config.get(section, key, default)` accessor added for module use. `KissAssist_Buffs.ini` and `KissAssist_Info.ini` left unconverted.

Depends on Step 1.3 (needs `State` structure to know where to write values).

**Done when:** First launch with existing character INI produces a `.lua` pickle file and `.ini.bak`; subsequent runs load the `.lua` directly.

---

#### Step 1.5 — `InitPlugins` + main loop wiring ✅
Add plugin validation (required: `MQ2Exchange`, `MQ2MoveUtils`, `MQ2Posse`, `MQ2Rez`) and wire the skeleton main loop into `init.lua`. Integration step — pulls 1.1–1.4 together.

```lua
while not State.terminate do
    mq.doevents()
    mq.delay(50)
end
```

**Done when:** `/lua run kissassist-lua assist TankName 95` starts, prints role and MA name, warns about missing plugins, runs the idle loop until `/lua stop kissassist-lua`. ✅ Verified in-game.

---

**Suggested order:** 1.1 → 1.2 → 1.3 → 1.4a → 1.4b → 1.5. Steps 1.2 and 1.3 can be worked in parallel.

---

### Milestone 2 — Events & Binds
**Goal:** All game text reactions and player commands registered.

**Done when:** All 113 events registered, all 31 binds respond in-game, `/lua stop` cleans up handlers.

#### Step 2.1 — `events.lua` scaffold + cast result events ✅
Create `modules/events.lua`, register it in `init.lua`, and port all cast-result events (~50 patterns across 22 named events): `CAST_BEGIN`, `CAST_FIZZLE`, `CAST_INTERRUPTED`, `CAST_RESISTED`, `CAST_TAKEHOLD`, `CAST_IMMUNE`, `CAST_DISTRACTED`, `CAST_STUNNED`, `CAST_NOTARGET`, `CAST_OUTOFRANGE`, `CAST_OUTOFMANA`, `CAST_NOTREADY`, `CAST_RECOVER`, `CAST_NOMOUNT`, `CAST_OUTDOORS`, `CAST_COMPONENTS`, `CAST_STANDING`, `CAST_CANNOTSEE`, `CAST_COLLAPSE`, `CAST_FAILED`, `CAST_FDFAIL`, `CAST_RESISTEDYOU`. Each handler sets `State.cast.castReturn`. `Events.register(state, utils)` / `Events.unregister()` wired into `init.lua`.

Notes: `CAST_OUTDOORS` maps to `CAST_OUTOFMANA` (preserves .mac quirk). `CAST_STUNNED` does not block in the handler — cast engine polls. `CAST_STANDING` uses `State.heal.medding` (not a TLO). `CAST_FDFAIL` guards `Me.Name` match before acting.

**Done when:** Script starts cleanly with events registered; cast result messages in-game set the correct `State.cast.castReturn`. ✅

---

#### Step 2.2 — Combat, movement, and session events ✅
Port remaining high-frequency gameplay events into `events.lua`:
- `GotHit` ×13 (12 attack types + near-miss) → `State.combat.gotHitToggle`, `State.timers.sitToMed`
- `AttackCalled` ×2 → `State.combat.calledTargetID` (guarded: not IAmMA, caller == mainAssist)
- `CantHit`, `CantSee`, `TooClose`, `TooFar` → `State.movement.*` / `State.pull.tooFar` (stubs; full movement in M7)
- `MezBroke` → `State.mez.broke` (stub; mez timer reset in M5)
- `Missing` ×2 → `State.combat.missingComponent`
- `ImDead` ×3 → `State.session.iAmDead` (duplicate-guarded)
- `Zoned` ×2 → `State.timers.justZoned`, DMZ, zone name, camp/return logic
- `Joined` → `State.timers.joinedParty`, `State.buffs.forceBuffs`
- `LeftGroup`, `Invised` → `State.combat.eventFlag`
- `Camping` → `State.terminate = true`
- `TooSteep` → `State.misc.campfireOn = false`

Also: added `campfireOn = false` to `State.misc` in `state.lua` (was missing).

**Done when:** Getting hit, dying, and zoning flip the correct State flags. ✅

---

#### Step 2.3 — Buff, pet, and comms events ✅
Port remaining events:
- `GoMOn` ×3, `GoMOff` ×2 → `State.bard.gomActive` (class filter BRD/BER/MNK/ROG/WAR; cast loop in M8)
- `WornOff`, `GainSomething`, `AskForBuffs` ×2, `KABegCheck` → `State.buffs.*` (full buff queuing in M6)
- `PetSusStateAdd1`, `PetSusStateAdd2`, `PetSusStateSub`, `PetToysPlease` → `State.pet.*`
- `YouGotTell` → echo tell (with pet/NPC filter inline)
- `EQBCIRC`, `FSEQBC`, `GUEQBC` → stubs (EQBC deprecated; DanNet relay in M9)
- `KTDismount` → `state.misc.mountOn = false` + `/dismount` (inline; blocking KT helpers stubbed for M7)
- `KTDoorClick` ×2, `KTHail`, `KTInvite`, `KTSay`, `KTTarget` → stubs for M7
- `#Event Timer Timer1` → omitted (Lua uses `os.clock()` polling; no equivalent event)
- `TaskUpdate`, `MLogOff` → eventFlag + minimal inline action

**Done when:** All 113 events registered with no errors on startup. ✅

---

#### Step 2.4 — `binds.lua` + shutdown cleanup ✅
Created `modules/binds.lua` with all 31 binds. `Binds.register/unregister` wired into `init.lua`.

Fully implemented inline:
- `/debug` — toggles `state.debug.*` flags by category (all/buffs/combat/cast/chainp/heals/mez/move/pet/pull/rk); log/logc arg controls `/mlog on|off`
- `/burn` — sets `state.combat.burnOn/burnActive/burnCalled/burnID`; rotation in M4
- `/backoff` — toggles `state.dps.paused` + clears `combatStart`; CombatReset in M4
- `/makecamphere` — sets campX/Y/Z/Zone + `returnToCamp=true`; broadcast in M9
- `/aggroinfo` — printf XTarget + group MA info from state/TLOs
- `/zoneinfo` — printf pull list state
- `/addfriend` — calls `/posse add/save/load` directly

Stubs (with milestone targets):
- `/switchnow`, `/switchma`, `/kisscast` → M4 (combat.lua)
- `/stayhere`, `/chaseme` → M9 (comms.lua)
- `/trackmedown`, `/addpull`, `/addignore`, `/SetPullArc`, `/setpullranking` → M7 (pull/movement)
- `/buffgroup`, `/campfire`, `/tbmanager` → M6 (buffs.lua)
- `/addimmune` → M5 (healing.lua)
- `/writespells`, `/iniwrite`, `/kisscheck`, `/changevarint` → M10 (config.lua)
- `/memmyspells` → M3 (cast.lua)
- `/kasettings` → M11 (ImGui)
- `/togglevariable`, `/parse`, `/mycmd` → respective domain modules

**Done when:** `/burn`, `/stayhere`, `/makecamphere`, `/debug` etc. toggle correct State flags in-game; `/lua stop` cleans up all handlers. ✅

---

**Suggested order:** 2.1 → 2.2 → 2.3 (sequential, all build on `events.lua`). Step 2.4 can start after 2.1 — binds have no dependency on events.

---

### Milestone 3 — Casting Engine ✅ COMPLETE

**Goal:** Spell/AA/disc/item dispatcher works.

- `cast.lua` — `CastWhat`, `CastSpell`, `CastAA`, `CastDisc`, `CastItem`, `CastCommand`, `CastSkill`, `CastMem`, `CastMemSpell`, `CastReMem`, `CastTarget`
- Cast result state machine driven by `events.lua` handlers (already wired in M2)
- Each cast function takes explicit arguments rather than reading globals directly

**Done when:** Can manually invoke casting functions and observe correct in-game behavior. ✅ Verified in-game (May 8 2026): all 11 exports confirmed as functions; script RUNNING; gemSlots=12 (8 + 4 MR ranks).

---

#### Step 3.1 — `cast.lua` scaffold + simple primitives ✅

Create `modules/cast.lua` with `Cast.init(state, utils)` / `Cast.castWhat(...)` stubs. Implement the three functions with no event-polling dependency:

- **CastTarget**: `/target clear` + `/target id X` with `mq.delay`
- **CastCommand**: strip `"command:"` prefix (first 8 chars), run `mq.cmdf`, return `'SUCCESS'`
- **CastSkill**: `/doability name`, poll `Me.AbilityReady` false → SUCCESS

**Done when:** module loads cleanly; a test invocation of CastCommand runs the raw command. ✅

---

#### Step 3.2 — CastSpell (core poll loop) ✅

The heart of the engine — reads `State.cast.castReturn` already set by `events.lua`.

- Invis guard (except `sentFrom == 'SingleHeal'` or `'GroupHeal'`)
- Free-target (splash) check: skip if `Target.CanSplashLand` is false
- Guard: spell must be in a gem (`Me.Gem[spellName]`), else return `CAST_NO_RESULT`
- `/cast "spellName"` then `mq.delay(100)` poll loop reading `State.cast.castReturn`
- Retry up to 2× on FIZZLE/INTERRUPT/RESIST if `Spell.RecastTime <= 2 sec`
- Restore sit state after cast
- Cast-interrupt handlers (`sentFrom`-based) stubbed → M4 (DPS), M5 (Cure/Mez), M6 (Buffs)

**Done when:** casting a known memed spell in-game returns the correct status enum value. ✅

---

#### Step 3.3 — CastAA + CastDisc + CastItem ✅

Three more primitives with their own polling patterns (can be implemented in parallel):

- **CastAA**: Banestrike race/distance/combat guard; `/alt act ID`; poll `AltAbilityReady == false && Casting.ID == 0` → SUCCESS. Bard twist-pause stubbed → M8.
- **CastDisc**: Duration/target-type guard (don't re-cast active self-disc); `/disc ID` (live MQ) or `/disc name` (emu, `MacroQuest.Build == 4`); wait cooldown timer → SUCCESS.
- **CastItem**: Gold/prestige subscription check; `/useitem "name"`; if cast time > 0, poll casting window; SUCCESS if item on cooldown or consumed.

**Done when:** each function invocable via a test bind returns correct status. ✅

---

#### Step 3.4 — CastMem + CastMemSpell + CastReMem ✅

Spell memorization — needed for `CastWhat` to handle spells not currently in a gem slot.

- **CastMemSpell**: low-level `/memspell gemNum "spellName"` with no-rent cursor cleanup and already-memed guard.
- **CastMem**: combat/moving/casting/invis guards; routes to `MiscGem` (short recast) or `MiscGemLW` (long recast, >30 sec) slots; polls up to 35s for spell ready; cancels if aggro appears mid-mem during buff context.
- **CastReMem**: after a misc-gem spell is cast successfully, sets `ReMemCast`/`ReMemCastLW` flag; calls `CastMemSpell` to restore the original spell when out of combat.
- Added `state.cast.miscGemRemem` field to `state.lua` (was missing).

State fields used: `State.cast.miscGem`, `State.cast.miscGemLW`, `State.cast.miscGemRemem`, `State.cast.reMemMiscSpell`, `State.cast.reMemMiscSpellLW`, `State.cast.reMemCast`, `State.cast.reMemCastLW`, `State.cast.reMemWaitShort`, `State.cast.reMemWaitLong`.

**Done when:** a non-memed spell gets slotted into the misc gem, cast, then original spell restored. ✅

---

#### Step 3.5 — CastWhat dispatcher ✅

Orchestrates everything above. References `.mac` lines 2467–2614.

**ReadyToCast detection** (in priority order, mirrors `.mac` `Select[]` logic):

| Value | Condition | Routes to |
|---|---|---|
| 1 | `Me.ItemReady[=name]` + `FindItem` | CastItem |
| 2 | `Me.AltAbilityReady[name]` (not an item) | CastAA |
| 3 | `Me.CombatAbilityReady[name]` + endurance check | CastDisc |
| 4 | `Me.AbilityReady[name]` + `Me.Skill[name]` | CastSkill |
| 5 | `Me.Gem[name]` + `Me.GemTimer == 0` | CastSpell |
| 6 | `name:Find["command:"]` | CastCommand |
| 7 | `Me.Book[name]` but not memed | CastMem → CastSpell |

Additional logic:
- Already-casting guard (non-bard): return `CAST_CASTING` immediately
- `CastTarget` when target doesn't match `WhatID` and spell is not self-targeted
- DPS stacking check stub → `CastDPSSpellCheck` returns `false` (filled in M4)
- Buff stacking check stub → `CastBuffsSpellCheck` returns `false` (filled in M6)
- Condition evaluation stub: `CondNumber == 0` always passes (filled in M10)
- `CastReMem` after cast if `MiscGemRemem` is set
- Pull context short-circuit: `PullAggroTargetID` set → return SUCCESS immediately
- Stop moving before cast if spell has cast time and character is moving (non-bard)

**Done when:** `Cast.castWhat('SpellName', targetID, 'DPS', 0, 0)` detects type, acquires target, and casts. ✅

---

#### Step 3.6 — Wire into init.lua + `/memmyspells` bind + in-game validation ✅

- `Cast.init(State, Utils)` called in `init.lua` after events/binds registration
- `init.lua` wires `state.cast.miscGem/miscGemLW/miscGemRemem/gemSlots` from `Config.get` post-load; seeds `reMemMiscSpell`/`reMemMiscSpellLW` from live gem slot names
- `/memmyspells` bind fully implemented in `binds.lua`: reads `Gem1..GemN` from `[Spells]` (or `[SpellsN]`) INI section, resolves current rank via `Spell[name].RankName`, mems each spell, refreshes misc gem snapshots after loop

**Done when:** all cast function types observed working in-game with correct status returns. ✅ Verified in-game (May 8 2026).

---

**Suggested order:** 3.1 → 3.2 → 3.3 (CastAA/CastDisc/CastItem in parallel) → 3.4 → 3.5 → 3.6. Each group depends on the previous.

---

### Milestone 4 — Combat Core
**Goal:** Script fights when controlling a single character.

- `combat.lua` — `CheckForCombat`, `Combat`, `CombatTargetCheck`, `CombatTargetCheckRaid`
- Target selection, assist-at threshold, MA detection, melee engagement

**Done when:** Script assists a main tank and fights using melee and combat disciplines.

---

#### Step 4.1 — `combat.lua` scaffold + array loading + state wiring

Create `modules/combat.lua` with `Combat.init(state, utils, cast)`. Wire into `init.lua`.

- Load DPS, Disc, Burn arrays from INI (`DPS1..DPSN`, `Disc1..DiscN`, `Burn1..BurnN`) into `state.combat` tables
- Wire `state.combat` flags from `Config.get`: `dpsOn`, `meleeOn`, `assistAt`, `burnOn`, `burnOnNamed`, `autoBurnTimer`, `meleeDistance`, `campRadius`, etc.
- Load named-mob watch list (`NamedWatch` / `NamedCheck`) from INI
- Add any missing state fields to `state.lua`

**Done when:** module loads cleanly; DPS/Disc/Burn arrays populated from INI.

---

#### Step 4.2 — MobRadar (mob detection)

Mirrors `MobRadar` (kissassist.mac:7143). Scans XTarget slots 1–13 for NPC haters within `MeleeDistance`.

- Iterate `Me.XTarget[n]`: check `.TargetType == "Auto Hater"`, `.Type == "NPC"`, spawn distance ≤ radius
- Set `state.combat.mobCount` and `state.combat.aggroTargetID` (closest hater ID)
- Handle LOS-only mode (`LOSBeforeCombat`) and DMZ guard

**Done when:** `mobCount` correctly reflects nearby hostile NPCs.

---

#### Step 4.3 — Assist + CombatTargetCheck + GetCombatTarget

- **`Assist`** (kissassist.mac:748): use `Me.GroupAssistTarget.ID` when MA is the group's assigned main assist; otherwise find MA's target by name. Sets `state.combat.myTargetID`. Handles IAmMA self-target mode and `/switchma` escalation when MA is dead.
- **`CombatTargetCheck`** (kissassist.mac:1337): validate `myTargetID` not a corpse; sync to MA's target if it changed; handle `TargetSwitchingOn` mode for MA. Group variant; `CombatTargetCheckRaid` for raid context (stub initially).
- **`GetCombatTarget`** (kissassist.mac:818): MA-only path — picks best target from XTarget hater list when no explicit target is set.

**Done when:** `myTargetID` is set correctly when MA has a live NPC targeted.

---

#### Step 4.4 — CheckForCombat + CombatReset + CheckForAdds

- **`CheckForCombat`** (kissassist.mac:484): outer combat control loop — DMZ/dead/no-mobs/no-DPS guards; calls `MobRadar`, `Assist`, then `Combat`; handles `ChainPull==2` exit; FeignAggroCheck after combat ends. IAmMA vs assist branching with `EngageWaitTimer`.
- **`CombatReset`** (kissassist.mac:2144): clears `CombatStart`, turns off attack (`/attack off`), resets `Attacking`, `MyTargetID`, `AggroTargetID`.
- **`CheckForAdds`** (kissassist.mac:2333): detects new mobs joining during combat; updates `mobCount`.
- **`FeignAggroCheck`** (kissassist.mac:14524): if still feigning after combat, stands up.
- Wire `Combat.checkForCombat()` call into `init.lua` main loop when `dpsOn || meleeOn`.

**Done when:** script enters and exits combat in response to nearby mobs; `CombatStart` flag correct.

---

#### Step 4.5 — Combat (melee engagement)

Mirrors `Combat` (kissassist.mac:1036) — the inner fight loop.

- CombatRadius calculation from `Spawn[myTargetID].MaxRangeTo` vs `MeleeDistance`
- `CombatStart` flag, announce "ATTACKING", `/attack on`, CheckStick (MQ2MoveUtils)
- `BeforeAttack` (kissassist.mac:2022): cast pre-combat abilities from `BeforeArray` before first attack
- Periodic `CheckHealth` calls during combat (every `HealInterval` ticks)
- Pet engagement at `PetAssistAt`% mob HP
- Calls `CombatTargetCheck` and `CombatCast` each iteration

**Done when:** script attacks target with melee; `Attacking` flag set.

---

#### Step 4.6 — CombatCast + CastDPSSpellCheck + MashButtons

Mirrors `CombatCast` (kissassist.mac:1616) — DPS spell/AA rotation inside the combat loop.

- Iterate DPS array entries (format `spell|target|cond|...`): call `Cast.castWhat` for each when ready
- Parse target type from array entry (`Mob`, `Me`, `MA`, `Group1..5`, spawn name)
- `CastDPSSpellCheck` (kissassist.mac:2919): check if spell/DoT already on target via `Target.MyBuff[name]` — fills the M4 stub in `Cast.castWhat`
- `MashButtons` (kissassist.mac:1973): iterate `MashArray` for instant-cast AAs/abilities

**Done when:** script casts DPS spells and AAs during combat.

---

#### Step 4.7 — Burn sequence

Mirrors `Burn` (kissassist.mac:11770).

- Iterate `Burn` array entries (same `spell|target|cond` format as DPS), call `Cast.castWhat`
- Tribute activation (`/tribute personal on`) at burn start when `UseTribute` set
- Auto-burn triggers: `/kaburn` bind (already stubbed in binds.lua), named-mob detection via `NamedWatch`/`NamedCheck` list, `AutoBurnTimer`
- `BurnActive` flag; broadcast on burn start

**Done when:** `/kaburn` triggers burn sequence in combat; named mobs auto-burn.

---

#### Step 4.8 — WriteDebuffs + AggroCheck + in-game validation

- **`WriteDebuffs`** (kissassist.mac:12569): iterate Debuff array, call `Cast.castWhat` for each when target lacks the debuff
- **`AggroCheck`** (kissassist.mac:2373): tank roles — taunt if losing aggro; check `Me.CombatAbility[Taunt]`; broadcast aggro state
- End-to-end validation: detect mob → assist MA → melee → DPS rotation → burn → debuffs → reset after kill

**Done when:** script fights end-to-end: detect → assist → melee → DPS → burn → reset.

---

**Suggested order:** 4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6 → 4.7 → 4.8. Each step depends on the previous.

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
- `bard.lua` — `DoBardStuff`, MQ2Medley integration, named medley sets per combat context
  - Define medley sets in character INI (`[MQ2Medley-melee]`, `[MQ2Medley-burn]`, `[MQ2Medley-oor]`, etc.)
  - Call `/medley <setname>` on context transitions; `/medley queue` for event-driven one-shot songs
  - Query `Medley.Active` / `Medley.TTQE` instead of `Twist.Twisting` / `Twist.Current`
  - Note: replaces MQ2Twist — Bard users must define `[MQ2Medley-*]` INI sections (one-time migration)

**Done when:** Necro/Mage/BST pets engage; Bard cycles correct medley sets in and out of combat.

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

## Architectural Decisions (all resolved before Milestone 1)

### 6. Bard Song Plugin — DECIDED: MQ2Medley (replaces MQ2Twist)

See full comparison: `design/mq2twist_vs_mq2medley.md`

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
