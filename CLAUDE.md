# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**KissAssist v1.0.0 (Lua)** — A Lua refactor of the original KissAssist v12.002 `.mac` macro for automating multi-character group combat in EverQuest. Original macro written in MacroQuest's proprietary macro language; maintained by Ctaylor22 for RedGuides subscribers, originally created by Maskoi.

- Main file: `kissassist.mac` (~17,000 lines)
- Loot helper: `Ninjadvloot.inc` (~1,160 lines)
- No build system, compiler, or test suite — macros run directly inside the EverQuest client via MacroQuest

## Running the Script

### Lua Port (this repo)

```
/lua run kissassist-lua assist TankName 95
/lua run kissassist-lua assist
/lua run kissassist-lua tank
/lua run kissassist-lua puller TankName
```

Stop with `/lua stop kissassist-lua`.

### `.mac` Source (reference)

```
/mac kissassist assist TankName 95
/mac kissassist assist                  (target the main tank first)
/mac kissassist tank
/mac kissassist puller TankName
```

Supported roles: `assist`, `tank`, `puller`, `pullertank`, `pettank`, `pullerpettank`, `hunter`, `hunterpettank`, `offtank`

Optional flags appended to startup: `debug`, `debugall`, custom INI path, parse mode

## Architecture (.mac Source Reference)

The sections below describe the original `.mac` macro — useful context for understanding what was ported and why. For the Lua port's structure, see **Lua Port Layout** below.

### Execution Model

Event-driven state machine running at `#turbo 120` (~120 Hz). Each iteration of the `while(1)` main loop:

1. `/doevents` — dispatches ~113 `#Event` handlers for game text (cast results, combat messages, chat, zone events)
2. Combat detection → target selection → combat execution
3. Spell/AA/Disc/Item casting via `CastWhat` dispatcher
4. Healing, cures, rezzes
5. Pulling logic (if role includes puller)
6. Buff management (self, group, pets)
7. Movement (return-to-camp, chase, stuck recovery)
8. Looting via `Ninjadvloot.inc`
9. `delay 1` — prevents CPU spin

### Startup Sequence (`Sub Main`)

```
Unload MQ2Bucles plugin
DeclareOuters (pre)      ← base variable declarations
PParse                   ← parse command-line parameters
Load character INI       ← KissAssist_Server_Toon_Class.ini (or fallback)
LoadAliases
DeclareOuters (main/post/global)
Bind_Settings            ← load all INI sections into variables
IniCleanup               ← remove stale INI keys
InitData                 ← runtime data structures
InitPlugins              ← validate required plugins are loaded
SetupAdvLootVars
AssignMainAssist
→ enter main loop
```

### Key Subsystems

| Subroutine | Purpose |
|---|---|
| `CastWhat` | Central casting dispatcher → `CastAA`, `CastDisc`, `CastSpell`, `CastItem`, `CastCommand` |
| `CheckForCombat` | Detect combat, set MA/assist target |
| `Combat` | Execute melee/spell rotation in combat |
| `CombatTargetCheck` / `CombatTargetCheckRaid` | Select appropriate target |
| `CheckHealth` | Triage heals for self/group |
| `DoGroupHealStuff` | Group-wide heal logic |
| `CheckCures` | Debuff removal |
| `RezCheck` / `RezWithCheck` | Resurrection logic |
| `FindMobToPull` / `PullCheck` | Pull target discovery and execution |
| `CheckBuffs` / `WriteBuffs` | Self/group buffing + cross-character state tracking |
| `DoPetStuff` / `CheckPetBuffs` | Pet combat and buffs |
| `DoBardStuff` | Bard-specific song management (Lua port uses MQ2Medley, not MQ2Twist) |
| `LootStuff` | Delegates to `Ninjadvloot.inc` |
| `DoWeMove` / `DoWeChase` / `Stuck` | Camp return, chase, anti-stuck |

### State Variables

~1,079 global outer variables declared across multiple `DeclareOuters` calls. Key groups:

