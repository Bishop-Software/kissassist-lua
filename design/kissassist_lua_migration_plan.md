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

### Milestone 4 — Combat Core ✅ COMPLETE
**Goal:** Script fights when controlling a single character.

- `combat.lua` — `CheckForCombat`, `Combat`, `CombatTargetCheck`, `CombatTargetCheckRaid`
- Target selection, assist-at threshold, MA detection, melee engagement

**Done when:** Script assists a main tank and fights using melee and combat disciplines.

---

#### Step 4.1 — `combat.lua` scaffold + array loading + state wiring ✅

Create `modules/combat.lua` with `Combat.init(state, utils, cast)`. Wire into `init.lua`.

- Load DPS, Disc, Burn arrays from INI (`DPS1..DPSN`, `Disc1..DiscN`, `Burn1..BurnN`) into `state.combat` tables
- Wire `state.combat` flags from `Config.get`: `dpsOn`, `meleeOn`, `assistAt`, `burnOn`, `burnOnNamed`, `autoBurnTimer`, `meleeDistance`, `campRadius`, etc.
- Load named-mob watch list (`NamedWatch` / `NamedCheck`) from INI
- Add any missing state fields to `state.lua`

**Done when:** module loads cleanly; DPS/Disc/Burn arrays populated from INI. ✅

---

#### Step 4.2 — MobRadar (mob detection) ✅

Mirrors `MobRadar` (kissassist.mac:7143). Scans XTarget slots 1–13 for NPC haters within `MeleeDistance`.

- Iterate `Me.XTarget[n]`: check `.TargetType == "Auto Hater"`, `.Type == "NPC"`, spawn distance ≤ radius
- Set `state.combat.mobCount` and `state.combat.aggroTargetID` (closest hater ID)
- Handle LOS-only mode (`LOSBeforeCombat`) and DMZ guard

**Done when:** `mobCount` correctly reflects nearby hostile NPCs. ✅

---

#### Step 4.3 — Assist + CombatTargetCheck + GetCombatTarget ✅

- **`Combat.assist(_fromWhere)`** (kissassist.mac:748): non-MA path. Uses `Me.GroupAssistTarget.ID` when group MA is assigned and matches `MainAssist`; falls back to `/assist MainAssist`. Validates target via `validateTarget()` and locks `state.combat.myTargetID`.
- **`Combat.getCombatTarget()`** (kissassist.mac:818): MA/offtank path. Selects best XTarget auto-hater: named > alert-4 > closest with hurt/level tie-breaks. Mem-blurred mob fallback when `mez.mobFlag` set.
- **`Combat.combatTargetCheck(setTarget)`** (kissassist.mac:1337): mid-combat sync. When group MA is active: non-MA syncs to `GroupAssistTarget`; MA locks or accepts new target based on `targetSwitchingOn`. Without group MA: drains `CalledTargetID` from event handlers. Re-targets the game client if `myTargetID` changed.
- **`validateTarget(spawnID)`** (kissassist.mac:948): local helper shared by Assist and GetCombatTarget. Checks bad types, ignore-by-ID list, camp distance (tank roles), eye-of, PC-owned pet, charmed, and PC/Zek rules. Pull-specific checks deferred to Step 5.x.
- **New state fields**: `mez.mezOn`, `combat.targetSwitchingOn`.

**Done when:** `myTargetID` is set correctly when MA has a live NPC targeted.

---

#### ✅ Step 4.4 — CheckForCombat + CombatReset + CheckForAdds

- **`Combat.checkForCombat(skipCombat, fromWhere, waitTime)`** (kissassist.mac:484): outer combat control loop — chaseAssist+moving guard; DMZ/hovering/dead/no-mobs/no-DPS guards; calls `mobRadar`, then MA vs non-MA branching: non-MA runs `assist()` loop with EngageWaitTimer, MA waits for mob in radius then calls `getCombatTarget()`; calls `feignAggroCheck()` after combat; ChainPull==2 exit; calls `checkForAdds()`; non-manual CombatReset if target died. `Combat.fight()` stub present for Step 4.5.
- **`Combat.combatReset(sFlag, calledFrom)`** (kissassist.mac:2144): mez array + immuneIDs + mobsToIgnoreByID cleanup; resets `myTargetID/aggroTargetID2/calledTargetID/combatStart/validTarget/pulled`; `/attack off` + `/target clear`; resets XTarget slot to autohater; sends pet back; clears `attacking/burnActive/dps.target`; clears burn state if burn target died; resets tank+petFollow timers; waits up to 2s for aggroOff timer; drains events. DPS meter output, loot, bard, MQ2Melee deferred.
- **`Combat.checkForAdds(calledFrom)`** (kissassist.mac:2333): calls `mobRadar`; guards (mobCount≤1, DMZ, pulling, !dps/melee, puller past campRadius, dead, chainPull==2, paused); re-acquires valid living target within campRadius; add spam popup + echo; puller-returning guard; tank roles target aggroID; stale myTargetID cleanup.
- **`Combat.feignAggroCheck()`** (kissassist.mac:14524): if aggroOff timer active, loops while feigning/invis draining events; else single `doevents`.
- Wired `Combat.checkForCombat(0, 'main', 0)` into `init.lua` main loop when `dpsOn || meleeOn`.

**Done when:** script enters and exits combat in response to nearby mobs; `CombatStart` flag correct.

---

#### ✅ Step 4.5 — Combat (melee engagement)

Mirrors `Combat` (kissassist.mac:1036) — the inner fight loop.

- **`Combat.fight(fromWhere)`**: entry guards (LOS, mezzed non-MA bailout, puller+pulling+out-of-camp, DPSPaused). CombatRadius = `max(MaxRangeTo, MeleeDistance) + 5`. Determines `inRange` as direct distance OR both MA and target within campRadius.
- **Main engage block** (mob not corpse, HP ≤ assistAt, inRange): `CombatStart` flag — echoes `ATTACKING -> name <-`, local echo for TANKING roles (BroadCast deferred M9). `/look 0` when not underwater. Initiates attack: sets `attacking = true`, stands, taunts for tank/hunter, fires `beforeAttack()`, sends pet via `combatPet()`. CheckStick/ZAxisCheck deferred M7.
- **`beforeAttack(_tarID, condCheck)`** (kissassist.mac:2022): local helper iterating `beforeArray`; tries each entry as item → AA → disc → ability; `condCheck==2` runs only `|cond`-flagged entries. ConOn condition evaluation deferred.
- **`combatPet()`** (kissassist.mac:2056): local helper; guards (no pet, pet in combat, DPSPaused, !combatOn); `combatTargetCheck(1)`; for pettank with ReturnToCamp uses camp-relative follow/attack logic; other roles attack if in `petAttackRange`, follow otherwise; sets `timers.petAttack + 3s`. BreakMez deferred M6.
- **Inner while loop**: event drain each iteration; Burn dispatch via `_cast.doBurn` (stub); NamedWatch stub (sets `namedCheck`); dead/paused target → `combatReset + break`; `_cast.combatCast()` stub (returns `'tcnc'` to restart iteration); `combatTargetCheck(1)`; melee re-attack + `/attack on` when standing; pet re-check each iteration; target-switching MA path (acquire next target or reset); FeignAggroCheck + break if still feigning. MeshButtons/CastMana/WriteDebuffs/Bard/Cures/Heals deferred. ChainPull puller path deferred M5.
- **Out-of-HP-range else-if** (inRange but HP > assistAt or corpse): burn check, `combatTargetCheck(1)`, `combatPet()`, `beforeAttack(myID, 2)` for `|cond` entries.
- **New state fields**: `pet.assistAt = 100`, `pet.combatOn = false` (loaded from `[Pet]` INI in `Combat.init`).
- `Combat.fight(fromWhere)` called from `checkForCombat` when `myTargetID ~= 0`.

**Done when:** script attacks target with melee; `Attacking` flag set. ✅

---

#### Step 4.6 — CombatCast + CastDPSSpellCheck + MashButtons ✅

Mirrors `CombatCast` (kissassist.mac:1616) — DPS spell/AA rotation inside the combat loop.

- **`castDPSSpellCheck(spellName)`** (kissassist.mac:2919): local helper in `modules/cast.lua`. Checks `Target.Buff[name].Caster == Me` to skip re-casting active DoTs. Also checks SPA-470 trigger chains (proc DoTs). Returns true if spell already on target by me.
- **`mashButtons(_tarID)`** (kissassist.mac:1973): local helper in `modules/cast.lua`. Iterates `state.arrays.mashArray`; for each entry fires ready item/AA/disc/skill/command. Retargets if target drifted. Returns without cast if `dpsOn=false`, not in STAND/MOUNT state, no target, or corpse. Cond check deferred M5.
- **`Cast.combatCast()`** (kissassist.mac:1616): public function in `modules/cast.lua`. Iterates `state.combat.dpsArray` starting at `debuffCount+1` (debuff slots handled by WriteDebuffs, deferred Step 4.8). For each entry:
  - Drains events via EventFlag repeat loop before each entry.
  - Validates target (not corpse/dead, not DPSPaused).
  - Parses `|`-delimited entry: `spellName|hpThresh|targetType|opt4|opt5`. Breaks if `hpThresh` is missing/zero.
  - Skips `|weave`, `|mash`, `|ambush` tagged entries (handled elsewhere).
  - Checks readiness (SpellReady/AltAbilityReady/CombatAbilityReady/AbilityReady/ItemReady); skips if nothing ready.
  - Mezzed guard: non-MA skips non-utility spells on mezzed targets.
  - HP% gate: skips if `dpsOn` and target HP > `dpsAt` (per-entry threshold or `assistAt` for MA).
  - Target resolution: `Me`/`Feign` → Me.ID; `MA`/`maonce` → MainAssist (or pet if pettank role); `Group1–5` → Group.Member; default → myTargetID.
  - Self-buff skip: `Me` target already has buff/song → skips.
  - Attack-off for self/MA spells when not MA (restores after cast).
  - Spell cooldown skip: gem-spell while `SpellInCooldown` → `goto next_dps` (DPSOn==2 wait mode deferred).
  - Calls `castDPSSpellCheck` for Mob/Target/default entries to skip active DoTs.
  - Calls `Cast.castWhat(spellName, castTargetID, 'dps')`.
  - Re-enables melee attack if dropped (`/squelch /attack on`).
  - Returns `'tcnc'` if castWhat returns `'tcnc'` (propagates no-combat-restart signal to fight()).
  - Sets `state.dps.lastCast`; echoes spell-on-target for SUCCESS; echoes RESISTED.
  - Per-slot timers (ABTimer/DPSTimer/FDTimer), DAMod, DPSSkip lower bound, WeaveArray/CastWeave, ConOn/CondNo, WriteDebuffs, Feign-death sequence, DPSInterval, DPSOn==2 mode all deferred Step 4.8 / M5.
  - Ends by calling `mashButtons(myTargetID)`.
- `Cast.combatCast` is already wired in `Combat.fight()` inner loop via `if _cast.combatCast then _cast.combatCast() end` (Step 4.5 stub now live).

**Done when:** script casts DPS spells and AAs during combat. ✅

---

#### Step 4.7 — Burn sequence ✅

Mirrors `Burn` (kissassist.mac:11770).

- **`Cast.doBurn()`** (cast.lua): guards (hovering/wrong zone/burnOn off); broadcast "BURN ACTIVATED" on first activation; tribute activation (`/tribute personal on` + `/trophy personal on`, sets `state.timers.tribute + 570s`) when `state.combat.useTribute` set; iterates `state.combat.burnArray` parsing `spell|target` entries, resolves target (Mob/Me/MA/Pet → targetID), calls `Cast.castWhat`; waits for cast window to close (non-bard); sets `state.combat.burnActive = true`. condNo/abortFlag deferred → Step 4.8.
- **`NamedWatch` in `Combat.fight()`** (combat.lua): when `burnOnNamed` and not yet `namedCheck`, checks `sp.Named()` on current target; also walks `namedWatchList` for list-mode detection; on match echoes named alert, calls `Cast.doBurn()`, sets `namedCheck = true`.
- **`state.combat.useTribute`** added to state.lua.
- `/kaburn` bind already sets `state.combat.burnID` (binds.lua:98-114); fight loop clears it after dispatch.
- `AutoBurnTimer` trigger deferred → Step 4.8. BroadCast deferred → M9.

**Done when:** `/kaburn` triggers burn sequence in combat; named mobs auto-burn.

---

#### ✅ Step 4.8 — DoDebuffStuff + AggroCheck + in-game validation

