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

### Milestone 5 — Healing & Recovery
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

### Milestone 6 — Buff System
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

#### Step 6.3 — `CheckBuffs`: entry parsing + self / group-type dispatch

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

---

#### Step 6.4 — `CheckBuffs`: single-target group iteration + class filters

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

---

#### Step 6.5 — `CheckBuffs`: special action tags + `CheckBegforBuffs`

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

---

#### Step 6.6 — `CheckPetBuffs` + `CheckBegforPetBuffs`

Port the pet-specific buff functions (mac:5402–5517, mac:13307+).

- **`Buffs.checkPetBuffs()`** (mac:5402): guards (`Me.Pet.ID`, `petOn`, `petBuffsOn`, `combatStart`, `pulling`, `timers.petBuffCheck`, invis); sets `state.timers.petBuffCheck = os.clock() + 60`; iterates `petBuffsArray`; per-entry: parse `1stPart|2ndPart|3rdPart`; `|dual` tag = different cast name vs buff check name; check spell in book vs item vs ability; scan 50 pet buff slots for `PTempBuff` match via `Me.PetBuff[j].Name`; if not found: `castWhat(1stPart, Me.Pet.ID, 'Pet-nomem')`; `|pettoys|begfor` — `Comms.broadcast('PetToysPlease Me.Pet.Name')` + timer; pet shrink after loop if `petShrinkOn`; clear target if pet was targeted
- **`Buffs.checkBegforPetBuffs()`** (mac:13307): iterates `state.buffs.kaBegForPetList`; resolves pet ID from group member name; casts pet toy spells; removes entries after success; clears `kaPetBegActive` when list empty
- Wire both into `init.lua` main loop after pet check (matches mac:396–397)

**Done when:** script buffs own pet from `petBuffsArray`; group pet toy requests processed.

---

#### Step 6.7 — Wire into main loop + `/buffgroup` + `/tbmanager` + `CastBuffsSpellCheck`

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

---

**Suggested order:** 6.1 → 6.2 → 6.3 → 6.4 → 6.5 → 6.6 → 6.7. Steps 6.2 and 6.6 can be worked in parallel with 6.3–6.5 once 6.1 is done. Steps 6.3 and 6.4 are one logical function split by complexity.

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
