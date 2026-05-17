# KissAssist Lua — In-Game Test Plan

All tests are manual and in-game. No automated test framework exists.

**Verification methods:**

- `[EQ]` — run from EQ chat bar
- `[mq_eval]` — run via mq-mcp mq_eval tool
- **Observation** — watch in-game character behavior

**Notation:**

- `[ ]` — not yet run
- `[x]` — passed
- `[!]` — known issue / deferred

---

## Milestones 1–9 — Code Complete (Tests Not Formally Executed)

All nine milestones merged to `main` via PRs. Individual test cases from the original plan were written but never run in-game. Milestone correctness was validated through code review and iterative in-game debugging during development, not a formal test pass.

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

---

## Section 10 — Full Integration & Parallel Validation (Milestone 10)

> Tests to be run as steps 10.1–10.6 are implemented.

### 10.1 — Stub binds

| # | Bind | Steps | Expected |
| --- | --- | --- | --- |
| 10.1.1 | `/kisscheck` | Run `/kisscheck` | Prints role, MA, assist-at %, key system on/off state; no error |
| 10.1.2 | `/writespells` | Run `/writespells` | Current spell set written to pickle; no Lua error |
| 10.1.3 | `/iniwrite` | Run `/iniwrite` | Config pickle flushed to disk; no Lua error |
| 10.1.4 | `/changevarint AssistAt 90` | Run command | `State.session.assistAt` updated to 90; confirmed via `/kisscheck` |
| 10.1.5 | `/togglevariable HealsOn` | Run command | `State.heal.healsOn` toggled; confirmation printed |
| 10.1.6 | `/kisscast <SpellName>` | Run with a memmed spell | Spell cast immediately; bypasses rotation |
| 10.1.7 | `/switchma <Name>` | Run with a valid player name | `State.session.mainAssist` updated; MA reassigned |
| 10.1.8 | `/campfire` | Stand at target spot; run command | Campfire placed; `state.misc.campfireOn = true` |
| 10.1.9 | `/parse Me.Level` | Run command | Current level printed to chat |
| 10.1.10 | `/mycmds` | Set `MyCmd` in INI; run command | Custom command string executed |

### 10.2 — comms.lua

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 10.2.1 | Module loads | Start script | `Comms.init()` runs; backend detected (actors or DanNet); no error |
| 10.2.2 | `/stayhere` broadcast | Run `/stayhere` on one Lua char | Other Lua chars set `returnToCamp = true`; chase cleared |
| 10.2.3 | `/chaseme` broadcast | Run `/chaseme` on MA | Other Lua chars begin chasing MA |
| 10.2.4 | Camp broadcast | Run `/makecamphere` | Other Lua chars receive and store camp coordinates |
| 10.2.5 | Buff broadcast | Wait one buff cycle | `State.buffs.remote[charName]` populated on all Lua chars |
| 10.2.6 | DanNet shim | One char on `.mac`, one on Lua | `.mac` DanNet messages received and acted on by Lua char |
| 10.2.7 | Clean shutdown | `/lua stop` | Comms mailbox unregistered; no orphaned actors or handlers |

### 10.3 — Main loop order

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 10.3.1 | Heal fires before buff cycle | Drop group member HP below heal threshold mid-buff-cycle | Heal fires on current tick; buff cycle resumes after |
| 10.3.2 | Pull phase is last | Observe tick order with `/debug all on` | Pull phase runs after all other phases; order matches `.mac` source |

### 10.4 — Single-character integration

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 10.4.1 | Full startup | `/lua run kissassist-lua tank` | Script starts; all modules load; no errors in console |
| 10.4.2 | Combat loop | Engage an NPC | Melee and spell rotation all fire |
| 10.4.3 | Camp return | `/makecamphere`; pull mob; kill it | Character returns to camp radius after combat ends |
| 10.4.4 | Burn window | `/kaburn`; engage NPC | Burn spells fire during burn window only |
| 10.4.5 | Clean shutdown | `/lua stop` | No Lua errors; all event and bind handlers cleaned up |

### 10.5 — Multi-character parallel validation

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 10.5.1 | MA on `.mac`, assist on Lua | `.mac` MA engages target | Lua assist char attacks MA's target |
| 10.5.2 | Healer on Lua | Group member takes damage | Lua healer heals `.mac` group members |
| 10.5.3 | Puller on `.mac` | Puller initiates pull | Lua assist chars engage pulled mob correctly |
| 10.5.4 | Cross-char buff sharing | Buff expires on `.mac` char | Lua buff char rebuffs `.mac` char |

### 10.6 — INI backward compatibility

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 10.6.1 | First-run migration | Start with existing `.ini`, no pickle present | Pickle created; `.ini.bak` written; no data loss |
| 10.6.2 | All 18 sections round-trip | Compare pickle values to original `.ini` | No keys dropped; no defaults incorrectly applied |
| 10.6.3 | Second run loads pickle | Run again after migration | Loads `.lua` directly; `.ini.bak` untouched |
| 10.6.4 | `/iniwrite` safety | Run `/iniwrite` after runtime config changes | Pickle updated; no data loss |
| 10.6.5 | Role coverage | Test with melee, pet, puller, healer INIs | All role configs migrate and load correctly |

---

## Known Deferred / Out of Scope

Features present in `.mac` that are not yet ported. Do not test for these behaviors.

| Area | Notes |
|------|-------|
| Mez system (`MezCheck`, `AECheck`, `BreakMez`) | Not ported; would require a mez module |
| `CombatTargetCheckRaid` | Raid/cross-char target selection; not ported |
| `MercsDoWhat` | Merc control; not ported |
| `AutoFireOn` branches | Ranged auto-fire logic; not ported |
| `namedWatchList` from `KissAssist_Info.ini` | Named mob watch list; INI loader not implemented |
| `SwitchMA` on offtank / MA-dead path | Cross-char MA failover; not ported |
| `BroadCast` burn/add/tank-announce | In-group announce on burn/add events; not ported |
| Condition evaluation (`condNumber`, `\|cond`) | Per-spell condition gating; M11 candidate |
| `doBurn`: per-entry `condNo` / `abortFlag` | Condition-gated burn entries; blocked on condition eval |
| `mashButtons`: `ConOn` condition path | Condition-gated melee abilities; blocked on condition eval |
| `combatCast`: per-slot timers (`ABTimer`, `DPSTimer`, `FDTimer`) | Fine-grained cast timing; not ported |
| `combatCast`: `DPSSkip`, `DPSOn==2`, `DAMod`, `DPSInterval` | Advanced rotation modes; not ported |
| `combatCast`: feign-death sequence (`FDTimer`) | FD pull cycling; not ported |
| `combatCast`: `WeaveArray` / `CastWeave` | Bard weave during cooldown; not ported |
| `combatCast`: `TargetSwitchingOn` + MA mid-rotation retarget | Dynamic retarget in rotation; not ported |
| `combatReset`: DPS meter output (`MQ2DPSAdv`) | End-of-fight parse output; not in scope |
| `fight`: `combatPet` Summon Companion AA | In-combat pet resummon; not ported |
| Stuck-gem detection in `castWhat` | Detects a spell stuck in gem slot; not ported |

---

*Last updated: 2026-05-17. Milestones 1–9 code complete (PRs merged); tests not formally executed. Milestone 10 in progress.*