- **`Cast.doDebuffStuff(firstMobID)`** (kissassist.mac:7613): guards (debuffAllOn, debuffCount, DPSPaused, DMZ, bard+MA bailout); cleans stale mob IDs from per-slot dboLists; calls `debuffCast(firstMobID, true)` for primary target; iterates XTarget auto-haters in range (LOS check, PC/PC-pet skip, distance guard), drops melee for off-target cast, calls `debuffCast(xtID, fwait)` for each; restores target + melee after loop.
- **`debuffCast(targetID, fwait)`** (kissassist.mac:7714): local helper in cast.lua. Iterates DPS slots 1..debuffCount; per slot: checks dboTimer/dboList to skip recently-debuffed mobs; verifies cast range vs effective spell range; checks spell/AA/disc readiness (fwait=true waits up to 2s for primary mob); calls `Cast.castWhat`; on SUCCESS updates dboList[i] and sets dboTimer[i] from spell duration.
- **`Combat.aggroCheck()`** (kissassist.mac:2373): guards (myTargetID, corpse check, MA target-sync); iterates `state.combat.aggroArray`; per entry: parses `spellName|pct|glt|target`; skips active self-disc; checks ability readiness; applies threshold (`<` gain / `<<` secondary / `>` lose); resolves target (null/Mob/INC → myTargetID, Me/MA/Pet); calls `_cast.castWhat(..., 'Aggro', ...)`; on SUCCESS echoes and breaks; sets aggroOff timer on lose-aggro cast if feigning/invis.
- **`Combat.init` additions**: `debuffAllOn` from `[DPS] DebuffAllOn`; `debuffCount` computed from DPS array (entries with hp threshold ≥ 101 are debuff-all slots); `aggroOn` from `[Aggro] AggroOn`; `aggroArray` loaded from `Aggro1..AggroN`.
- **State fields added**: `combat.aggroArray`, `combat.aggroOn`, `combat.debuffAllOn`, `combat.dboList`, `combat.dboTimer`.
- **Wired into `Combat.fight()`**: `aggroCheck` called each inner loop iteration when `aggroOn`; `doDebuffStuff` called before `combatCast` when `debuffAllOn > 0`; `doDebuffStuff` called in out-of-HP-range block when `debuffAllOn == 2`.
- **Note**: `Sub WriteDebuffs` at mac:12569 writes self-debuff status to `KissAssist_Buffs.ini` for healers — that belongs to the cures system (M5). Step 4.8's debuff-casting is `DoDebuffStuff` + `DebuffCast`.

**Done when:** script fights end-to-end: detect → assist → melee → DPS → debuffs → burn → reset.

---

**Suggested order:** 4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6 → 4.7 → 4.8. Each step depends on the previous.

---

### Milestone 5 — Healing & Recovery ✅ COMPLETE
**Goal:** Character keeps self and group alive; dead players get rezzed; debuffs get cured.

- `healing.lua` — `CheckHealth`, `DoGroupHealStuff`, `CheckCures`, `RezCheck`, `RezWithCheck`
- Health threshold triage, MQ2Rez plugin event handling

**Done when:** Healer classes heal group members and rez dead players.

---

#### ✅ Step 5.1 — `healing.lua` scaffold + INI wiring + state audit

Create `modules/healing.lua` with `Heal.init(state, utils, cast)`. Load all heal config from INI into `state.heal`: `healsOn`, `sHealPct`, `groupWatchPct`, `healRemChk1–3`, `autoRezAll`, `corpseRezCheck`, medding thresholds, single-heal flags. Audit `state.heal` in `state.lua` for any missing fields and add them. Wire `Heal.init` into `init.lua`. Wire `/addimmune` bind (currently a stub in `binds.lua`).

- **`modules/healing.lua`** created with `Heal.init(state, utils, cast)`. Loads `[Heals]`, `[Cures]`, and `[General]` med/group-watch config into `state.heal`. `GroupWatchOn` pipe-format (`1|pct`) parsed to split `groupWatchOn` and `groupWatchPct`. Stub comments for Steps 5.2–5.6.
- **`state.lua` heal table** — 16 new fields added: `healsOn`, `healsArray`, `curesOn`, `curesArray`, `healInterval`, `autoRezOn`, `xTarHeal`, `xTarHealList`, `healGroupPetsOn`, `rezMeLast`, `medOn` (default true), `medStart` (20), `medStop` (100), `medCombat`, `groupWatchOn`, `corpsRecoveryOn`.
- **`init.lua`** — `Heal` required; `Heal.init(State, Utils, Cast)` called after `Combat.init`.
- **`/addimmune` bind** (`binds.lua`) — targets current NPC; strips `#` prefix and corpse suffix; appends ID to `state.mez.immuneIDs`; persists name to `InfoFileName` INI under zone key `MezImmune`.

**Done when:** module loads cleanly; heal state fields populated from INI. ✅

---

#### ✅ Step 5.2 — `CheckHealth`: self-triage + single-heal dispatch

Port `Sub CheckHealth` — the main health triage entry point. Self-heal path (`sHealPct` threshold, `singleHealPoint`), MA-heal path, group member scan (lowest HP below threshold). Guards: dead, hovering, DMZ, medding, mezzed. Calls `Cast.castWhat(..., 'SingleHeal')`.

**Done when:** script heals self when HP drops below threshold. ✅

**Implemented:**
- `state.lua`: `healsOn` changed to integer (0–4); `singleHealPoint/MA/Range` changed from `false` to `0`; `session.heals` field added
- `Heal.init()`: `healsOn` loaded as `tonumber`; `singleHealPoint/MA/Range` computed from `healsArray` (mirrors `FindSingleHeals` mac:12012); `state.session.heals` wired to `healsOn > 0`
- `healing.lua`: `local singleHeal()` iterates `healsArray`, finds first spell where threshold ≥ hpPct, calls `_cast.castWhat(spell, targetID, 'SingleHeal')`
- `healing.lua`: `Heal.checkHealth(sentFrom)` — guards (healsOn==0, invis, medding), self-heal, MA OOG heal (healsOn 1/3), group member scan (lowest HP, berserker cap, pet check if `healGroupPetsOn`); stubs for Steps 5.3–5.5

---

#### ✅ Step 5.3 — `DoGroupHealStuff`: group heal + HoT + medding

Port `Sub DoGroupHealStuff`. Count group members below `groupWatchPct`; decide single-target triage vs AoE/group heal. HoT (heal-over-time) slot management. Medding: sit-to-med control (`state.heal.medding`, `state.timers.sitToMed`), interrupted-medding event wiring (deferred from Step 2.2).

**Done when:** script fires group heals when multiple members are low.

✅ **Implemented:**
- `state.lua`: added `heal.groupHealArray` (filtered group-target spells) and `heal.groupHealTimers` (per-slot `os.clock()` expiry, mirrors `SpellGH${j}` mac timers)
- `healing.lua` `Heal.init()`: builds `groupHealArray` from `healsArray` via `FindGroupHeals` filter (TargetType contains 'group' or is 'Targeted AE' without MA/ME tag); initializes `groupHealTimers`; derives `medStat` (Mana vs Endurance) from class (mirrors `DoWeMed` mac:3852)
- `healing.lua` `Heal.doGroupHealStuff()`: iterates `groupHealArray`; breaks on empty/zero-threshold entry (mirrors mac:6749 `/return`); checks per-slot timer; fires `castWhat(..., 'GroupHeal')` when `Group.Injured(pct) > 1`; sets HoT timer to `os.clock() + MyDuration` on success
- `healing.lua` `Heal.checkHealth()`: replaced Step 5.3 stub with `Heal.doGroupHealStuff()` call gated by `GROUP_HEAL_CLASSES` and `Group.AvgHPs < 100 && Injured(90) > 1`
- `healing.lua` `Heal.doWeMed()`: simplified port of `DoWeMed` (mac:3836) — guards (medOn, medCombat, Moving), sits when `pct < medStart`, stands when `pct >= medStop`, re-sits if interrupted mid-med; full `MeddingInterrupted` state machine deferred to Step 5.6
- Wiring `Heal.doWeMed()` into `init.lua` main loop deferred to Step 5.6

---

#### ✅ Step 5.4 — `CheckCures` + `WriteDebuffs`

Port `Sub CheckCures`: iterate cure array from INI, check group members for matching debuffs by SPA type, call `Cast.castWhat` with `'cure'` sentFrom. Port `Sub WriteDebuffs` (mac:12569): write self-debuff status to `KissAssist_Buffs.ini` for cross-character healer awareness. Wire `MezBroke` timer reset that was deferred in Step 2.2.

**Done when:** script removes debuffs from group members; `KissAssist_Buffs.ini` updated with self-debuff state.

✅ Implemented (May 13 2026):
- `state.lua`: Changed `heal.curesOn` from `false` (boolean) to `0` (integer, 0=off 1=everyone 2=self 3=group)
- `healing.lua` `Heal.init()`: Load `curesOn` as integer via `tonumber()`, not boolean comparison
- `healing.lua` `Heal.writeDebuffs()`: Port of mac:12569 — computes debuff sum (Poisoned/Diseased/Cursed/Corrupted/Mezzed + Restless Curse song), writes `count|poison|disease|curse|corrupt|mez` format to `KissAssist_Buffs.ini` under `[Me.ID]`; clears entry when clean; only updates on state change (needCuring flag gate)
- `healing.lua` `Heal.checkCures()`: Port of mac:12596 — guards (curesOn=0, invis, medding+medCombat); builds target ID list from ini sections (CuresOn=2=self only, else reads `KissAssist_Buffs.ini` section names); for each target: skip corpse/distance>100/non-group (curesOn=3); for each cure entry: parse SpellName|debuffType|scope|condN, check ready, fetch debuff state (live TLO for self, ini cache for others), type-match, group-spell guard; calls `castWhat` with sentFrom='Cure'; on success broadcasts cure and re-checks health; after self-cure refreshes `writeDebuffs`; DanNet path omitted (deprecated)
- `healing.lua` `checkHealth()`: Stub comment updated — `checkCures` is wired from combat loop in Step 5.6 (not from checkHealth, to avoid recursion since checkCures calls checkHealth internally)
- `events.lua` MezBroke deferred item: `_state.mez.broke = false` reset added at end of `checkCures()`

---

#### ✅ Step 5.5 — `RezCheck` / `RezWithCheck`

MQ2Rez integration. `RezCheck`: scan for dead group members needing rez, check `autoRezAll`. `RezWithCheck`: validate rez target is recoverable (not LD, not already rezzing), call `Cast.castWhat` with `'Rez'` sentFrom. `corpseRezCheck` state management. Rez sickness guard.

**Done when:** script rezzes dead group members using MQ2Rez.

**Implemented:**
- `state.lua`: `autoRezOn` changed from boolean to integer (0=off, 1=normal, 2=OOC-only); added `autoRezArray = {}`, `battleRezTimers = {0,0,0,0,0}`, `oocRezTimers = {}`. Removed duplicate boolean `autoRezOn` field.
- `healing.lua` `Heal.init()`: loads `autoRezOn` via `tonumber()`; loads `AutoRez` array from `[Heals]` INI section; debug log updated.
- `healing.lua` `rezWithCheck()` (local): selects first ready rez spell from `autoRezArray` filtered by combat state vs rez type (rez/rezooc/rezcombat). Returns spell name or nil. Condition eval (ConOn) deferred to Step 6+.
- `healing.lua` `Heal.rezCheck()`: guards (autoRezOn, DMZ+instance, hovering, invis+no-aggro, autoRezOn==2+combat). Phases: MA corpse → self (if !rezMeLast) → group slots 1-5 with `battleRezTimers` → self (if rezMeLast) → OOC `autoRezAll` pass with `corpseRezCheck` try-count tracking (max 3). Per-corpse `oocRezTimers` replace mac dynamic timer variables.
- `healing.lua` `checkHealth()`: stub replaced with `if _state.heal.autoRezOn > 0 then Heal.rezCheck() end`.
- Test plan: Section 5.6 added (39 test cases 5.6.1–5.6.45). Known Deferred updated.

---

#### ✅ Step 5.6 — Wire into combat loop + main loop

Add `Heal.checkHealth()` and `Heal.checkCures()` calls in `Combat.fight()` inner loop (currently commented as deferred). Add heal/rez/cure checks to the `init.lua` main loop for out-of-combat contexts. Verify heal interrupts in `castSpell` fire correctly when `sentFrom == 'SingleHeal'` or `'GroupHeal'` (cast interrupt guards for those sentFrom values are already stubbed in `cast.lua`).

**Done when:** heals fire mid-combat and out-of-combat; rez fires after fights.