- **Combat**: `IAmMA`, `AggroTargetID`, `MobCount`, `IAmDead`, `ChainPull`
- **Movement**: `ReturnToCamp`, `ChaseAssist`, `CampX/Y/Z`, `CampRadius`
- **Role/Assist**: `Role`, `MainAssist`, `AssistAt`, `WhoToChase`
- **Pulling**: `PullMob`, `PullWith`, `MaxRadius`, `MaxZRange`, `PullRange`
- **Spells/Buffs**: `HealsOn`, `BuffsOn`, `CuresOn`, per-spell settings
- **Pet**: `PetOn`, `PetSpell`, `PetHoldMobs`, `PetToyName`

### In-Game Command Bindings

31 `#bind` directives expose toggle commands (e.g., `/kacampon`, `/kaburn`, `/kapullon`). These are the primary runtime controls during play.

### Event Handlers

113 `#Event` handlers parse EverQuest game text for real-time reactions: cast interruptions, resist messages, death notices, zone changes, tell/say commands from players, etc.

### Debug Preprocessor Macros

`#define` macros: `DEBUGN`, `DEBUGCAST`, `DEBUGCOMBAT`, etc. — conditionally emit debug output based on startup flags.

## Configuration

Character-specific INI files are auto-generated on first run:

- `KissAssist_ServerName_ToonName_ClassShort.ini` (preferred)
- `KissAssist_ToonName_ClassShort.ini` (fallback)

Key INI sections: `[General]`, `[Spells]`, `[Buffs]`, `[Heals]`, `[Cures]`, `[Pet]`, `[Mez]`, `[Pull]`, `[PullAdvanced]`, `[Burn]`, `[Aggro]`, `[Melee]`, `[DPS]`, `[AFKTools]`, `[Conditions]`

Loot settings are in `Loot.ini` or a character-specific loot INI, managed by `loot.lua` (MQ2AutoLoot delegation) in the Lua port.

## Plugin Dependencies

**Required** (validated at startup by `Config.checkPlugins()`):

- `MQ2Exchange`, `MQ2MoveUtils`, `MQ2Posse`, `MQ2Rez`, `MQ2AutoLoot`
- Extended Target window with Auto Hater x-target slots configured in-game

**Required for Bard only:**

- `MQ2Medley` — named medley sets replace MQ2Twist for song management

**Optional** (conditionally used):

- `MQ2Cast` — casting management
- `MQ2Melee` — melee auto-attack
- `MQ2DanNet` — cross-character messaging (DanNet shim active during `.mac`→Lua migration; EQBC deprecated)
- `MQ2Nav` — navigation mesh pathfinding
- `MQ2AdvPath` — waypoint-based pathing

## Reference

- RedGuides wiki: <https://www.redguides.com/wiki/KissAssist>
- Analysis docs in repo: `design/KissAssist_Macro_Analysis_Summary.md`, `design/KissAssist_Macro_Quick_Reference.md`
- Lua migration plan: `design/kissassist_lua_migration_plan.md`

## Lua Port Layout

Run with: `/lua run kissassist-lua`

