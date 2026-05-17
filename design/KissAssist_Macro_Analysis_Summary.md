# KissAssist Macro Analysis Summary

## Executive Summary

Your macro is a large, mature, all-in-one automation framework for EverQuest boxing, not just a simple assist script. The main file kissassist.mac is about 934 KB and includes:

- 290 subroutines
- 113 event handlers
- 31 bind commands
- 1079 variable declarations

It is effectively a state machine that loops continuously, reacts to game text events, and orchestrates combat, movement, pull logic, healing, buffs, mez, pet management, looting, communication, and plugin coordination.

## What This Build Is

Based on the header in kissassist.mac, this is:

- KissAssist v12.002
- Maintained for RedGuides (dated 12/5/2025 in-file)
- Designed for many roles beyond basic assist: assist, tank, puller, pullertank, pettank, pullerpettank, hunter, hunterpettank, offtank
- Tightly integrated with MacroQuest plugins and RedGuides ecosystem

## Core Control Flow

The macro boot sequence starts in Main and does this in order:

- Unloads MQ2Bucles if found to avoid while-loop conflicts
- Parses command-line options (role, MA, assist %, parse mode, ini override, path, etc.) in PParse
- Loads or creates character INI and aliases
- Declares huge global or outer state sets via DeclareOuters
- Loads settings by section through Bind_Settings
- Initializes data and plugins via InitData and InitPlugins
- Enters the perpetual main loop

Main-loop cadence:

- Process queued events first
- Run combat, AE, mez, cures, heals
- Handle movement, chase, return-to-camp
- Manage rez, campfire, misc, merc, mana, pet, buffs, med, groupwatch
- If pull role is active, search, validate, and pull targets
- Re-check combat, then loot
- Sleep briefly and repeat

## Major Systems Mapped

### Combat and targeting

- CheckForCombat, Combat, GetCombatTarget
- MA and raid targeting and switch logic in CombatTargetCheck, CombatTargetCheckRaid, Bind_Switch, Bind_SwitchMA

### Casting engine

- Readiness and dispatch: CastReady, CastWhat
- Per-channel casts: CastAA, CastItem, CastDisc, CastCommand, CastSpell
- Interrupt and remem support: CastInteruptHeals, CastInteruptDPS, CastReMem

### Movement and navigation

- Return, chase, and stuck handling in DoWeMove, DoWeChase, Stuck
- Supports LOS movement, MQ2Nav, and MQ2AdvPath fallback and selection

### Pulling stack

- Discovery and validation: FindMobToPull, PullValidate, PullCheck
- Pull methods: PullWithMelee, PullWithRanged, PullWithCast, PullWithPet, PullUsingNav, PullUsingAdvPath
- Pull ranking and arc controls: Bind_SetPullRanking, UpdatePullRanking, Bind_SetPullArc

### Heals, cures, and rez

- Health and triage in CheckHealth, SingleHeal, DoGroupHealStuff
- Cures in CheckCures
- Rez logic in RezCheck and RezWithCheck

### Buff system

- Core buffing in CheckBuffs and CheckIniBuffs
- Cross-character state writes in WriteBuffs, plus WriteBuffsMerc and WriteBuffsPet
- Supports buff requests and conditional or targeted buff flags

### Pet system

- Main pet orchestration in DoPetStuff and CheckPetBuffs
- Pet toys pipeline in CastPetToys and PetToys
- Includes pet mez-break logic in BreakMez

### Mez and control

- DoMezStuff, MezMobs, MezMobsAE
- Mez immunity maintenance in AddMezImmune and Bind_AddMezImmune

### Looting

- Main macro includes Ninjadvloot.inc at load time
- Loot entrypoint in LootStuff
- Advanced Loot module has its own full logic set, initialized by SetupAdvLootVars

## Plugin and Integration Dependencies

Documented by the file itself and enforced by InitPlugins.

### Required behavior-critical plugins

- MQ2Exchange
- MQ2MoveUtils
- MQ2Posse
- MQ2Rez
- MQ2Twist (bard use)
- Extended Target setup
- Ninjadvloot include file

### Optional or conditional plugins

- MQ2Melee, MQ2Cast, MQ2DanNet, MQ2EQBC, MQ2Nav, MQ2AdvPath, MQ2DPSAdv, MQ2Map, MQ2Notepad, MQ2SpawnMaster, MQ2Log

Important behavior note:

- The macro can unload and reload some plugins during runtime and startup depending on settings (for example MQ2Melee and MQ2Cast), which is powerful but can surprise users running multiple scripts.

## How It Aligns With the Wiki

The macro matches the wiki’s major architecture and sections:

- General
- Spells
- Buffs
- Melee
- DPS
- Aggro
- Heals
- Cures
- Pet
- Mez
- Merc
- Pull
- PullAdvanced
- Burn
- AFKTools
- Conditions

Notable implementation-specific defaults in this build:

- AFKTools defaults in code are active-biased: AFKToolsOn default is 1 and radius 500
- FaceMobOn default in this build is 1
- CastingInterruptOn handling is custom: loaded as int, then normalized to internal value 62 when enabled
- Header wiki URL points to an older path, while modern docs use redguides.com/docs/projects/kissassist

## Operational Caveats and Risk Points

- Very high complexity and global-state density means small setting changes can create non-obvious side effects
- Chain pull requires multiple autohater x-target slots; macro exits if not configured
- PullPath key is marked placeholder or not fully implemented in settings text
- Messaging commands such as switch and chase group-wide require EQBC or DanNet plugin availability
- Heavy INI read and write usage across runtime supports resilience but increases dependency on clean config state
- The macro is strongly event-text-driven; chat filters, localization, or format changes can affect event triggers

## Bottom Line

This is a production-grade, feature-rich KissAssist branch with broad role support and substantial resilience tooling. It is closest to a configurable automation platform rather than a single-purpose combat macro. The architecture is robust but monolithic, so maintainability and troubleshooting depend heavily on disciplined INI management and plugin consistency.

## Optional Next Steps

- Build a practical safe baseline INI profile from this exact build (by role and class)
- Produce a subsystem call graph (combat, pull, heal, buff) with hot paths for debugging
- Audit your current INI against this code’s defaults and flag likely bad interactions
