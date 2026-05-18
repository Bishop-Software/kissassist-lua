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

## Section 11 — Condition Evaluation (Milestone 11)

> Tests to be written when M11 implementation is complete.

### 11.1 — Core condition engine

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 11.1.1 | `ConOn=0` bypasses all conditions | Set `ConOn=0`; add `\|cond` to a DPS slot | Slot fires regardless of condition value |
| 11.1.2 | True condition allows cast | Set `Cond1=${Me.PctHPs}>1`; tag DPS slot `\|cond001` | Slot fires normally |
| 11.1.3 | False condition skips cast | Set `Cond1=${Me.PctHPs}>999`; tag DPS slot `\|cond001` | Slot is skipped that tick |
| 11.1.4 | `TARGETCHECK` sentinel | Set `Cond1=TARGETCHECK`; tag a CastWhat entry | Target validity check fires; invalid target skips cast |

### 11.2 — `\|cond` gating per system

| # | System | Steps | Expected |
| --- | --- | --- | --- |
| 11.2.1 | DPS rotation | Tag DPS slot with false condition | Slot skipped in combatCast |
| 11.2.2 | MashButtons | Tag melee ability with false condition | Ability skipped in MashButtons |
| 11.2.3 | Buffs | Tag buff slot with false condition | Buff skipped in CheckBuffs |
| 11.2.4 | Pet buffs | Tag pet buff with false condition | Pet buff skipped |
| 11.2.5 | Single heal | Tag heal slot with false condition | Heal skipped |
| 11.2.6 | Group heal | Tag group heal with false condition | Group heal skipped |
| 11.2.7 | Cures | Tag cure with false condition | Cure skipped |
| 11.2.8 | AutoRez | Tag rez with false condition | Rez skipped |
| 11.2.9 | Burn entries | Tag burn entry with false condition | Burn entry skipped |
| 11.2.10 | Bard GoMSpell | Tag GoM spell with false condition | GoM spell skipped |
| 11.2.11 | Bard WeaveArray | Tag weave entry with false condition | Weave entry skipped |

### 11.3 — `/togglevariable ConOn`

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 11.3.1 | Toggle off | `/togglevariable ConOn` when on | `state.cond.on = false`; conditions ignored |
| 11.3.2 | Toggle on | `/togglevariable ConOn` when off | `state.cond.on = true`; conditions evaluated |
| 11.3.3 | `/kisscheck` output | Run `/kisscheck` | Prints current `ConOn` state |

---

## Section 12 — Mez System (Milestone 12)

> Tests to be written when M12 implementation is complete.

### 12.1 — Module loads

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 12.1.1 | Module init | Start script with `MezOn=0` | `Mez.init()` runs; no error; mez check is a no-op |
| 12.1.2 | Config loads | Set `MezSpell` and `MezOn=1` in INI | `state.mez.spell` and `state.mez.on` populated correctly |

### 12.2 — Single mez

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 12.2.1 | Add gets mezzed | Two mobs aggro; `MezOn=1`; mob count ≥ `MezSingleCount` | Second mob mezzed automatically |
| 12.2.2 | Mezzed mob not attacked | Non-MA char has mezzed mob as target | Cast skipped; mezzed mob not woken |
| 12.2.3 | HP threshold skip | Mob HP below `MezPct` | Mez skipped for that mob |
| 12.2.4 | Mana check | Char below mana to cast mez spell | Mez skipped |
| 12.2.5 | Spell not ready | Mez spell on cooldown | Mez skipped until ready |

### 12.3 — AE mez

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 12.3.1 | AE mez fires | Mob count in AE range ≥ `MezAECount`; `MezOn=1` or `3` | AE mez spell cast |
| 12.3.2 | AE mez suppressed | `MezOn=2` (single only) | AE mez does not fire |
| 12.3.3 | AE timer cooldown | AE mez just cast | AE mez does not fire again until timer expires |

### 12.4 — MezBroke event and re-mez

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 12.4.1 | Mob wakes | Mezzed mob wakes naturally or is woken | `MezBroke` event fires; `state.mez.broke = true` |
| 12.4.2 | Re-mez fires | After MezBroke | Mez check re-fires on next tick; mob re-mezzed if eligible |

