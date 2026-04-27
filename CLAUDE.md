# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**KissAssist v12.002** — A MacroQuest (MQ2) scripting macro for automating multi-character group combat in EverQuest. Written in MacroQuest's proprietary macro language. Maintained by Ctaylor22 for RedGuides subscribers; originally created by Maskoi.

- Main file: `kissassist.mac` (~17,000 lines)
- Loot helper: `Ninjadvloot.inc` (~1,160 lines)
- No build system, compiler, or test suite — macros run directly inside the EverQuest client via MacroQuest

## Running the Macro

Start from in-game EverQuest chat:
```
/mac kissassist assist TankName 95
/mac kissassist assist                  (target the main tank first)
/mac kissassist tank
/mac kissassist puller TankName
```

Supported roles: `assist`, `tank`, `puller`, `pullertank`, `pettank`, `pullerpettank`, `hunter`, `hunterpettank`, `offtank`

Optional flags appended to startup: `debug`, `debugall`, custom INI path, parse mode

## Architecture

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
| `DoBardStuff` | Bard-specific song twist management |
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

Loot settings are in `Loot.ini` or a character-specific loot INI, managed by `Ninjadvloot.inc`.

## Plugin Dependencies

**Required** (validated at startup by `InitPlugins`):
- `MQ2Exchange`, `MQ2MoveUtils`, `MQ2Posse`, `MQ2Rez`, `MQ2Twist`
- Extended Target window with Auto Hater x-target slots configured in-game

**Optional** (conditionally used):
- `MQ2Cast` — casting management (macro may unload/reload it)
- `MQ2Melee` — melee auto-attack (macro may unload/reload it)
- `MQ2DanNet` or `MQ2EQBC` — cross-character messaging
- `MQ2Nav` — navigation mesh pathfinding
- `MQ2AdvPath` — waypoint-based pathing
- `MQ2DPSAdv`, `MQ2Map`, `MQ2Notepad`, `MQ2SpawnMaster`, `MQ2Log`

## Reference

- RedGuides wiki: https://www.redguides.com/wiki/KissAssist
- Analysis docs in repo: `KissAssist_Macro_Analysis_Summary.md`, `KissAssist_Macro_Quick_Reference.md`