```
kissassist-lua/          ← repo root (deployed into MQ2's lua/ directory)
├── init.lua             ← entry point: require order, main loop, INI wiring
└── modules/
    ├── config.lua       ← INI→pickle migration, Config.load, Config.checkPlugins
    ├── state.lua        ← all runtime State.* sub-tables (replaces ~1,079 .mac globals)
    ├── utils.lua        ← debug logging, timer helpers (timerExpired/setTimer)
    ├── events.lua       ← all 113 mq.event() registrations (cast, combat, zone, pet, bard)
    ├── binds.lua        ← all 31 mq.bind() slash commands + loot binds
    ├── cast.lua         ← CastWhat dispatcher, CastSpell/AA/Disc/Item/Command, gem memory, stuck-gem detection
    ├── combat.lua       ← CheckForCombat, Combat rotation, CombatTargetCheck, burn system, per-slot timers
    ├── healing.lua      ← CheckHealth, DoGroupHealStuff, CheckCures, RezCheck
    ├── buffs.lua        ← CheckBuffs, WriteBuffs, beg-for-buffs, CheckPetBuffs
    ├── pull.lua         ← FindMobToPull, PullCheck, executePull, CheckRampPets integration
    ├── movement.lua     ← DoWeMove, DoWeChase, stuck recovery, camp management
    ├── pet.lua          ← DoPetStuff, petStateCheck, PetToys, CheckRampPets
    ├── bard.lua         ← DoBardStuff, MQ2Medley context switching (melee/burn/oor sets)
    ├── loot.lua         ← MQ2AutoLoot delegation: Loot.init, sell/deposit/barter helpers
    ├── comms.lua        ← cross-character messaging: Lua actors backend + DanNet shim (.mac interop)
    ├── cond.lua         ← KConditions evaluator: mq.parse expressions, TARGETCHECK sentinel
    └── mez.lua          ← Mez system: mezRadar, MezCheck, AECheck, BreakMez, immune list
```

### Module Dependency Rule

Every module receives `state` and `utils` at `init()` time. No module imports another domain module directly — cross-module communication goes through `State` exclusively (star topology, no circular deps). Selected modules also receive peer references at init (e.g. `Combat.init(state, utils, cast, healing, buffs, bard)`).

### Completed Milestones

| Milestone | PR | What was built |
| --- | --- | --- |
| 1 — Foundation | #1 | `init.lua`, `utils.lua`, `state.lua`, `config.lua`, plugin validation, main loop |
| 2 — Events & Binds | #2 | All 113 events in `events.lua`; all 31 binds in `binds.lua` |
| 3 — Casting Engine | #3 | `cast.lua`: full `CastWhat` dispatcher, gem memory, cast state machine |
| 4 — Combat Core | #4 | `combat.lua`: combat detection, melee/spell rotation, burn system |
| 5 — Healing | #5 | `healing.lua`: heals, cures, rez; wired into combat loop |
| 6 — Buffs | #6 | `buffs.lua`: self/group buffs, beg-for-buffs, `CheckPetBuffs` |
| 7 — Pulling & Movement | #7 | `pull.lua`, `movement.lua`: full pull/movement loop, all binds |
| 8 — Pet & Bard | #8 | `pet.lua`: pet control, rampage-pet gating; `bard.lua`: MQ2Medley switching |
| 9 — Looting | #9 | `loot.lua`: MQ2AutoLoot delegation, sell/deposit/barter; loot binds |
| 10 — Full Integration & Parallel Validation | #10 | Remaining stub binds; `comms.lua` cross-char messaging (actors + DanNet shim); main loop phase audit |
| 11 — Condition Evaluation (KConditions) | #11 | `cond.lua`: `mq.parse` evaluator, TARGETCHECK sentinel; wired into all rotation modules and `CastWhat` |
| 12 — Mez System | #12 | `mez.lua`: `mezRadar`, `Mez.check`, `Mez.aeCheck`, `Mez.breakMez`; `state.mez` (20 fields); `/addimmune` bind |
| 13 — Advanced Combat Rotation | #13 | Per-slot `slotTimers[]`, `DAMod` arithmetic, `DPSSkip` HP floor, `DPSOn==2` OOC, feign-death sequence, `TargetSwitchingOn`, stuck-gem re-mem |

## Before spawning any subagent

Only spawn subagents for complex, multistep tasks. For simple tasks (single file edits, targeted searches, quick lookups), handle directly.

When spawning, use the `Agent` tool with `subagent_type` set to the appropriate type (`Explore` for codebase search, `Plan` for architecture design, `claude` for general). Write a self-contained prompt — the subagent has no conversation context.

## For code search

Prefer cocoindex.search() over Grep for semantic/exploratory queries.
Use Grep only for exact string matches.

## Memory

claude-mem auto-captures observations. Use search() → get_observations()
for progressive retrieval (don't load everything).
