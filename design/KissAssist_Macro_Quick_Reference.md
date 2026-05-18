# KissAssist Macro Quick Reference

## What This Is

This is a compact companion to the full analysis, intended for quick lookups while running or tuning KissAssist.

## Build Snapshot

- Macro: KissAssist v12.002 (per header)
- Primary file: kissassist.mac
- Included loot module: Ninjadvloot.inc
- Complexity (approx): 290 subroutines, 113 events, 31 binds

## Startup Flow

1. Starts in Main.
2. Parses startup parameters (role, MA, assist percent, ini override, parse mode, path).
3. Loads or creates character INI.
4. Loads aliases and settings sections.
5. Initializes plugins and runtime data.
6. Enters perpetual main loop (events, combat, heal, buff, pull, loot).

## Required Runtime Pieces

- MQ2Exchange
- MQ2MoveUtils
- MQ2Posse
- MQ2Rez
- MQ2Twist (for bards)
- Extended Target properly configured (Auto Hater slots)
- Ninjadvloot include present

## Optional Integrations

- MQ2Melee
- MQ2Cast
- MQ2DanNet
- MQ2EQBC
- MQ2Nav
- MQ2AdvPath
- MQ2DPSAdv
- MQ2Map
- MQ2Notepad
- MQ2SpawnMaster
- MQ2Log

## Core Systems At A Glance

- Combat and target control: assist, MA checks, raid-target checks, switch logic.
- Casting engine: spell, AA, disc, item, command casting with interrupt and remem support.
- Movement: return-to-camp, chase, anti-stuck, LOS or nav movement.
- Pulling: discovery, validation, pull methods (melee, ranged, spell, pet, nav, advpath).
- Healing and cures: single/group triage, rez routines, cure checks.
- Buffing: self/group logic, rebuff handling, cross-character tracking.
- Pet management: summon, buff, combat, toys, mez-break support.
- Mez control: single and AE mez workflows, mez-immune handling.
- Looting: delegated to Ninjadvloot logic when enabled.

## High-Impact Settings To Verify First

- Role
- Main assist target
- AssistAt
- ReturnToCamp or ChaseAssist (mutually behavior-shaping)
- CampRadius and MeleeDistance
- PullWith and MaxRadius and MaxZRange
- HealsOn and key Heals entries
- BuffsOn and key Buffs entries
- CuresOn and cure entries
- PetOn and pet spell or buffs
- UseMQ2Melee (plugin behavior changes)
- EQBCOn or DanNetOn (group command behavior)

## Common Failure Points

- Not enough Auto Hater xtarget slots (required for normal and chain-pull behavior).
- Plugin missing or unloaded unexpectedly.
- Pull validation rejects mobs (range, LOS, level, path, nearby PCs, pull arc).
- Mismatch between selected role and available assist or tank context.
- INI drift: stale or inconsistent values after many incremental edits.

## Safe Bring-Up Checklist

1. Start with conservative settings: no chain pull, moderate radius, clear assist target.
2. Confirm required plugins are loaded.
3. Confirm xtarget Auto Hater slot configuration.
4. Validate role and assist target at startup echo.
5. Enable systems gradually: combat first, then heals, buffs, pull, finally extras.
6. Turn on debug selectively (not all channels at once).

## Useful Operational Commands

- Toggle and tuning style commands:
  - assists and engagement: assistat, meleeon, meleedistance
  - healing and cures: healson, autorezon
  - buffs and rebuff: buffson, rebuffon, buffgroup
  - movement and camp: chase, chaseon, chaseoff, camphere, makecamphere, campradius
  - pulling: maxradius, maxzrange, setpullarc, setpullranking
  - combat pacing: dpson, dpsinterval, dpsskip
  - diagnostics: debug, kisscheck, kasettings load

## When To Use Which Movement Mode

- LOS mode: simplest fallback, least dependency.
- MQ2Nav mode: preferred when mesh is good and available.
- MQ2AdvPath mode: use for curated pull routes and special terrain handling.

## Practical Tuning Priorities

1. Stabilize targeting and movement first.
2. Then stabilize heal thresholds.
3. Then optimize DPS ordering and intervals.
4. Add advanced pull options only after baseline is stable.

## Related Notes

- Full report: KissAssist_Macro_Analysis_Summary.md
- Main script: kissassist.mac
- Loot include: Ninjadvloot.inc