**Implemented:**
- `combat.lua`: Added `_heal` module-level local; `Combat.init(state, utils, cast, heal)` now stores the Heal module reference.
- `combat.lua` `fight()` inner loop (after `AggroCheck`, mac:1166-1167): `_heal.checkCures()` then `_heal.checkHealth('Combat')`.
- `combat.lua` `fight()` inner loop (after DPS casts, mac:1200-1215): `_heal.writeDebuffs()`, `_heal.checkCures()`, `_heal.checkHealth('Combat2')`.
- `combat.lua` `checkForCombat()` non-MA assist loop: `_heal.checkHealth('CheckForCombat')` after each `Combat.assist()` call.
- `combat.lua` `checkForCombat()` skipCombat==1 path (mac:563-580): `_heal.checkCures()` + `_heal.checkHealth('SkipCombat')` when skipCombat==1 and heal module present.
- `init.lua`: `Heal.init()` now runs before `Combat.init()` so Heal can be passed as 4th arg; `Combat.init(State, Utils, Cast, Heal)`.
- `init.lua` main loop: `Heal.writeDebuffs()`, `Heal.checkHealth('MainLoop')`, `Heal.checkCures()`, `Heal.doWeMed()` called every tick after combat pass (internal guards handle all no-op cases).
- `cast.lua`: `SingleHeal`/`GroupHeal` invis guards already present in `castSpell`, `castAA`, `castDisc`, `castItem`, `castMem` — no changes needed.

---

**Suggested order:** 5.1 → 5.2 → 5.3 → 5.4 → 5.5 → 5.6. Steps 5.2 and 5.3 can be worked together since they share the same triage scan logic.

---

### Milestone 6 — Buff System ✅ COMPLETE
**Goal:** Self-buffing and group buffing work.

- `buffs.lua` — `CheckBuffs`, `WriteBuffs`, `WriteBuffsPet`, `WriteBuffsMerc`, `CheckBegforBuffs`, `CheckPetBuffs`, `CheckBegforPetBuffs`
- Cross-character buff state via `KissAssist_Buffs.ini` (DanNet shim deferred; actors path in M9/comms.lua)

**Done when:** Characters self-buff on startup, rebuff when worn off, group-buff group members, `/buffgroup` forces a full rebuff cycle.

---

#### Step 6.1 — `buffs.lua` scaffold + INI wiring + state audit ✅

Create `modules/buffs.lua` with `Buffs.init(state, utils, cast)`. Load all buff config from INI and audit `state.buffs` for missing fields.

- **`[Buffs]` INI section** (mac:14657–14671): `buffsOn`, `buffsSize` (default 20), `buffsArray[]` (loaded same pattern as `dpsArray`), `rebuffOn`, `checkBuffsTimer`, `powerSource`
- **Mount fields**: `mountOn`, `mountSpell` — triggered from within CheckBuffs (mac:4200)
- **`[Pet]` INI section**: `petBuffsOn`, `petBuffsArray[]`
- **New state fields in `state.buffs`**: `buffsOn`, `buffsArray`, `rebuffOn`, `checkBuffsTimer`, `powerSource`, `mountOn`, `mountSpell`, `petBuffsOn`, `petBuffsArray`, `blockedBuffsCount`
- **New timer fields in `state.timers`**: `writeBuffs`, `readBuffs`, `petBuffCheck`
- **Per-slot per-member timers**: `state.buffs.slotTimers[i][j]` — 2D table replacing `.mac`'s dynamic `Buff${i}GM${j}` variables (`i` = spell slot 1–buffsSize, `j` = group member 0–5)
- Wire `Buffs.init(State, Utils, Cast)` into `init.lua` before main loop

**Done when:** module loads cleanly; `state.buffs.buffsArray` and `state.buffs.petBuffsArray` populated from INI.

---

#### Step 6.2 — `WriteBuffs` + `WriteBuffsPet` + `WriteBuffsMerc` ✅

Port the three buff-state export functions (mac:17072, mac:12318, mac:12364). These write each character's current buff/blocked-buff list to `KissAssist_Buffs.ini` so other characters can check what buffs are already present before casting.

- **`Buffs.writeBuffs()`** (mac:17072): guards (`timers.writeBuffs`, in-combat, DanNet active); writes `Day/Hour/Zone/Buffs/Blockedbuffs/AmILooting/MyRole` under `[Me.ID]`; iterates 41 buff slots + `blockedBuffsCount` (30 emu / 40 live) blocked slots; sets `state.timers.writeBuffs = os.clock() + 30`
- **`Buffs.writeBuffsPet()`** (mac:12364): writes pet's current buff list under `[Me.ID_pet]` key
- **`Buffs.writeBuffsMerc()`** (mac:12318): writes merc buff list (merc-only guard via `state.session.mercOn`)
- Wire into `init.lua` main loop: runs when `CombatState != COMBAT && !DanNetOn` (mirrors mac:398–401)

**Done when:** `KissAssist_Buffs.ini` updated with character's buff list every 30s out of combat.

---

#### Step 6.3 — `CheckBuffs`: entry parsing + self / group-type dispatch ✅

Port the entry point, loop guards, and the two simplest target-type branches (mac:4170–4521).

- **Guards** (mac:4171): `!buffsOn`, dead, hovering, invis (non-Rogue), chaseAssist+moving, whoToChase==me+moving → return
- **PowerSource refuel** (mac:4192–4198): if PowerSource item exists with no charge, click to destroy cursor and refill
- **Mount cast** (mac:4200): `mountOn && !Me.Mount.ID && (Zone.Outdoor || Type 1/2/5) && OOC` → local `castMount()` helper
- **Per-entry loop** (mac:4207): iterates `buffsArray[]`; drains events each iteration; aggro bail (distance < 200), invis bail, `|0` skip, interleaved cure/heal/rez check (mirrors mac:4218–4227), `calledTargetID` sync
- **Entry parsing** (mac:4233–4272): `|`-split into `spellToCast`, `2ndPart`..`5thPart`; `Dual` tag normalization; `alias` entry skip; `|cond` prefix cleared (ConOn deferred to M10)
- **`buffToCheck` resolution** (mac:4273–4293): gold subscription strips ` Rk.` suffix from check name for non-Dual entries; Dual entries check `3rdPart` instead
- **`bookSpellTT` / `spellRange`** (mac:4295–4305): derive target type and effective range from spell book; default range 100
- **Combat/invis/timer bail** (mac:4308–4309): if in COMBAT with aggro, or `readBuffsTimer`, or dead/invis → return
- **Condition check** (mac:4311–4315): `|cond` number extraction; ConOn evaluation deferred to M10 (always passes)
- **`group v` target type** (mac:4491–4521): cast group buff on self; skip if `slotTimers[i][0]` set; drain `WornOff` events; `CastWhat(..., 'Buffs-nomem')`; set timer on SUCCESS/TAKEHOLD
- **`self` target type** (mac:4640–4647): check `Me.Buff[buffToCheck]` / `Me.Song[buffToCheck]`; `CastWhat` on Me.ID

**Done when:** script self-buffs and casts group-type buffs on self when `BuffsOn=1`.

**Implemented:** `Buffs.checkBuffs(forceGroup)` added to [modules/buffs.lua](../modules/buffs.lua). Local helpers `castMount()` and `refuelPowerSource()` handle the pre-loop actions. `DUAL_TAGS` set used for `buffToCheck` resolution. `Buffs.init()` extended to accept a 4th `heal` parameter (`_heal` stored for interleaved cure/heal/rez calls). `Buffs.checkBuffs()` wired into [init.lua](../init.lua) main loop after write functions. Steps 6.4/6.5 branches (single-target, special tags) fall through to `::continue::` stub.

---

#### Step 6.4 ✅ — `CheckBuffs`: single-target group iteration + class filters

Port the single-target path that iterates each group member and all class-filter tags (mac:4523–4638).

- **Single-target group loop** (mac:4525–4613): iterate `j` from `Group` downto `0`; skip if member not alive, distance ≥ `spellRange`, or `slotTimers[i][j]` > 0
- **`|me` / `|Dualme`**: skip if `j > 0` (self only)
- **`|MA` / `|DualMA`**: skip if member is not the main assist spawn
- **`|!MA`**: skip if member IS the main assist
- **`|Melee` / `|DualMelee`**: skip non-melee classes (`BRD,BER,BST,MNK,PAL,ROG,RNG,SHD,WAR`)
- **`|Caster` / `|DualCaster`**: skip non-caster classes (`CLR,DRU,SHM,BST,ENC,MAG,NEC,PAL,SHD,RNG,WIZ`)
- **`|class` / `|Dualclass`**: skip if member's ShortName not in `5thPart` list
- **`|!class` / `|Dual!class`**: skip if member's ShortName IS in `5thPart` list
- **Per-cast**: mana check; spell cooldown wait (up to 6s gem timer); aggro bail mid-loop; `WornOff` drain; `CastWhat(..., 'Buffs-nomem')`; `slotTimers[i][j]` set on SUCCESS/TAKEHOLD/HASBUFF; components error disables slot
- **Pet extension** (mac:4580–4609): DanNet path skipped (stub); non-DanNet path: pet buff via DanNet only — omit for now
- **No-group fallback** (mac:4614–4637): when no group and no class-filter tags, cast on Me.ID

**Done when:** script buffs each group member individually with single-target spells, respecting per-slot-per-member timers.

**Implemented:** `isSingle` detection added to `Buffs.checkBuffs()` in [modules/buffs.lua](../modules/buffs.lua). Module-level constants `CASTER_CLASSES`, `MELEE_CLASSES`, `CLASS_FILTER_TAGS`, and local helper `classInList()` added. Group loop iterates `j` from `Group.Members()` downto 0; skips dead/out-of-range/timer-active members; applies `|me`, `|MA`, `|!MA`, `|Melee`, `|caster`, `|class`, `|!class` filters (and their Dual variants). Per-cast mana check breaks the j loop; gem timer wait (up to 6s) with aggro bail; `WornOff` drain via `mq.doevents()`; `castWhat(..., 'buffs-nomem')`; `slotTimers[i][j]` set on SUCCESS/TAKEHOLD/HASBUFF using `Spell.MyDuration.TotalSeconds()`; COMPONENTS nulls slot. No-group fallback casts on Me.ID when `CLASS_FILTER_TAGS[p2]` is false. DanNet pet extension deferred to M9. `p5` unused-local hint resolves (consumed by class/!class dispatch).

---

#### Step 6.5 ✅ — `CheckBuffs`: special action tags + `CheckBegforBuffs`

Port the remaining `2ndPart` action branches and the beg-for-buffs subsystem (mac:4319–4403, mac:13199–13303).

- **`|Endgroup` / `|Managroup`** (mac:4319–4328): `regenOther()` local helper — find lowest-resource group member, cast regen spell, set `slotTimers[i][0]`
- **`|mana`** (mac:4329–4338): cast mana-regen on self if `PctMana > threshold` or HP < threshold
- **`|End`** (mac:4341–4342): endurance disc/AA when `PctEndurance <= threshold`; checks `CombatAbilityReady` or `AltAbilityReady`
- **`|Remove`** (mac:4344–4348): `/removebuff spellName` if buff/song slot active; condition-guarded
- **`|Aura`** (mac:4353–4354): `checkAura()` local helper — cast aura if `Me.Aura[1]` not matching
- **`|Once`** (mac:4356–4361): `buffOnce()` — cast once; on SUCCESS set entry to `spellName|0` to disable
- **`|summon`** (mac:4363–4369): stub — `printf` + continue (full SummonStuff deferred)
- **`|mgb` / `|dualmgb`** (mac:4370–4371): stub — call `castWhat` without MGB flag; full `massGroupBuff()` deferred
- **`|begfor|alias`** (mac:4372–4393): broadcast beg request via `Comms.broadcast` if item/buff count below threshold; sets 900s `slotTimers[i][0]`
- **`|command:`** (mac:4395–4399): `targetTag()` resolution then `CastWhat(..., 'Buffs')`
- **`Buffs.checkBegforBuffs()`** (mac:13199): iterates `state.buffs.kaBegForList` pipe-delimited queue; resolves `buffToCast` from `buffsArray[idx]`; casts on requesting PC; calls `removeFromBegList()` on SUCCESS/RECOVER or self-type; increments index on other failures; clears `kaBegActive` when list empty
- **`removeFromBegList()`** (mac:13249): local helper — removes entry from `kaBegForList`; handles AE-item dedup (same alias+slot entries) and single-type dedup

**Done when:** beg-for-buff queue processes correctly; special action tags (Aura, Once, Remove, mana, End) fire.