### 12.5 — `/addimmune` bind

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 12.5.1 | Add to immune list | Target a mob; run `/addimmune` | Mob ID added to `state.mez.immuneIDs`; confirmation printed |
| 12.5.2 | Immune mob skipped | Immune mob aggros | Mez not cast on that mob |
| 12.5.3 | Dead immune cleared | Immune mob dies | ID pruned from immune list on next cycle |

### 12.6 — BreakMez (pettank role)

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 12.6.1 | BreakMez fires | Pettank role; mezzed mob in camp | `PetBreakMezSpell` cast on mob to wake it for pet |
| 12.6.2 | Non-pettank skips | Assist or tank role | BreakMez not called |

---

## Section 13 — Advanced Combat Rotation (Milestone 13)

> Tests to be run after M13 implementation is complete.

### 13.1 — Per-slot timers

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 13.1.1 | ABTimer gates ability | Set ABTimer on a MashButton slot | Ability not re-cast until timer expires; fires again after |
| 13.1.2 | DPSTimer gates spell | Set DPSTimer on a DPS slot | Spell not re-cast until timer expires; fires again after |
| 13.1.3 | FDTimer controls FD cycle | Set FDTimer; enable FD cycling | FD re-fires after timer, not immediately on next tick |

### 13.2 — Advanced rotation modes

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 13.2.1 | DPSSkip skips N ticks | Set DPSSkip=2 on a slot | Slot fires every 3rd tick; skipped 2 ticks between fires |
| 13.2.2 | DPSOn==2 out-of-combat | Set DPSOn=2 on a slot | Slot fires outside combat; other slots do not |
| 13.2.3 | DPSInterval cadence | Set DPSInterval=500 | No two casts occur within 500 ms of each other |
| 13.2.4 | DAMod suppresses on DA | Set DAMod on a slot; activate a DA disc | Slot skipped while disc is active; resumes after disc drops |

### 13.3 — Feign-death sequence

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 13.3.1 | FD fires and waits | Enable FD cycling; engage NPC | FD cast; FDTimer wait; character re-engages after timer |
| 13.3.2 | FD abort on death | Character dies mid-FD cycle | Sequence aborts cleanly; no Lua error |

### 13.4 — Target switching

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 13.4.1 | MA retargets mid-rotation | MA switches target during rotation | Assist char switches to new target within same rotation cycle |
| 13.4.2 | TargetSwitchingOn=0 suppresses | Set TargetSwitchingOn=0; MA switches target | Assist char does not switch until next rotation cycle starts |

### 13.5 — Stuck-gem detection

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| 13.5.1 | Wrong spell in gem | Gem slot contains wrong spell | `castWhat` detects mismatch; re-mems correct spell; cast proceeds |
| 13.5.2 | Empty gem recovery | Gem slot unexpectedly empty mid-combat | `castWhat` mems spell; cast proceeds; warning logged |

---

## Known Deferred / Out of Scope

Features present in `.mac` that are not yet ported. Do not test for these behaviors.

| Area | Notes |
| --- | --- |
| `CombatTargetCheckRaid` | Raid/cross-char target selection; not ported |
| `MercsDoWhat` | Merc control; not ported |
| `AutoFireOn` branches | Ranged auto-fire logic; not ported |
| `namedWatchList` from `KissAssist_Info.ini` | Named mob watch list; INI loader not implemented |
| `SwitchMA` on offtank / MA-dead path | Cross-char MA failover; not ported |
| `BroadCast` burn/add/tank-announce | In-group announce on burn/add events; not ported |
| `combatReset`: DPS meter output (`MQ2DPSAdv`) | End-of-fight parse output; requires MQ2DPSAdv plugin; not in scope |
| `fight`: `combatPet` Summon Companion AA | In-combat pet resummon; not ported |

---

*Last updated: 2026-05-17. Milestones 1–9 code complete (PRs merged); tests not formally executed. Milestone 10 in progress. Milestones 11 (condition evaluation), 12 (mez system), and 13 (advanced combat rotation) planned; sections to be run after implementation.*