**Implemented:** Special action tag chain inserted in `Buffs.checkBuffs()` in modules/buffs.lua BEFORE the group-v/self/single target-type dispatch (matching the mac's structural ordering). Module-level helpers added: `regenOther()` iterates group members by stat class sets (REGEN_END_CLASSES / REGEN_MANA_CLASSES), casts on lowest-stat qualifying member, skips MA for Rallying Call and BRD for Dichotomic/Quiet Miracle; `checkAura()` strips ` Rk.` suffix, applies class-specific name corrections (Disciples Aura, Reverent Aura, Mana Rev., etc.), checks aura slots 1+2 for CLR/ENC, handles Mage TempAura via PetBuff scan, casts via `/disc` for BER/MNK/ROG/WAR endurance classes or via `castWhat('CheckAura')`; `buffOnce()` casts on Me.ID with sentFrom `'BuffOnce'`, returns bool; `checkEndurance()` stands if sitting, casts with sentFrom `'CheckEndurance'`; `getListArg()` parses pipe-delimited strings by 1-based index. Elseif chain: `|Endgroup`/`|Managroup` → regenOther + timer set (dur×10); `|mana` → cast if PctMana ≤ p3 AND PctHPs ≥ p4; `|End` → checkEndurance if PctEndurance ≤ p3 AND CA/AA ready; `|Remove` → removebuff if buff/song active; global mana bail elseif (non-begfor entries, spell.Mana > currentMana); `|Aura` → checkAura; `|Once` → buffOnce + entry set to `spellName|0`; `|summon` → printf stub; `|mgb`/`|DualMgb` → castWhat stub (MGB deferred); `|begfor` → `/bc KABeg for ...` + 900s timer; `command:` → simplified target (Target.ID or Me.ID) + castWhat. `Buffs.checkBegforBuffs()` added: iterates kaBegForList pipe-delimited queue, parses alias:charName:buffIdx entries, resolves buffToCast from buffsArray, determines spellType from Book/AltAbility TLO, casts on PC by name; calls `removeFromBegList()` on SUCCESS/RECOVER or self-type; increments idx on other failures; clears kaBegActive when list empty. `removeFromBegList()` local helper: parses list to table, removes primary entry, AE-item/self dedup (same part1+part3), single-type dedup. Stub comment removed. `/bc` used for begfor broadcast (DanNet/Comms M9). TargetTag full resolver deferred to M7.

---

#### Step 6.6 ✅ — `CheckPetBuffs` + `CheckBegforPetBuffs`

Port the pet-specific buff functions (mac:5402–5517, mac:13307+).

- **`Buffs.checkPetBuffs()`** (mac:5402): guards (`Me.Pet.ID`, `petOn`, `petBuffsOn`, `combatStart`, `pulling`, `timers.petBuffCheck`, invis); sets `state.timers.petBuffCheck = os.clock() + 60`; iterates `petBuffsArray`; per-entry: parse `1stPart|2ndPart|3rdPart`; `|dual` tag = different cast name vs buff check name; check spell in book vs item vs ability; scan 50 pet buff slots for `PTempBuff` match via `Me.PetBuff[j].Name`; if not found: `castWhat(1stPart, Me.Pet.ID, 'Pet-nomem')`; `|pettoys|begfor` — `Comms.broadcast('PetToysPlease Me.Pet.Name')` + timer; pet shrink after loop if `petShrinkOn`; clear target if pet was targeted
- **`Buffs.checkBegforPetBuffs()`** (mac:13307): iterates `state.buffs.kaBegForPetList`; resolves pet ID from group member name; casts pet toy spells; removes entries after success; clears `kaPetBegActive` when list empty
- Wire both into `init.lua` main loop after pet check (matches mac:396–397)

**Done when:** script buffs own pet from `petBuffsArray`; group pet toy requests processed.

**Implemented:** `Buffs.checkPetBuffs()` added to modules/buffs.lua: guards on `Me.Pet.ID`, `state.pet.on`, `state.buffs.petBuffsOn`, `state.session.combatStart`, `state.combat.pulling`, `state.timers.petBuffCheck`, and `Me.Invis`; sets `petBuffCheck = os.clock() + 60`; iterates `petBuffsArray` with `mq.doevents()` and aggro bail per iteration; per-entry: parses `part1|part2|part3` via `getListArg`; `|dual` tag causes `part3` (buff check name) to differ from `part1` (cast name), otherwise `part3 = part1`; strips ` Rk.` suffix for pet buff slot scan; if spell in book or AltAbility: scans 50 `Me.PetBuff(j).Name` slots for partial match, casts via `castWhat(part1, Pet.ID, 'Pet-nomem')` if not found, echoes on SUCCESS, nulls entry on COMPONENTS; if item (FindItem): same 50-slot scan, casts via `castWhat(part1, Pet.ID, 'Pet')`; if `pettoys|begfor`: broadcasts `/bc PetToysPlease petName` + sets 90s `_petBegTimers[i]` + sets `kaPetBegActive = true`; after loop: shrinks pet if height > 1.35 and `shrinkOn`/`shrinkSpell` set; clears target if pet was targeted. `Buffs.checkBegforPetBuffs()` added: guards on `state.pet.toysOn`, `Me.Invis`, `kaBegForPetList` non-empty; iterates pipe-delimited `kaBegForPetList`; entry `"group"` iterates group members 1–5 filtering by `PET_CLASSES` and `Spawn.Type == Pet`, casts `toysArray[1]` on each qualifying pet; individual entry resolves pet ID via `Spawn('pet name').ID`, casts; on SUCCESS removes entry from list and clears `kaPetBegActive` when list empty; on CAST_CANCELLED breaks; otherwise advances index. Both wired into init.lua main loop: `if State.pet.on then checkPetBuffs() end` and `if State.pet.toysOn and kaPetBegActive then checkBegforPetBuffs() end`. `Buffs.init()` extended to load `state.pet.on`, `state.pet.shrinkOn`, `state.pet.shrinkSpell`, `state.pet.toysOn`, `state.pet.toysArray` from `[Pet]` INI. `state.lua` pet table extended with `on`, `shrinkOn`, `shrinkSpell`, `toysOn`, `toysArray` fields.

---

#### Step 6.7 ✅ — Wire into main loop + `/buffgroup` + `/tbmanager` + `CastBuffsSpellCheck`

Final wiring pass to make the full buff system live (mirrors mac:398–407).

- **`init.lua` main loop** — add in correct order after existing heal calls:
  1. `if OOC and not DanNet: Buffs.writeBuffs(); Buffs.writeBuffsMerc(); Buffs.writeBuffsPet()`
  2. `if state.buffs.buffsOn: Buffs.checkBuffs(state.buffs.forceBuffs); state.buffs.forceBuffs = false`
  3. `if state.buffs.kaBegActive: Buffs.checkBegforBuffs()`
  4. `if state.pet.on: Buffs.checkPetBuffs()`
  5. `if state.pet.toysOn and state.buffs.kaPetBegActive: Buffs.checkBegforPetBuffs()`
- **`/buffgroup` bind** (binds.lua): set `state.buffs.forceBuffs = 1`; reset `state.timers.iniNext = 0`; call `Buffs.checkBuffs(1)` directly
- **`/tbmanager` bind** (binds.lua): add/remove entries from `state.buffs.extendedList` (too-buff list manager); persist to INI under `[Buffs]`
- **`cast.lua` `castBuffsSpellCheck()`**: replace the stub that always returns `false` — check `mq.TLO.Me.Buff(spellName).ID()` and `mq.TLO.Me.Song(spellName).ID()` to skip redundant buff casts (same role as `.mac`'s `BuffsNotAnItem` pattern in CastWhat dispatcher, Step 3.5)
- **`cast.lua` interrupt guards**: add `'Buffs'` and `'Buffs-nomem'` to the sentFrom values that bypass the invis check in `castSpell`, `castAA`, `castDisc`, `castItem`, `castMem` (same pattern as `'SingleHeal'`/`'GroupHeal'` from M5)

**Deferred (not needed for M6):**
- Full `massGroupBuff()` — MGB helper is low-frequency; stub returning nil
- `SummonStuff` helper — niche use case; stub with printf
- DanNet cross-query in single-target loop (mac:4469–4489) — the entire DanNet block is commented out in the `.mac` source; omit
- ConOn condition evaluation — deferred to M10 (always passes for now)

**Done when:** characters self-buff on startup, rebuff when worn off, group-buff all members, `/buffgroup` forces a full rebuff cycle.

**Implemented:** `init.lua` main loop rewritten — `writeBuffs`/`writeBuffsPet`/`writeBuffsMerc` now gated on `not combatStart and not danNetOn`; `checkBuffs` gated on `buffsOn` and receives `forceBuffs` (reset to false after); `checkBegforBuffs()` added after `checkBuffs`. `Binds.register` now accepts a third `Buffs` argument; `onBuffGroup` sets `forceBuffs=true`, clears `iniNext`, and calls `Buffs.checkBuffs(true)` directly; `onTbManager` implements add/remove on `state.buffs.extendedList` with INI persistence under `[Buffs]`. `cast.lua`: `castBuffsSpellCheck(spellName)` added (checks `Me.Buff` + `Me.Song`; full WillStack/SPA-374/340 deferred to M10); wired into `castWhat` for `sentFrom == 'Buffs'` or `'buffs-nomem'`; `'Buffs'` and `'buffs-nomem'` added to the invis-bypass sentFrom set in `castSpell`, `castAA`, `castDisc`, `castItem`, and `castMem`.

---

**Suggested order:** 6.1 → 6.2 → 6.3 → 6.4 → 6.5 → 6.6 → 6.7. Steps 6.2 and 6.6 can be worked in parallel with 6.3–6.5 once 6.1 is done. Steps 6.3 and 6.4 are one logical function split by complexity.

---

### Milestone 7 ✅ — Pulling & Movement

**Goal:** Puller roles work; all characters return to camp.

- `pull.lua` — `FindMobToPull`, `PullValidate`, `PullCheck` (melee/ranged/spell/pet/nav)
- `movement.lua` — `DoWeMove`, `DoWeChase`, `Stuck`, MQ2Nav/MQ2AdvPath integration

**Done when:** Puller finds a valid mob, announces the pull, engages with the configured pull method, returns to camp; group fights within camp radius; non-puller characters return to camp automatically; chase mode follows MA; all 5 pull bind stubs respond correctly; `CheckStick` engages during combat.

---

#### Step 7.1 ✅ — `movement.lua` scaffold + INI wiring

Create `modules/movement.lua` with `Movement.init(state, utils)`. Load all movement config from INI into state. Wire into `init.lua`.

**INI fields to load** (from `Config.get`):
- `[General]`: `ReturnToCamp`, `CampRadius`, `CampRadiusExceed`, `ChaseAssist`, `WhoToChase`, `DontMoveMe`, `StayPut`, `StickDist`, `StickDistUW`, `StickHow` (d/mp/!), `NavPathHelper`, `LocDelayCheckUW`, `FaceMobOn`, `ScatterOn`, `ScatterDistance`
- `[Pull]`: `PullMoveUse` (los/nav/advpath), `MaxRadius`, `MaxZRange` (seed `state.pull.waypointZRange`)

Audit `state.movement` for any missing fields and add them. Module exports stubs for Steps 7.2–7.4: `doWeMove`, `doWeChase`, `stuck`, `zAxisCheck`, `checkStick`. Wire `Movement.init(State, Utils)` into `init.lua` (after `Buffs.init`); pass `Movement` into `Combat.init` as a 5th arg so `combat.lua` can call `checkStick`.

**Done when:** module loads cleanly; `state.movement.campRadius`, `state.movement.returnToCamp`, `state.movement.pullMoveUse`, etc. populated from INI. ✅

✅ **Implemented (2026-05-16):**

- `state.lua`: added `faceMobOn`, `scatterOn`, `scatterDistance` to `state.movement`; `campRadiusExceed` added.
- `modules/movement.lua` created: `Movement.init(state, utils)` loads all `[General]` and `[Pull]` movement INI fields; local helpers `dist2D`, `isPullerRole`, `isPullerOrHunterRole`; stubs for `doWeMove`, `doWeChase`, `stuck`, `zAxisCheck`, `checkStick`.
- `combat.lua`: `Combat.init` updated to accept `Movement` as 5th arg; `_movement` upvalue stored; duplicate `campRadius`/`campRadiusExceed` INI loading removed.
- `init.lua`: `Movement` module required; `Movement.init(State, Utils)` wired; `Combat.init` call updated to pass `Movement`.

---

#### Step 7.2 ✅ — `Movement.doWeMove` (camp return, all nav modes)

Port `DoWeMove` (kissassist.mac:3342–3663, 321 lines). Read the full source before implementing.

**Guards** (mac:3344–3367): return if `dontMoveMe`, `chaseAssist`, `hovering`, `iAmDead`, `justZoned`, invis-with-aggro, `stayPut` (except `forceFlag==1`), campZone mismatch, CombatState == COMBAT with aggro.

**Camp radius check** (mac:3368–3400): compute 2D distance to camp (`Math.Distance[campY,campX:Me.Y,Me.X]`); call `zAxisCheck` if `campRadius + 10` exceeded on Z-axis → return without moving; if already within `campRadius` → `checkOnReturn` scan if `returnToCamp`, then return; `campRadiusExceed` case: use larger radius before triggering return.

**Movement routing by `pullMoveUse`** (mac:3401–3600):
- **`advpath`**: walk waypoints in `pullPathX/Y/Z` array; advance `advpathPoint`; stuck recovery via `stuck()`; loop/park at end of path
- **`nav`** (MQ2Nav): `/nav locyxz campY campX campZ`; poll `Navigation.Active`; fallback if nav fails
- **`los`** / default: `/moveto loc campY campX`; poll `Me.Moving`; call `stuck()` if no progress

**Additional behaviors**: `locDelayCheckUW` (underwater delay: `mq.delay(250)` before loc checks when `Me.FeetWet`); walk/run toggle (`/squelch /walk` within `stickDist + 5` of camp, `/squelch /run` otherwise); `checkOnReturn` flag set on arrival (triggers a `pullCheck` pass from pull module); heal-while-moving stub comment (deferred M9).

**Done when:** character navigates back to camp X/Y/Z when `ReturnToCamp=1` and outside `CampRadius` using all three nav modes. ✅

✅ **Implemented (2026-05-16):**

- `movement.lua` `Movement.doWeMove(forceFlag, sentFrom)`: guards (dontMoveMe, chaseAssist, iAmDead/hovering, justZoned, invis+aggro, stayPut unless forced, zone mismatch, combat+aggro); camp-radius check with `campRadiusExceed` leash; three nav modes: advpath (waypoint array walk with stuck recovery), nav (`/nav locyxz` + `Navigation.Active` poll), los (`/moveto loc` + stuck recovery); walk/run toggle within `stickDist+5`; `checkOnReturn` set on arrival; `locDelayCheckUW` underwater delay.

---

#### Step 7.3 ✅ — `Movement.doWeChase` + `stuck` + `zAxisCheck`

Port three functions from kissassist.mac. Read each source block before implementing.

**`Movement.doWeChase(calledFrom)`** (mac:3663–3817, 154 lines):
- Guards (mac:3665–3680): `dontMoveMe`, `iAmDead`, `chaseAssist==false`, `whoToChase` not found in zone, hovering, CombatState == COMBAT with aggro
- Chase loop: target `whoToChase` spawn; get distance; if within `chaseOnValue * meleeDistance` stop moving (`/squelch /moveto loc stop`); `scatterOn` → displace aim point by `scatterDistance` in random direction to avoid stacking; `/moveto loc Y X` toward target; poll `Me.Moving`; call `stuck('DoWeChase')` if stalled; `mq.doevents()` each iteration
- **FaceMobOn** (mac:3646): if `faceMobOn && !aggroTargetID && !combatStart` (or pullertank roles): `/face id spawnID`

**`Movement.stuck(calledFrom)`** (mac:3817–3836, 19 lines): anti-stuck via directional keypresses — `/keypress forward hold` → `mq.delay(300)` → `/keypress forward`; optional strafe variant.

**`Movement.zAxisCheck()`** (mac:12224–12239, 15 lines): returns `true` if Z-axis distance to camp exceeds `campRadius + 10`; used as a guard in `doWeMove`.
```lua
function Movement.zAxisCheck()
    local dz = math.abs(mq.TLO.Me.Z() - _state.movement.campZ)
    return dz > (_state.movement.campRadius + 10)
end
```

**Done when:** character chases `whoToChase`; gets unstuck if nav stalls; `zAxisCheck` gates camp-return correctly when character is on a different floor/level. ✅

✅ **Implemented (2026-05-16):**

- `movement.lua` `Movement.doWeChase()`: guards (dontMoveMe, iAmDead, chaseAssist off, whoToChase not in zone, hovering, combat+aggro); scatter offset when `scatterOn`; `/moveto loc` toward target; stuck recovery; `faceMobOn` face call when not in combat.
- `movement.lua` `Movement.stuck()`: `/keypress back hold` + delay + release; random left/right strafe to break geometry.
- `movement.lua` `Movement.zAxisCheck()`: press `CMD_MOVE_DOWN` while `Me.Z - campZ >= 3.1` (levi correction); returns `true` if abs Z-gap > `campRadius + 10`.

---

#### Step 7.4 ✅ — `Movement.checkStick` + movement event completions + wire into loops

**`Movement.checkStick(flag, useAttack)`** (mac:1879–1973, 94 lines): Read source before implementing.

- Guards (mac:1888–1892): `chaseAssist` or `!returnToCamp` → use MA position as camp reference; else use saved campX/Y/Z
- Not sticking and mob within melee range and `!dontMoveMe`: `/stick id myTargetID [uw]` (underwater variant if `Me.FeetWet`)
- Already sticking to wrong mob: `/stick id myTargetID` update
- `stickHow == 'd'` → `/stick id X behind`; `stickHow == 'mp'` → `/stick id X moveback`
- Nav fallback when MQ2MoveUtils not present: `/moveto id myTargetID`
- Stick active but mob too far: break with `/squelch /moveto loc stop`

Wire into `combat.lua`: replace the `-- Deferred M7: CheckStick` stub in `Combat.fight()` with `_movement.checkStick(0, 1)` (mac:1065); replace `-- Deferred M7: ZAxisCheck` stub with `_movement.zAxisCheck()` (mac:1066).

**Complete movement event stubs** from Step 2.2 (`events.lua`):
- `CantHit` → `state.movement.cantHit = true`; `/squelch /attack off`; face target
- `CantSee` → `state.movement.cantSee = true`
- `TooClose` → `state.movement.toClose = true`; face target; `/keypress back hold`
- `TooFar` → `state.movement.dontMoveMe = false`; call `Movement.doWeMove(1, 'tooFar')`; `state.pull.tooFar = true`

**Wire into loops** (`init.lua` main loop — replace stub comments after `Heal.doWeMed()`):
```lua
if not State.combat.combatStart and State.movement.returnToCamp then
    Movement.doWeMove(0, 'mainloop')
end
if State.session.chaseAssist then Movement.doWeChase('mainloop') end
```
`Combat.checkForCombat()` — replace `-- Deferred M7: DoWeChase` stub:
```lua
if _state.session.chaseAssist then _movement.doWeChase('CheckForCombat1') end
```

**Done when:** stick engages on combat target; characters return to camp and chase MA; movement events (`CantHit`, `TooFar`, etc.) respond correctly. ✅

✅ **Implemented (2026-05-16):**

- `movement.lua` `Movement.checkStick(flag, useAttack)`: MA-reference camp fallback when `chaseAssist`; closes melee gap via nav or `/moveto id`; `/stick id` with `dStickHow` variants (behind/moveback); `/attack on` when `useAttack=1` and not in combat; breaks stick when mob too far from camp.
- `events.lua`: `CantHit` → `state.movement.cantHit = true` + `/attack off`; `CantSee` → `state.movement.cantSee = true`; `TooClose` → `state.movement.toClose = true` + back keypress; `TooFar` → `state.pull.tooFar = true` + `doWeMove(1, 'tooFar')`.
- `combat.lua` `fight()`: `_movement.checkStick(0, 1)` replacing deferred stub (mac:1065); `_movement.zAxisCheck()` replacing deferred stub.
- `init.lua` main loop: `Movement.doWeMove(0, 'mainloop')` and `Movement.doWeChase()` wired into loop (replacing stubs).

---

#### Step 7.5 ✅ — `pull.lua` scaffold + INI wiring + state audit

Create `modules/pull.lua` with `Pull.init(state, utils, cast, movement)`. Load all pull config from INI. Audit `state.pull`.

**INI fields to load** (from `Config.get`):
- `[Pull]`: `PullOn`, `PullWith` (Melee/Ranged/spell name/Pet/FD), `PullRange`, `MaxRadius`, `MaxZRange`, `PullMin`, `PullMax`, `PullHold`, `PullArcWidth`, `PullLSide`, `PullRSide`, `PullWait`, `ChainPull`, `PullOnReturn`, `PullRanking`, `MobsToPull` (pipe-separated priority list), `MobsToIgnore` (pipe-separated), `MobsNotAllowed`, `PullMoveUse` (los/nav/advpath), `SearchType`
- `[PullAdvanced]`: `PullLocsOn`, `PullLocY1..N`, `PullLocX1..N`, `PullLocZ1..N`, `PullWpCount`, `MaxWpRange`

Compare all INI keys against `state.pull` fields and add any missing entries (e.g., `pullArcWidth`, `pullLSide`, `pullRSide`, `pullWait`, `pullLocsOn`, `searchType`). Wire `Pull.init(State, Utils, Cast, Movement)` into `init.lua`.

**Done when:** module loads cleanly; `state.pull.maxRadius`, `state.pull.pullWith`, `state.pull.pullMoveUse` etc. populated from INI. ✅

✅ **Implemented (2026-05-16):**

- `state.lua`: `state.pull` expanded with `maxRadius`, `maxZRange`, `maxWpRange`, `mobsNotAllowed`, `mobsToIgnore`, `mobsToIgnoreByID`, `pullArcWidth`, `pullLocX/Y/Z`, `pullLocsOn`, `pullOnReturn`, `pullWait`, `searchType`; `chainPull` type changed from `false` to `0` (integer 0/1/2).
- `modules/pull.lua` created: `Pull.init(state, utils, cast, movement)` loads all `[Pull]` and `[PullAdvanced]` INI fields; derives `lSide`/`rSide` from `pullArcWidth` when individual sides not set; stubs for `pullValidate`, `findMobToPull`, `pullCheck`.
- `init.lua`: `Pull` module required; `Pull.init(State, Utils, Cast, Movement)` wired after `Buffs.init`.

---

#### Step 7.6 ✅ — `Pull.pullValidate` (mob validity gate)

Port `PullValidate` (kissassist.mac:9443–9571, 128 lines). Read the full source before implementing.

**Function signature:** `Pull.pullValidate(mobID, flag)` → returns `true` (valid) or `false` (skip).

Port all reject conditions in order:

| Check | mac line | Logic |
|---|---|---|
| NPC type | 9449 | `Spawn.Type == 'NPC'` — reject non-NPC |
| Targetable | 9453 | `Spawn.Targetable` — reject non-targetable |
| Eye of Zomm | 9517 | `CleanName:Find('Eye of')` + PC with same suffix nearby |
| LOS | 9522 | `los` mode: reject if `!Spawn.LineOfSight` |
| Nav path | 9510 | `nav` mode: reject if `Navigation.PathLength[id X] <= 0` |
| Level range | 9527 | `Spawn.Level < pullMin` or `> pullMax` |
| PCs near mob | 9532 | `SpawnCount[notid Me loc X Y radius 30 pc nogroup] > 0` while `pulling` |
| Pull arc | 9537 | `pullArcWidth > 0`: call `figureMobAngle(mobID)` → reject if outside arc |
| HP% | 9545 | `Spawn.PctHPs <= 99 && Spawn.Distance >= meleeDistance` → already in combat |
| Pull names list | 9550 | If `mobsToPullFirst != 'all'`: reject if name not in list |
| Mobs to ignore | 9558 | Reject if name in `mobsToIgnore` list |
| Near-camp mobs | 9564 | `PullNames` active but mobs-already-in-camp block |

Local helper: `figureMobAngle(mobID)` (mirrors mac `FigureMobAngle`) — computes heading from mob to camp, compares to `pullLSide`/`pullRSide` window, returns `true` if in arc.

**Done when:** `Pull.pullValidate(spawnID, 1)` correctly rejects mobs outside level range, not LOS, in combat, or in ignore list. ✅

✅ **Implemented (2026-05-16):**

- `pull.lua` local helpers: `dist2D`, `inNameList` (comma/pipe list with `*` substring and `#` exact prefix), `figureMobAngle` (mob→camp heading vs lSide/rSide window, wrapping arc support).
- `pull.lua` `Pull.pullValidate(mobID, flag)`: all 13 reject conditions in mac order: NPC type gate, name-allowed list, ignore-by-name, ignore-by-ID, `pullLocsOn` proximity (must be near a pull loc), range from camp (2D), nav-path existence (nav mode), Eye of Zomm PC check, LOS (los mode), level range, PCs near mob (30-unit radius), pull arc (`figureMobAngle`), HP% already-in-combat check with server-lag recheck (target + `BuffsPopulated` wait when `flag > 0`), named mob guard (reject unless `flag > 0` and camp free).

---

#### Step 7.7 ✅ — `Pull.findMobToPull` (mob discovery)

Port `FindMobToPull` (kissassist.mac:8945–9308, 363 lines) — the most complex function in M7. Read the entire sub before starting.

**Function signature:** `Pull.findMobToPull(readyToPullFlag, a, b)` → sets `state.pull.mob`; returns `1` (found) or `0` (none).

**Entry guards** (mac:8947–8970): `iAmDead`, `Me.Invis`, `DMZ && !Me.InInstance`, `CampZone != Zone.ID`, `pulling`, `combatStart`, `holdCond`, rez sickness buffs → return `0`.

**PullAlert / ignore list** (mac:8997–9010): timer gate on `timers.pullAlert`; when expired rebuild alert list from `mobsToIgnore`; call `pullIgnoreCheck(1, 'c')`.

**Advpath dispatch** (mac:9008–9011): if `pullMoveUse == 'advpath'` → call `findMobAdvPath(readyToPullFlag)` and return its result (stub with `printf` + return `0` — see Deferred below).

**Hunter roles — SpawnCount scan** (mac:9012–9066): hunter uses `npc` (nav) or `npc los` (los/melee); other pullers use `npc los`; compute `pullCount = SpawnCount[vstStr1 radius maxRadius zradius maxZRange targetable searchType]`; decrement by mobs already within `meleeDistance` (chain pull adjustment).

**Main candidate search loop** (mac:9079–9300): iterate spawn index `Pindex` from `beginSearchX` to `pullCount`; for each: `Spawn[N, vstStr1 ...]` by rank order; call `pullValidate(spawn.ID, Pindex)` — skip if invalid; check `mobsToPullFirst` priority list (prefer priority mobs); apply `pullRanking` sort (stub if `> 9`); on valid candidate: set `state.pull.mob = spawn.ID` + `state.pull.lastMobPullID`; return `1`.

**Chain pull handling** (mac:9072–9075): `readyToPullFlag == false` → subtract mobs within `meleeDistance` from count; if last-pulled mob still outside melee → return `0`.

**Done when:** `Pull.findMobToPull(1, 1, 0)` sets `state.pull.mob` to a valid NPC ID matching pull criteria (level range, LOS, not ignored, not in combat). ✅

✅ **Implemented (2026-05-16):**

- `pull.lua` local helpers: `pullQuery` (builds spawn filter string), `findMobLOS` (sequential `NearestSpawn` scan calling `pullValidate`), `findMobNAV` (scan picking mob with shortest `Navigation.PathLength`; heuristic early-out on dist vs current shortest), `findMobsFirst` (iterates `mobsToPullFirst` list; strips `#` prefix for SpawnCount queries).
- `pull.lua` `Pull.findMobToPull(readyFlag, a, b)`: entry guards (iAmDead, invis, DMZ, zone mismatch, pulling, combatStart, holdCond, rez sickness); chainPull guard (last pulled mob still outside melee → return 0); `aggroTargetID` already set → return 0; advpath deferred (debug + return 0); `findMobsFirst` priority pass; progressive radius outer loop (up to 3 attempts); inner `pIter` loop expanding subdivision until `SpawnCount ≤ modCheck`; dispatches to `findMobLOS` or `findMobNAV` based on `moveUse`; sets `state.pull.mob` and `state.pull.lastMobPullID`; returns 1 (found) or 0 (none).

---

#### Step 7.8 ✅ — `Pull.pullCheck` + bind completions + `validateTarget` pull checks + main loop wiring

Port `PullCheck` (kissassist.mac:9308–9443, 135 lines). Read source before implementing.

**Guards** (mac:9313): `pullHold`, `dpsOn && dpspaused`, rez sickness buffs, `campZone != Zone.ID`, `Me.Invis` → return `0`.

**Target acquisition** (mac:9314–9317): for `los`/`nav` modes `/target id pullMob` + `mq.delay(20)`.

**Advpath guard** (mac:9321–9333): check mob distance to advpath point; if out of range clear target and return `0`.

**ValidateTarget + distance** (mac:9335–9342): call `Combat.validateTarget(pullMob)` — if invalid or mob too far, call `pullIgnoreCheck` + clear target + return `0`.

**Broadcast announce** (mac:9343–9350): echo "PULLING-> MobName <- ID:X at Y feet." via `/bc` (DanNet M9).

**Pull method dispatch** (mac:9354–9440):

| Method | Logic |
|---|---|
| `Pet` | Pet back off, pet follow; mob aggros pet and paths back |
| `Melee` | `pullRange = maxRangeTo * 0.90`; run at mob, engage melee, run back to camp |
| `Ranged` | `/squelch /attack off`; face mob; fire ranged weapon; retreat to camp |
| `FD` | Target mob, engage, feign death; mob resets and paths back |
| `nav` / `los` | Spell pull: `_cast.castWhat(pullWith, pullMob, 'Pull')` |
| `advpath` | Set `pulling=true`; mob follows back along advpath waypoints |

**Chain pull + hunter return** (mac:9305–9412): `chainPull==2` → reset to `1`; set `checkOnReturn`; hunter with no mobs → `_movement.doWeMove(1, 'pullcheck')` + `pullDelay()` wait.

**Complete `validateTarget` pull checks** in `combat.lua` `validateTarget()` (deferred from Step 4.3):
- PCs near mob (within 30 units, not in group) → `validTarget = false` when `state.pull.pulling`
- Mob level outside `[pullMin, pullMax]` → `validTarget = false` when `state.pull.pulling`

**Bind completions** in `binds.lua` (replace M7 stubs):
- `/trackmedown [name]` → set `state.session.whoToChase = name`; `state.session.chaseAssist = true`; no arg → toggle off
- `/addpull [name]` → append to `state.pull.mobsToPullFirst` pipe list; persist to INI `[Pull] MobsToPull`
- `/addignore [name]` → append to `state.pull.mobsToIgnore`; persist to INI `[Pull] MobsToIgnore`
- `/SetPullArc [width]` → set `state.pull.pullArcWidth`; compute `pullLSide`/`pullRSide`; persist
- `/setpullranking [n]` → set `state.pull.ranking = tonumber(n) or 0`; echo confirmation

**Main loop wiring** in `init.lua` (after `Movement.doWeChase()` call):
```lua
local PULLER_ROLES = {puller=true, pullertank=true, pullerpettank=true, hunter=true, hunterpettank=true}
if PULLER_ROLES[State.session.role] then
    if not State.pull.hold then
        if not State.pull.mob then Pull.findMobToPull(1, 1, 0) end
        if State.pull.mob then Pull.pullCheck() end
        State.pull.mob = 0
    end
end
```

Wire `Pull` into `combat.lua` `checkForCombat()` for the ChainPull==2 exit path (mac:629): when `chainPull==2` and no mobs near camp, call `Pull.findMobToPull()`.

**Done when:** puller role finds a valid mob, pulls it to camp, group engages within camp radius; all 5 bind stubs respond correctly; `validateTarget` pull checks active. ✅

✅ **Implemented (2026-05-16):**

- `combat.lua` `validateTarget()`: added pull-specific checks (guarded by `state.pull.pulling`): rejects mob if any non-group PC is within 30 units of the mob; rejects mob level outside `[state.pull.min, state.pull.max]`. Exposed as `Combat.validateTarget = validateTarget`.
- `pull.lua`: added `_combat` upvalue; `Pull.init()` accepts `Combat` as 5th arg. Local helpers added: `stopMoving`, `pullReset`, `pullWithMelee` (moveto+attack+retreat), `pullWithRanged` (/range loop + aggro wait), `pullWithPet` (pet attack+backoff), `pullWithCast` (castWhat loop for spell/AA/item). `executePull()` (mirrors Sub Pull mac:9589): outer `goto`-based loop handles aggro-already-detected, mobs-in-camp abort, pull-status-flag evaluation (distance/timeout/OOR), nav/los movement with timer extension, stuck detection, PullDist creep on repeated failures, in-range dispatch to pull method, BTC (back-to-camp) reset on abort, `doWeMove` return-to-camp.  `Pull.pullCheck()` (mirrors Sub PullCheck mac:9308): chainPull-2 reset, all guards (hold, DPSPaused, rez sickness, zone, invis), no-mob failcounter/hunter-return/inline pullWait, target acquisition for los/nav, advpath deferred, validateTarget + camp-distance gate, pull announce (printf; /bc deferred to M9), sets myTargetID/myTargetName, calls executePull.
- `binds.lua`: implemented `/trackmedown` (sets `movement.whoToChase` + `session.chaseAssist`), `/SetPullArc` (sets pullArcWidth, recomputes lSide/rSide, persists), `/setpullranking` (sets ranking, persists), `/addpull` (appends to mobsToPullFirst, persists), `/addignore` (appends to mobsToIgnore, persists).
- `init.lua`: `Pull.init` wired with `Combat` as 5th arg. `PULLER_ROLES` table declared above main loop. Puller-role block added at end of main loop: `findMobToPull(1,1,0)` → `pullCheck()` → `mob = 0`.
- Test plan: Section 7.8 added (32 test cases). Known Deferred updated.

---

**Deferred (not needed for M7):**

| Feature | Deferred to |
|---|---|
| `FindMobAdvPath` / advpath mob discovery | M7 stretch; stub with `printf` + return `0` |
| `UpdatePullRanking` ranking sort | M7 stretch; `pullRanking > 9` guard passthrough |
| `PullDelay` / respawn wait loop | M7 stretch; `mq.delay(pullWait * 1000)` inline |
| `AlertAddToList` / `PullIgnoreCheck` | M7 stretch; skip-ignore list management |
| BroadCast pull announce to group | M9 (comms); use `/bc` directly |
| Heal-while-moving in `doWeMove` | M9 integration pass |
| `DoBardStuff` calls in movement | M8 (bard module) |
| `CheckRampPets` (mac:9569) | M8 (pet module) |
| ConOn condition evaluation for pull entries | M10 |

**Suggested order:** 7.1 → 7.2 → 7.3 → 7.4 (movement, sequential). 7.5 can start in parallel with 7.1. 7.6 → 7.7 → 7.8 (pull, sequential — `pullValidate` needed by `findMobToPull`).

---

### Milestone 8 — Pet & Bard
**Goal:** Pet classes and Bards function correctly.

- `pet.lua` — `DoPetStuff`, `PetToys` (item-giving cluster), `CheckRampPets`, pet hold/resume
  - Note: `CheckPetBuffs` was already ported to `buffs.lua` in M6 Step 6.6
- `bard.lua` — `DoBardStuff` translated to MQ2Medley API, context-based medley switching
  - Define medley sets in character INI (`[MQ2Medley-melee]`, `[MQ2Medley-burn]`, `[MQ2Medley-oor]`, etc.)
  - Call `/medley <setname>` on context transitions; `/medley queue` for event-driven one-shot songs
  - Query `Medley.Active` / `Medley.TTQE` instead of `Twist.Twisting` / `Twist.Current`
  - Note: replaces MQ2Twist — Bard users must define `[MQ2Medley-*]` INI sections (one-time migration)

**Done when:** Necro/Mage/BST pets summon and receive toys; `CheckRampPets` holds pulls until rampage pets poof; Bard switches medley sets correctly on combat state transitions; CastAA pauses medley before activating AAs.

---

#### Step 8.1 ✅ — `pet.lua` scaffold + INI wiring + state audit

Create `modules/pet.lua` with `Pet.init(state, utils, cast)`. Load all pet config not already loaded by M6 (`Buffs.init` already loads `on`, `shrinkOn`, `shrinkSpell`, `toysOn`, `toysArray` into `state.pet` — do not duplicate).

**New INI fields to load** (from `[Pet]`):

- `PetSpell` → `state.pet.spell`
- `PetFocus` → `state.pet.focus` (pipe-delimited `focusItem|focusSlot|focusBuff`)
- `PetFocusOn` → `state.pet.focusOn`
- `PetHoldOn` → `state.pet.holdOn`
- `PetSuspend` → `state.pet.suspend`
- `PetSuspendState` → `state.pet.suspendState` (0=none, 1=suspended)
- `PetTotCount` → `state.pet.totCount` (total pet slots including suspended)
- `PetActiveState` → `state.pet.activeState` (0=no pet, 1=pet active)
- `PetFocusOn` → `state.pet.focusOn`

Audit `state.pet` in `state.lua` for any missing fields and add them. Wire `Pet.init(State, Utils, Cast)` into `init.lua` after `Buffs.init`. Add stub comments for Steps 8.2–8.4.

**Done when:** module loads cleanly; `state.pet.spell`, `state.pet.focus`, `state.pet.holdOn` populated from INI.

✅ **Implemented (2026-05-16):** `modules/pet.lua` created with `Pet.init(state, utils, cast)`. Loads `PetSpell`, `PetFocus`, `PetFocusOn`, `PetHoldOn`, `PetSuspend` from `[Pet]` INI section. `state.pet` audited — added `spell`, `focus`, `holdOn`, `suspend` fields (runtime fields `activeState`, `suspendState`, `totCount`, `focusOn` were already present). `Pet.init` wired into `init.lua` after `Buffs.init`. Stub comments for Steps 8.2–8.4 in place. **Note:** `holdOn`/`focusOn` were initially loaded as booleans here; Step 8.2 changed them to numeric 0/1/2 and added `tauntOverride` load.

---

#### Step 8.2 — `Pet.doPetStuff` (summon + focus swap)

Port `DoPetStuff` (kissassist.mac:5210–5401, ~191 lines) and the local helper `petStateCheck` (mac:5191–5209, 18 lines). Read both source blocks before implementing.

**`petStateCheck()`** (local helper, mac:5191): checks `Me.Pet.ID` against expected states, echoes status, sets `state.pet.activeState` and `state.pet.suspendState` based on live pet presence vs `PetTotCount`.

**`Pet.doPetStuff()`** (mac:5210):

- **Entry guards** (mac:5211–5212): `!petOn`, `campZone != Zone.ID`, `aggroTargetID`, `Me.Invis`, `Me.Hovering` → return
- **Event drain loop** (mac:5213–5217): drain `EventFlag` before any work
- **Pet focus resolution** (mac:5220–5233): parse `state.pet.focus` (pipe-delimited `FocusPet|FocusSlot|FocusBuff`); if slot != `buff`, read `Me.Inventory[slot].Name` as `focusCurrent`; if slot == `buff`, `focusCurrent = focusBuff`
- **Familiar banish** (mac:5234): if `Me.Pet.CleanName == Me.Name's familiar` → `/pet get lost`
- **No-pet path** (mac:5237–5328): guard `!Me.Pet.ID && PetSpell.Mana <= CurrentMana`
  - Reset `petActiveState = 0`, clear `g_PetToysGave`
  - Focus item swap (non-buff slot): if cursor clear and focus item differs from current → `MQ2Exchange` equip via `mq.cmd('/exchange ...')`, set `focusSwitch = true`
  - Focus buff path: if `focusBuff` not active → `_cast.castWhat(focusPet, Me.ID, 'DoPetStuff')`
  - **Suspend path** (mac:5274–5306): if `petSuspend`: call `petStateCheck()`; if `totCount==1 && activeState==0 && suspendState==1` → echo + call `petStateCheck` to unsuspend; if `totCount < 2 && suspendState==0 && activeState==0` → summon loop
  - **Normal summon loop** (mac:5307–5327): `CastWhat(petSpell, Me.ID, 'DoPetStuff')`; loop with 1s delay until `Me.Pet.ID` or `PetSummonTimer` expires; on `CAST_COMPONENTS` → echo + return; on pet appear: echo, set `activeState = 1`, call `_buffs.checkPetBuffs()`, call `Pet.petToys(petName)` if `toysOn`
  - Focus swap-back (mac:5324–5327): if `focusSwitch` and cursor clear → exchange back to original item

**Done when:** pet class with no pet casts `PetSpell`, pet appears, focus item swaps correctly.

✅ **Implemented (2026-05-16):** `petStateCheck()` local helper and `Pet.doPetStuff()` implemented in `modules/pet.lua`. Covers: entry guards (petOn, campZone, aggroTargetID, Invis, Hovering); focus string parsing (`FocusPet|FocusSlot|FocusBuff`); familiar banish; no-pet path with focus item equip + suspend unsuspend/summon + normal summon loop (`CastWhat` → wait 1s → 60s deadline); focus swap-back; pet stance guard/follow for PULL_ROLES; `holdOn`/`focusOn` sent once (state 0→1→2); has-pet path stance/hold/focus maintenance; taunt on/off for PETTANK_ROLES with `tauntOverride` guard; `_buffs.checkPetBuffs()` always called; `Pet.petToys()` called when `toysOn` and pet name not in `toysGave`; pettank/hunterpettank owner-away-from-camp follow logic; `castMemSpell` guarded with existence check. `Pet.init` updated: `buffs` added as 4th arg; `holdOn`/`focusOn` stored as numeric 0/1/2 instead of boolean; `tauntOverride` loaded from INI. `Pet.petToys` and `Pet.checkRampPets` remain stubs.

---

#### Step 8.3 — `Pet.petToys` + item-giving helpers

Port the `PetToys` cluster (mac:5586–6034). All functions are local helpers in `pet.lua` except `Pet.petToys` which is the public entry point. Read each sub before implementing.

**Mac source ranges:**

| Function | mac lines | Lines | Purpose |
| --- | --- | --- | --- |
| `CastPetToys` | 5521–5561 | 40 | Cast a toy spell/AA/disc on the pet |
| `PickUpItem` | 5562–5585 | 23 | Move item from bag to cursor for giving |
| `PetToys` | 5586–5835 | 249 | Main item-giving orchestration |
| `OpenInvSlot` | 5836–5884 | 48 | Open a bag slot to make room for cursor |
| `DestroyBag` | 5885–5922 | 37 | Destroy a bag if needed to free space |
| `GiveTo` | 5923–6034 | 111 | Give cursor item to target NPC/pet |

**`castPetToys(spell)`** (local, mac:5521): cast spell/AA/disc on pet via `_cast.castWhat(spell, Me.Pet.ID, 'Pet-nomem')`; guards on `CombatAbilityReady`/`AltAbilityReady`.

**`pickUpItem(itemName, addToList)`** (local, mac:5562): find item in inventory by name; click to move to cursor; handle `addToList` flag for tracking.

**`openInvSlot()`** (local, mac:5836): find an empty top-level inventory slot; open the bag in that slot if needed.

**`destroyBag()`** (local, mac:5885): delete a bag item from cursor to free inventory space.

**`giveTo(item, targetID, giveNow)`** (local, mac:5923): target NPC by ID, wait for target lock, give cursor item via `/itemnotify slot leftmouseup` + `/click right target`; poll trade window; confirm trade.

**`Pet.petToys(petName)`** (public, mac:5586): guards (`toysOn`, pet present, `g_PetToysGave` not already given); iterates `state.pet.toysArray`; for each toy: check if pet already has it (scan `Me.PetBuff` slots); if not: `pickUpItem`, `giveTo(pet.ID)`; on success mark `g_PetToysGave`; call `castPetToys` for any toy-buff spells.

**Done when:** pet toys are given to pet after summon; toy items move through cursor → pet trade window correctly.

✅ **Implemented (2026-05-16):** All six functions implemented in `modules/pet.lua`. `castPetToys(spell)` — retry loop up to 4 fizzles; handles `CAST_SUCCESS`/`CAST_FIZZLE`/`CAST_RECOVER`; returns `true` if cancelled. `pickUpItem(itemName)` — locates via `FindItem`, adjusts slot indices (>22 subtract 22; slot2 0→1-based), appends to module-level `_toyItems` table for return-on-reject tracking. `openInvSlot()` — two-pass search: pass 1 = completely empty slot, pass 2 = non-container slot with `FreeInventory > 1`; sets `_bagNum`/`_bagNumLast`. `destroyBag()` — verifies all contents are `NoRent` before `/destroy`ing known phantom/arcane pack names. `giveTo(gItem, gTarget, giveNow)` — targets pet, moves close, dismounts/removes-lev, confirms via `GiveWnd`; on rejection restores item to origin slot using `_toyItems` table. `Pet.petToys(petName)` — full 249-line orchestrator port: bag-slot acquisition, `toysGave`/`toysTemp` tracking, per-entry spell-in-book / inventory-item dispatch, bag-on-cursor placement loop, pipe-part iteration with skip-already-given and level-76 auto-equip guards, summoned-item re-cast loop, heirloom-bag (`castFlag1==2`) path, `destroyBag` on known pack names, inventory-window cleanup, `doWeMove` on `returnToCamp`. `Pet.init` signature updated to accept `movement` as 5th arg (needed for `doWeMove` call in petToys); `init.lua` updated. `condNo`/`|cond` condition evaluation deferred to M10.

---

#### Step 8.4 — `Pet.checkRampPets` + wire into main loop + pull module

Port `CheckRampPets` (mac:9571–9585, 14 lines) and wire all pet functions into the main loop and pull system.

**`Pet.checkRampPets()`** (mac:9571): if not in `COMBAT`, iterate `i` from 0–20; if `Spawn[Me.CleanName's_pet0{i}].ID` exists (rampage pet present), echo and loop with `mq.delay(100)` until OOC and pet gone or combat re-enters; releases when all rampage pets have poofed.

**Main loop wiring** in `init.lua`: add after buff/heal section:
```lua
if State.pet.on and not State.combat.combatStart then
    Pet.doPetStuff()
end
```

(Note: `checkPetBuffs` and `checkBegforPetBuffs` are already wired from M6.)

**Pull module wiring** in `pull.lua`: add `Pet.checkRampPets()` call in `Pull.pullCheck()` immediately before the pull method dispatch (mirrors mac:9569) — only called when `state.pet.on` and `petRampageOn` config is set.

**Done when:** pet classes auto-summon pets in main loop; pulls wait for rampage pets to poof before executing.

> ✅ **Implemented (Step 8.4):** `Pet.checkRampPets()` (pet.lua) iterates spawn names `Me.CleanName's_pet0{i}` i=0–20; if out of combat and a rampage pet exists, echoes and loops with `mq.delay(100)` until the spawn disappears or combat resumes; returns early on combat re-entry. `state.pet.petRampageOn` added to `state.lua`; loaded from `[Pull] PetRampPullWait` INI key in `Pet.init`. `Pull.init` extended with a `pet` 6th parameter (`_pet` upvalue); `Pull.pullCheck()` calls `_pet.checkRampPets()` before `executePull()` when `pet.on` and `pet.petRampageOn` are set and not in combat. `init.lua` main loop wired: `if State.pet.on and not State.combat.combatStart then Pet.doPetStuff() end` (after begforPetBuffs check); `Pull.init` call updated to pass `Pet` as 6th arg.

---

#### Step 8.5 — `bard.lua` scaffold + MQ2Medley INI wiring + state audit

Create `modules/bard.lua` with `Bard.init(state, utils, cast)`. Load all bard config from INI. Map `state.bard` fields from MQ2Twist terminology to MQ2Medley equivalents.

**INI fields to load** (from `[General]` and `[Spells]`):

- `TwistOn` → `state.bard.twistOn` (OOC medley enabled)
- `MeleeTwistOn` → `state.bard.meleeTwistOn` (0=off, 1=swap to melee set, 2=swap when aggro without combatStart)
- `TwistHold` → `state.bard.twistHold`
- `PullTwistOn` → `state.bard.pullTwistOn` (pause medley during pull)
- `OORMedley` → `state.bard.oorMedley` (medley set name for OOC: default `"oor"`)
- `MeleeMedley` → `state.bard.meleeMedley` (medley set name for combat: default `"melee"`)
- `BurnMedley` → `state.bard.burnMedley` (medley set name for burn: default `"burn"`)
- `GoMMedley` → `state.bard.gomMedley` (one-shot song name for GoM proc: default `"gomSong"`)

**State fields to audit** in `state.bard`: `twistOn`, `meleeTwistOn`, `twistHold`, `pullTwistOn`, `twisting` (bool: OOC medley active), `dpsTwisting` (bool: melee medley active), `gomActive` (already set by events.lua Step 2.3), `oorMedley`, `meleeMedley`, `burnMedley`, `gomMedley`. Add any missing fields.

Wire `Bard.init(State, Utils, Cast)` into `init.lua` after `Pet.init`. `Bard.init` is a no-op for non-Bard classes (guard on `state.session.iAmABard`).

**Done when:** module loads cleanly; `state.bard.twistOn`, `state.bard.meleeMedley` populated from INI for Bard characters.

> ✅ **Implemented (Step 8.5):** `modules/bard.lua` created with `Bard.init(state, utils, cast)` and a `Bard.doBardStuff()` stub for Step 8.6. `Bard.init` guards on `state.session.iAmABard` (no-op for non-Bard classes). Loads from `[General]` INI: `twistOn` (TwistOn), `meleeTwistOn` (MeleeTwistOn, numeric 0/1/2), `twistHold` (TwistHold), `pullTwistOn` (PullTwistOn), `oorMedley` (OORMedley, default `"oor"`), `meleeMedley` (MeleeMedley, default `"melee"`), `burnMedley` (BurnMedley, default `"burn"`), `gomMedley` (GoMMedley, default `"gomSong"`). `state.bard` audited: 7 missing fields added (`twistOn`, `meleeTwistOn`, `pullTwistOn`, `oorMedley`, `meleeMedley`, `burnMedley`, `gomMedley`) with defaults matching MQ2Medley conventions. `init.lua` updated: `require('modules.bard')` added; `Bard.init(State, Utils, Cast)` wired after `Pet.init`.

---

#### Step 8.6 — `Bard.doBardStuff` (MQ2Medley context switching)

Port `DoBardStuff` (kissassist.mac:6229–6331, ~103 lines) translated to MQ2Medley API. This is a semantic translation — do not use MQ2Twist TLOs. Read the full source before implementing.

**MQ2Twist → MQ2Medley API translation:**

| `.mac` (MQ2Twist) | Lua (MQ2Medley) |
|---|---|
| `${Twist}` | `mq.TLO.Medley.Active()` |
| `/squelch /twist ${TwistWhat}` | `mq.cmdf('/medley %s', state.bard.oorMedley)` |
| `/squelch /twist ${MeleeTwistWhat}` | `mq.cmdf('/medley %s', state.bard.meleeMedley)` |
| `/stopsong` | `mq.cmd('/medley stop')` |
| `Sub CastBardCheck` (check cast window) | `stopMedley()` local helper |
| `Twist.List.Left[-1]` (current set name) | `mq.TLO.Medley.ActiveSet()` (or equivalent) |
| `${Me.BardSongPlaying}` | `mq.TLO.Me.BardSongPlaying()` |

**`stopMedley()`** (local): if `Medley.Active` → `/medley stop`; wait for `!Me.BardSongPlaying` up to 500ms. Replaces `CastBardCheck`.

**`Bard.doBardStuff()`** (mac:6229):

- **Class guard**: `not state.session.iAmABard` → return
- **Twist disabled**: `!twistOn && !meleeTwistOn` → if `Medley.Active` call `stopMedley()`; return
- **Invis/hold path** (mac:6248–6253): if `Me.Invis` or `twistHold` → if GoM active (`gomActive`), queue GoM song; return
- **Combat path** (mac:6256–6302): `combatStart || (meleeTwistOn==2 && aggroTargetID)`:
  - `meleeTwistOn && !dpsTwisting` → `stopMedley()` if wrong set active; `/medley <meleeMedley>`; set `dpsTwisting = true`, `twisting = false`
- **OOC path** (mac:6303–6329): `!combatStart`:
  - `twistOn && !twisting` → `stopMedley()` if wrong set active; `/medley <oorMedley>`; set `dpsTwisting = false`, `twisting = true`
  - `!twistOn` → `stopMedley()`
- **GoM handling**: when `state.bard.gomActive` and in OOC path → `/medley queue <gomMedley>`; clear `gomActive` after queuing

**Done when:** Bard switches from OOR medley to melee medley when entering combat; switches back OOC; GoM queues one-shot song without disrupting active medley.

> ✅ **Implemented (Step 8.6):** `Bard.doBardStuff()` fully ported in `modules/bard.lua`. `mq.TLO.Medley` aliased as `local Medley` with a single `---@diagnostic disable-next-line` suppression (plugin TLO not in type definitions). Local `stopMedley()` helper: calls `/medley stop` if `Medley.Active()`, waits up to 500ms for `BardSongPlaying` to clear — replaces `Sub CastBardCheck` and inline `/stopsong` patterns. Logic paths: (1) class guard; (2) both modes off → `stopMedley()` + return; (3) medley not running → reset `twisting`/`dpsTwisting`, `/stopsong` if casting window closed; (4) invis/hold → queue GoM if `gomActive`, return; (5) combat path (`combatStart` or `meleeTwistOn==2 && aggroID>0`) — if `meleeTwistOn!=0 && !dpsTwisting`: stop if wrong set, `/medley <meleeMedley>`, set `dpsTwisting=true`, `twisting=false`; (6) OOC path — if `twistOn && !twisting`: stop if wrong set, `/medley <oorMedley>`, set `dpsTwisting=false`, `twisting=true`; if `!twistOn`: `stopMedley()`; GoM queue in OOC path. MQ2Twist Continuous/non-Continuous distinction collapses into single `/medley <set>` call. `_cast` upvalue retained for Step 8.7 `pauseMedley`.

---

#### Step 8.7 — Wire bard + complete deferred M3/M4/M7 bard stubs

Final wiring pass — connect `bard.lua` to all the deferred stub points across existing modules.

**`init.lua` main loop**: add `Bard.doBardStuff()` call after `Heal.doWeMed()` and before movement section:

```lua
if State.session.iAmABard then Bard.doBardStuff() end
```

**`combat.lua` `fight()` inner loop** (deferred from Step 4.5): replace `-- Deferred M8: DoBardStuff` stub comment with `if _bard then _bard.doBardStuff() end` call each iteration. Pass `Bard` as 6th arg to `Combat.init`; store as `_bard` upvalue.

**`combat.lua` `combatReset()`** (deferred from Step 4.4): replace `-- Deferred M8: bard` stub with `stopMedley` logic — when `combatReset` fires, switch back to OOR medley by forcing `dpsTwisting = false` and letting next `doBardStuff` tick detect the OOC transition.

**`cast.lua` CastAA bard pause** (deferred from Step 3.3): before `/alt act ID` in `castAA()`, add:

```lua
if _state.session.iAmABard and _bard then _bard.pauseMedley() end
```

Add `Bard.pauseMedley()` public function: `/medley pause` if supported; else `stopMedley()`. Restore via `/medley resume` after cast returns.

**`pull.lua` bard pull-pause** (deferred from M7, mirrors mac:9629–9631): in `Pull.pullCheck()` before execution, add:

```lua
if _state.session.iAmABard and not _state.bard.pullTwistOn and _bard then
    _bard.stopMedley()
end
```

**Done when:** Bard cycles medley sets throughout combat; CastAA pauses medley; pull stops medley when `PullTwistOn=0`; `combatReset` transitions back to OOR set.

> ✅ **Implemented (Step 8.7):** `bard.lua` — added `Bard.stopMedley` (public alias of local `stopMedley`), `Bard.pauseMedley()` (`/medley pause` + 300ms wait if active), `Bard.resumeMedley()` (`/medley resume`). `cast.lua` — added `local _bard` + `Cast.setBard(bard)` setter; replaced `-- Bard twist-pause stub → M8` with `if state.session.iAmABard and _bard then _bard.pauseMedley() end`; replaced `-- Bard cleanup stub → M8` with `_bard.resumeMedley()`. `combat.lua` — `_bard` upvalue added; `Combat.init` extended to 6th `bard` param; CombatStart announce stub replaced with `if _bard then _bard.doBardStuff() end`; inner fight-loop stub replaced with same; `combatReset` clears `state.bard.dpsTwisting = false` when bard so next `doBardStuff` tick re-enters OOC path. `pull.lua` — `_bard` upvalue added; `Pull.init` extended to 7th `bard` param; bard pull-pause added before `executePull`: stops medley when `iAmABard && !pullTwistOn`. `init.lua` — `Combat.init` updated to pass `Bard` (6th); `Cast.setBard(Bard)` called after `Bard.init`; `Pull.init` updated to pass `Bard` (7th); main loop wired: `if State.session.iAmABard then Bard.doBardStuff() end` after `Heal.doWeMed()`.

---

**Deferred (not needed for M8):**

| Feature | Deferred to |
|---|---|
| `GroupEscape` evac (mac:6335) | M10 full integration |
| `MassGroupBuff` MGB helper | M10 (stub already returns nil) |
| `SummonStuff` helper | M10 (stub with printf) |
| Burn medley (`burnMedley`) auto-switch | M9 — triggered by burn activation in `cast.lua` |
| DanNet cross-character pet toy request | M9 (comms.lua) |
| ConOn condition evaluation for pet/bard entries | M10 |
| `FindMobAdvPath` advpath mob discovery | M9 stretch (stub remains) |

**Suggested order:** 8.1 → 8.2 → 8.3 → 8.4 (pet, sequential — each depends on previous). 8.5 can start in parallel with 8.1. 8.6 → 8.7 (bard, sequential). Pet and bard tracks are independent once 8.1/8.5 scaffolds are done.

---

### Milestone 9 — Looting (MQ2AutoLoot)

**Goal:** Characters loot corpses automatically per `Loot.ini` rules, sell/deposit/barter on demand, without porting `Ninjadvloot.inc`.

**Approach decision:** Delegate to the `MQ2AutoLoot` plugin instead of porting `Ninjadvloot.inc`. Rationale:

- MQ2AutoLoot handles the entire Advanced Looting window in C++ (master looter assignment, need/greed/no voting, distribution, bag-space tracking, forage) — zero Lua looting loop code required.
- Uses the **same `Loot.ini` format** as Ninjadvloot.inc (`=Keep`, `=Sell`, `=Destroy`, `=Quest|#n`, `=Ignore`). Existing user loot configs work without migration.
- Adds richer actions Ninjadvloot.inc lacks: `=Deposit`, `=Barter|#n`, `=Gear|Classes|WAR|...|NumberToLoot|#n|`.
- Sell/deposit/barter are one-liner `/autoloot sell|deposit|barter` slash commands.
- Consistent with the project philosophy of delegating complex subsystems to maintained plugins (MQ2MoveUtils, MQ2Rez, MQ2Medley, MQ2Nav).

---

#### Step 9.1 — Plugin validation + `State.loot` INI wiring

Add `MQ2AutoLoot` to the required plugin list in `Config.checkPlugins()`.

New `state.loot` fields (wire from INI `[General]` section):

| State field | INI key | Default | Purpose |
| --- | --- | --- | --- |
| `state.loot.on` | `LootOn` | `1` | Master enable; skip all loot activity if 0 |
| `state.loot.radius` | `CorpseRadius` | `100` | Max range to consider corpses (informational; MQ2AutoLoot owns the actual check) |
| `state.loot.spamInfo` | `SpamLootInfo` | `1` | Mirror of MQ2AutoLoot's SpamLootInfo for binds display |

Wire in `init.lua` after `Config.load(State)` alongside the other INI blocks — no new module file needed for step 9.1.

**Implemented:**

- `MQ2AutoLoot` added to `REQUIRED_PLUGINS` in `config.lua` — missing plugin now prints a warning at startup alongside MQ2Exchange/MQ2Rez/etc.
- `state.loot.on`, `state.loot.radius`, `state.loot.spamInfo` added to `state.lua` with defaults `1`, `100`, `1`.
- All three fields wired from INI `[General]` keys `LootOn`, `CorpseRadius`, `SpamLootInfo` in `init.lua` immediately after `Config.load(State)`.

---

#### Step 9.2 — `loot.lua` scaffold + `Loot.init`

Create `modules/loot.lua` with the standard `init` + upvalue pattern:

```lua
local Loot = {}
local _state, _utils

function Loot.init(state, utils)
    _state = state
    _utils = utils
end
```

`Loot.init` validates that MQ2AutoLoot is loaded:

```lua
if not mq.TLO.Plugin('MQ2AutoLoot').IsLoaded() then
    _utils.warn('MQ2AutoLoot not loaded — looting disabled.')
    _state.loot.on = 0
end
```

Wire `require('modules.loot')` and `Loot.init(State, Utils)` into `init.lua` (after `Pull.init`).

---

#### Step 9.3 — Vendor/banker action helpers

Add three public functions that wrap the plugin's slash commands:

```lua
function Loot.sell()    mq.cmd('/autoloot sell')    end
function Loot.deposit() mq.cmd('/autoloot deposit') end
function Loot.barter()  mq.cmd('/autoloot barter')  end
```

These are the entire implementation — MQ2AutoLoot handles targeting validation and iteration internally.

---

#### Step 9.4 — In-game command binds

Add to `binds.lua` (alongside existing `/ka*` binds):

| Bind command | Action |
| --- | --- |
| `/kalooton` | `State.loot.on = 1` |
| `/kalootoff` | `State.loot.on = 0` |
| `/kasell` | `Loot.sell()` |
| `/kadeposit` | `Loot.deposit()` |
| `/kabarter` | `Loot.barter()` |

Update `Binds.register` / `Binds.unregister` accordingly. Pass `Loot` as a new argument to `Binds.register`.

---

#### Step 9.5 — Main loop guard (optional heartbeat)

MQ2AutoLoot fires autonomously on each advloot window update — no polling call is needed in the main loop. The only main-loop addition is a guard so the sell/deposit binds respect `loot.on`:

```lua
-- (no loop addition required for looting itself)
-- binds already check _state.loot.on before calling Loot.sell/deposit/barter
```

If future testing reveals the plugin needs a periodic nudge, add:

```lua
if State.loot.on and not State.combat.combatStart then
    Loot.tick()   -- no-op stub; expands if needed
end
```

---

**Done when:**

- Characters in a group auto-loot corpses per `Loot.ini` rules without any Lua polling.
- `/kasell` targets a merchant and sells all `=Sell` items.
- `/kadeposit` targets a banker and deposits all `=Deposit` / `=Keep` items.
- `/kabarter` opens the barter window and lists all `=Barter|#n` items.
- `LootOn=0` in INI (or `/kalootoff`) disables the binds without affecting MQ2AutoLoot's own config.
- Existing `Loot.ini` files (from Ninjadvloot.inc users) work without modification.

**Deferred:**

| Feature | Reason |
| --- | --- |
| Non-advloot classic loot window (`LootMobs` path) | Legacy path; all modern MQ2 setups use Advanced Looting |
| Forage item handling | MQ2AutoLoot handles forage events natively |
| `GlobalLoot` cross-character list | Handled by MQ2AutoLoot's group distribution logic |
| Per-character `LootOn` check for master looter selection | Handled internally by MQ2AutoLoot |

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
