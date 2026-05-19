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

**Scope:** Covers all implemented functionality as of Milestone 12 (M1–M12 complete). M13 (Advanced Combat Rotation) tests will be added when that milestone is implemented.

---

## Section 1 — Startup & Foundation

### 1.1 — Plugin validation

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 1.1.1 | All required plugins already loaded | Start with `MQ2Exchange`, `MQ2MoveUtils`, `MQ2Posse`, `MQ2Rez`, `MQ2AutoLoot` loaded | Script starts; no plugin messages printed |
| [ ] | 1.1.2 | Missing plugin auto-loads | Unload one required plugin; start script | Script prints loading message, loads the plugin, continues normally |
| [ ] | 1.1.3 | Plugin fails to load | Unload a plugin and make it unavailable; start script | Error message names the failed plugin; `checkPlugins` returns false |
| [ ] | 1.1.4 | Bard with MQ2Medley already loaded | Start as Bard role with `MQ2Medley` loaded | Script starts; no plugin messages printed |
| [ ] | 1.1.5 | Bard auto-loads MQ2Medley | Start as Bard role without `MQ2Medley` loaded | `Bard.init` loads MQ2Medley; yellow notice printed; medley switching functions normally |
| [ ] | 1.1.6 | Bard MQ2Medley fails to load | Start as Bard role; MQ2Medley unavailable on disk | Red error printed; script continues but medley switching is non-functional |

### 1.2 — Config loading

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 1.2.1 | First-run INI migration | Start with existing `.ini`, no `.lua` pickle present | Pickle created; `.ini.bak` written; no data loss |
| [ ] | 1.2.2 | Subsequent run loads pickle | Run again after migration | Loads `.lua` directly; `.ini.bak` untouched |
| [ ] | 1.2.3 | All 18 sections round-trip | Compare pickle values to original `.ini` | No keys dropped; no defaults incorrectly applied |
| [ ] | 1.2.4 | Role configs migrate | Test with melee, pet, puller, healer INIs | All role configs migrate and load correctly |

### 1.3 — Role and startup parameters

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 1.3.1 | Assist role with MA name | `/lua run kissassist-lua assist TankName` | Role = assist; MA = TankName |
| [ ] | 1.3.2 | Tank role | `/lua run kissassist-lua tank` | Role = tank; script assumes self as MA |
| [ ] | 1.3.3 | Puller role | `/lua run kissassist-lua puller TankName` | Role = puller; pull system active |
| [ ] | 1.3.4 | Pettank role | `/lua run kissassist-lua pettank` | Pet module active; BreakMez path enabled |
| [ ] | 1.3.5 | Clean shutdown | `/lua stop` | No Lua errors; all event and bind handlers cleaned up |

---

## Section 2 — Slash Commands

### 2.1 — Debug and diagnostics

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.1.1 | `/debug on` | Run command | General debug output enabled; confirmation printed |
| [ ] | 2.1.2 | `/debug off` | Run command | General debug output disabled |
| [ ] | 2.1.3 | `/debug all on` | Run command | All debug sub-systems enabled |
| [ ] | 2.1.4 | `/debug combat on` | Run command | Combat debug enabled; other systems unchanged |
| [ ] | 2.1.5 | `/debug combat off` | Run command | Combat debug disabled |
| [ ] | 2.1.6 | `/debug` (no args) | Run command | Toggles current debug state; prints new state |
| [ ] | 2.1.7 | `/debug help` | Run command | Prints valid sub-command list |
| [ ] | 2.1.8 | `/parse Me.Level` | Run command | Current level printed to chat |
| [ ] | 2.1.9 | `/zoneinfo` | Run command | Zone name, short name, or relevant zone data printed |
| [ ] | 2.1.10 | `/aggroinfo` | Run command | Aggro target or mob count info printed |
| [ ] | 2.1.11 | `/kisscheck` | Run command | Prints role, MA, assist-at %, combat state, key system on/off flags; no error |
| [ ] | 2.1.12 | `/kasettings` | Run command | Prints current config or settings summary; no error |

### 2.2 — Config and persistence

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.2.1 | `/iniwrite` | Run command | Config pickle flushed to disk; no Lua error |
| [ ] | 2.2.2 | `/writespells` | Run command | Current spell set written to pickle; no Lua error |
| [ ] | 2.2.3 | `/memmyspells` | Run command | Spells memorized from saved spell set; no Lua error |
| [ ] | 2.2.4 | `/togglevariable healsOn` | Run with heals on | `state.heal.healsOn` toggled off; confirmation printed |
| [ ] | 2.2.5 | `/togglevariable healsOn` | Run again | `state.heal.healsOn` toggled back on |
| [ ] | 2.2.6 | `/togglevariable conOn` | Run command | `state.cond.on` toggled; condition evaluation state flips |
| [ ] | 2.2.7 | `/changevarint assistAt 90` | Run command | `state.session.assistAt` updated to 90; confirmed via `/kisscheck` |
| [ ] | 2.2.8 | `/changevarint mezOn 1` | Run command | `state.mez.on` updated to 1; confirmed via `/kisscheck` or debug |
| [ ] | 2.2.9 | `/togglevariable` (no args) | Run command | Usage message printed; no crash |
| [ ] | 2.2.10 | `/changevarint` (no args) | Run command | Usage message printed; no crash |
| [ ] | 2.2.11 | `/mycmd` | Set `MyCmd` in INI; run command | Custom command string executed |

### 2.3 — Combat commands

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.3.1 | `/burn on` | Run command | `state.combat.burnOn = true`; confirmation printed |
| [ ] | 2.3.2 | `/burn off` | Run command | `state.combat.burnOn = false`; burn state cleared |
| [ ] | 2.3.3 | `/burn on doburn` | Run command in combat | Burn rotation fires immediately |
| [ ] | 2.3.4 | `/backoff` | Run in combat | Combat disengages; MA assist paused |
| [ ] | 2.3.5 | `/switchnow` | Run when non-MA; MA has target | Switches assist target to MA's current target |
| [ ] | 2.3.6 | `/switchma <Name>` | Run with valid player name | `state.session.mainAssist` updated; confirmation printed |
| [ ] | 2.3.7 | `/kisscast <SpellName>` | Run with a memmed spell | Spell cast immediately; bypasses rotation |

### 2.4 — Movement and camp commands

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.4.1 | `/makecamphere` | Run at current location | Camp coordinates set; `state.movement.campX/Y/Z` updated |
| [ ] | 2.4.2 | `/stayhere` | Run command | `state.movement.returnToCamp = true`; chase cleared |
| [ ] | 2.4.3 | `/campoff` | Run after camp is set | Camp disabled; return-to-camp stops |
| [ ] | 2.4.4 | `/chaseme` | Run on MA character | Other Lua chars begin chasing MA |
| [ ] | 2.4.5 | `/trackmedown` | Run command | Tracking behavior activated; no error |
| [ ] | 2.4.6 | `/campfire` | Stand at target spot; run command | Campfire placed; confirmation printed |

### 2.5 — Pull list management

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.5.1 | `/SetPullArc <degrees>` | Run with valid degree value | Pull arc updated; confirmation printed |
| [ ] | 2.5.2 | `/setpullranking <value>` | Run with ranking value | Pull ranking updated |
| [ ] | 2.5.3 | `/addpull` | Target a mob; run command | Mob added to pull list |
| [ ] | 2.5.4 | `/addignore` | Target a mob; run command | Mob added to ignore list; not pulled |

### 2.6 — Group and social commands

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.6.1 | `/buffgroup` | Run command | Force-buff cycle triggered; group buffs applied |
| [ ] | 2.6.2 | `/tbmanager` | Run command | Task or tribute manager interaction; no error |
| [ ] | 2.6.3 | `/addfriend <Name>` | Run with a player name | Player added to friends/social list |

### 2.7 — Mez commands

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.7.1 | `/addimmune` | Target a mob; run command | Mob ID added to `state.mez.immuneIDs`; confirmation printed |

### 2.8 — Loot commands

| Status | # | Command | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 2.8.1 | `/kalooton` | Run command | MQ2AutoLoot enabled (`/autoloot turn on`); confirmation printed |
| [ ] | 2.8.2 | `/kalootoff` | Run command | MQ2AutoLoot disabled (`/autoloot turn off`); confirmation printed |
| [ ] | 2.8.3 | `/kasell` | Run at merchant | Sell routine triggered; sellable items sold |
| [ ] | 2.8.4 | `/kadeposit` | Run at banker | Deposit routine triggered; items deposited |
| [ ] | 2.8.5 | `/kabarter` | Run at barter NPC | Barter routine triggered; no error |

---

## Section 3 — Combat

### 3.1 — Combat detection and assist

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 3.1.1 | Assist engages MA's target | MA attacks an NPC at ≥ assist-at % | Assist char targets and attacks MA's target |
| [ ] | 3.1.2 | Assist-at threshold | MA engages; mob is above then below threshold | Assist char only engages when MA's target is at or below `assistAt` HP% |
| [ ] | 3.1.3 | Tank role self-targets | Tank role; NPC attacks | Tank attacks NPC directly without MA requirement |
| [ ] | 3.1.4 | Combat detection ends | Kill mob; no more mobs in camp | Combat loop exits; character returns to neutral state |
| [ ] | 3.1.5 | MA dead — assist stops | MA character dies | Assist char stops attacking; waits for MA to return |

### 3.2 — Melee rotation (MashButtons / AB slots)

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 3.2.1 | Combat abilities fire | Engage NPC with AB slots configured | Combat abilities execute in rotation |
| [ ] | 3.2.2 | Ability on cooldown skipped | Ability not yet refreshed | Slot skipped; next slot tried |
| [ ] | 3.2.3 | False condition skips slot | Tag AB slot with false condition | Slot skipped in rotation |

### 3.3 — Spell rotation (DPS slots)

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 3.3.1 | DPS spells fire | Engage NPC with DPS slots configured | Spells cast in rotation order |
| [ ] | 3.3.2 | Spell on recast timer skipped | Spell recently cast | Slot skipped; rotation continues |
| [ ] | 3.3.3 | False condition skips slot | Tag DPS slot with false condition | Slot skipped that tick |
| [ ] | 3.3.4 | Mana below threshold | Mana drops below DPS cast threshold | DPS rotation pauses |

### 3.4 — Burn system

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 3.4.1 | Burn activates on command | `/burn on doburn` in combat | Burn spells/abilities fire from Burn slots |
| [ ] | 3.4.2 | Burn deactivates on command | `/burn off` | Burn rotation stops; normal DPS resumes |
| [ ] | 3.4.3 | Burn fires on target | `/burn on doburn` with current target | `state.combat.burnID` set to current target ID |
| [ ] | 3.4.4 | False condition skips burn entry | Tag burn entry with false condition | Burn entry skipped |

### 3.5 — FaceMob

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 3.5.1 | FaceMob on engage | `FaceMobOn=1`; engage new mob | Character faces mob on first engage |
| [ ] | 3.5.2 | FaceMob re-facing | Mob moves; `FaceMobOn=1` | Character periodically re-faces mob during combat |
| [ ] | 3.5.3 | FaceMob disabled | `FaceMobOn=0` | Character does not auto-face mob |

---

## Section 4 — Healing

### 4.1 — Single heals

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 4.1.1 | Self-heal fires | HP drops below `SHealPct` | Heal fires on self |
| [ ] | 4.1.2 | Group member healed | Group member HP drops below threshold | Healer casts heal on that member |
| [ ] | 4.1.3 | Heals toggle | `/togglevariable healsOn` | Heals disabled; no heals fire until re-enabled |
| [ ] | 4.1.4 | False condition skips heal | Tag heal slot with false condition | Heal slot skipped |

### 4.2 — Group heals

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 4.2.1 | Group heal fires | Multiple group members below threshold | Group heal cast |
| [ ] | 4.2.2 | False condition skips group heal | Tag group heal with false condition | Group heal skipped |

### 4.3 — Cures

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 4.3.1 | Cure fires on debuff | Character or group member afflicted | Appropriate cure cast |
| [ ] | 4.3.2 | False condition skips cure | Tag cure slot with false condition | Cure skipped |

### 4.4 — AutoRez

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 4.4.1 | Rez fires on corpse | Group member dies; rezzer has rez spell | Rez cast on corpse |
| [ ] | 4.4.2 | False condition skips rez | Tag rez slot with false condition | Rez skipped |

---

## Section 5 — Buffs

### 5.1 — Self buffs

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 5.1.1 | Self buff applied | Buff expires | Re-applied on next buff cycle |
| [ ] | 5.1.2 | Buff already present skipped | Buff still active | Buff not re-cast unnecessarily |
| [ ] | 5.1.3 | False condition skips buff | Tag buff slot with false condition | Buff skipped |

### 5.2 — Group buffs

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 5.2.1 | Group buff applied | Group member missing buff | Buff cast on that member |
| [ ] | 5.2.2 | `/buffgroup` forces cycle | Run command | Buff cycle fires immediately regardless of timer |

### 5.3 — Pet buffs

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 5.3.1 | Pet buff applied | Pet missing buff | Buff cast on pet |
| [ ] | 5.3.2 | False condition skips pet buff | Tag pet buff slot with false condition | Pet buff skipped |

### 5.4 — Beg-for-buffs

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 5.4.1 | Beg triggers on missing buff | Buff slot marked as beg-for; buff missing | Beg request broadcast |
| [ ] | 5.4.2 | Beg stops when buff present | Buff received | Beg requests stop |

---

## Section 6 — Pulling and Movement

### 6.1 — Pull system

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 6.1.1 | Puller finds mob | Puller role; mobs in pull range | Mob selected and pull initiated |
| [ ] | 6.1.2 | Pull arc respected | Mob outside pull arc | Mob not pulled |
| [ ] | 6.1.3 | Pull range respected | Mob outside max pull range | Mob not pulled |
| [ ] | 6.1.4 | Ignore list respected | Mob on ignore list | Mob skipped; next candidate chosen |
| [ ] | 6.1.5 | Priority list pulled first | Mob on `/addpull` list in range | That mob pulled before others |
| [ ] | 6.1.6 | Chain pull | `ChainPull` enabled; kill occurs | Next pull starts immediately |

### 6.2 — Camp return

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 6.2.1 | Returns to camp after combat | Kill mob outside camp; combat ends | Character walks back to camp radius |
| [ ] | 6.2.2 | Camp radius respected | Character within camp radius | No movement initiated |
| [ ] | 6.2.3 | `/campoff` disables return | Run `/campoff` | Character no longer returns to camp |

### 6.3 — Chase mode

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 6.3.1 | Chase follows MA | `/chaseme` run on MA; MA moves | Assist char follows MA |
| [ ] | 6.3.2 | `/stayhere` stops chase | Run `/stayhere` | Chase stops; `returnToCamp` set |

### 6.4 — Stuck recovery

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 6.4.1 | Stuck detection fires | Character stops moving while pathing | Stuck recovery routine activates; character moves |

---

## Section 7 — Pet

### 7.1 — Pet combat

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 7.1.1 | Pet attacks MA's target | Combat starts; `PetOn=1` | Pet receives `/pet attack` on MA's target |
| [ ] | 7.1.2 | Pet backs off non-MA target | Pet attacks wrong mob | `/pet back off` issued |
| [ ] | 7.1.3 | Pet hold mode | `PetHold=1` | Pet does not attack until released |

### 7.2 — Pet buffs

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 7.2.1 | Pet buffs applied | Pet missing configured buff | Pet buff cast |
| [ ] | 7.2.2 | Pet buff skipped when buffed | Buff already on pet | No re-cast |

### 7.3 — Rampage-pet pull gating

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 7.3.1 | Pull gated on pet rampage | Pet has rampage mob; puller configured | Pull does not start while pet has rampage mob |

### 7.4 — Pet toys

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 7.4.1 | Pet toy cast | `PetToyOn=1`; pet in combat | Pet toy item used on pet |

---

## Section 8 — Bard

### 8.1 — Medley context switching

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 8.1.1 | Melee medley on engage | Bard enters combat | `/medley melee` issued; melee medley plays |
| [ ] | 8.1.2 | Burn medley on burn | `/burn on doburn` | `/medley burn` issued during burn window |
| [ ] | 8.1.3 | OOR medley out of combat | Combat ends; no mobs | `/medley oor` issued |
| [ ] | 8.1.4 | GoMSpell | GoM proc detected | One-shot spell queued via `/medley queue` without disrupting active medley |

### 8.2 — WeaveArray

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 8.2.1 | Weave entries fire in order | WeaveArray configured | Weave spells cycle in defined order |
| [ ] | 8.2.2 | False condition skips weave entry | Tag weave slot with false condition | Entry skipped; next weave entry tried |

---

## Section 9 — Looting

### 9.1 — AutoLoot toggle

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 9.1.1 | Loot on enables MQ2AutoLoot | `/kalooton` | MQ2AutoLoot enabled; items looted from corpses |
| [ ] | 9.1.2 | Loot off disables MQ2AutoLoot | `/kalootoff` | MQ2AutoLoot disabled; corpses not auto-looted |
| [ ] | 9.1.3 | Loot default on startup | `loot.on=1` in state | MQ2AutoLoot enabled automatically on script start |

### 9.2 — Sell / deposit / barter

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 9.2.1 | Sell at merchant | `/kasell` while merchant window open | Sellable items sold; no error |
| [ ] | 9.2.2 | Deposit at banker | `/kadeposit` while banker window open | Items deposited; no error |
| [ ] | 9.2.3 | Barter | `/kabarter` at barter NPC | Barter process completes; no error |

---

## Section 10 — Condition Evaluation

### 10.1 — Core condition engine

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 10.1.1 | `conOn=0` bypasses all conditions | `/togglevariable conOn` (off); tag DPS slot with `\|cond001` | Slot fires regardless of condition value |
| [ ] | 10.1.2 | True condition allows cast | Set `Cond1=${Me.PctHPs}>1`; tag DPS slot `\|cond001` | Slot fires normally |
| [ ] | 10.1.3 | False condition skips cast | Set `Cond1=${Me.PctHPs}>999`; tag DPS slot `\|cond001` | Slot skipped that tick |
| [ ] | 10.1.4 | `TARGETCHECK` sentinel | Set `Cond1=TARGETCHECK`; tag a CastWhat entry | Target validity check fires; invalid target skips cast |

### 10.2 — Per-system condition gating

| Status | # | System | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 10.2.1 | DPS rotation | Tag DPS slot with false condition | Slot skipped in combatCast |
| [ ] | 10.2.2 | MashButtons (AB slots) | Tag melee ability with false condition | Ability skipped |
| [ ] | 10.2.3 | Buffs | Tag buff slot with false condition | Buff skipped |
| [ ] | 10.2.4 | Pet buffs | Tag pet buff with false condition | Pet buff skipped |
| [ ] | 10.2.5 | Single heal | Tag heal slot with false condition | Heal skipped |
| [ ] | 10.2.6 | Group heal | Tag group heal with false condition | Group heal skipped |
| [ ] | 10.2.7 | Cures | Tag cure with false condition | Cure skipped |
| [ ] | 10.2.8 | AutoRez | Tag rez with false condition | Rez skipped |
| [ ] | 10.2.9 | Burn entries | Tag burn entry with false condition | Burn entry skipped |
| [ ] | 10.2.10 | Bard GoMSpell | Tag GoM spell with false condition | GoM spell skipped |
| [ ] | 10.2.11 | Bard WeaveArray | Tag weave entry with false condition | Weave entry skipped |

### 10.3 — ConOn toggle

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 10.3.1 | Toggle off | `/togglevariable conOn` when on | Conditions ignored; all conditioned slots fire |
| [ ] | 10.3.2 | Toggle on | `/togglevariable conOn` when off | Conditions evaluated; false conditions skip slots |
| [ ] | 10.3.3 | `/kisscheck` output | Run `/kisscheck` | Prints current `conOn` state |

---

## Section 11 — Mez System

### 11.1 — Module init and config

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 11.1.1 | Module init with mez off | Start script with `MezOn=0` | `Mez.init()` runs; mez check is a no-op; no error |
| [ ] | 11.1.2 | Config loads | Set `MezSpell` and `MezOn=1` in INI | `state.mez.spell` and `state.mez.on` populated correctly |

### 11.2 — Single mez

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 11.2.1 | Add gets mezzed | Two mobs aggro; `MezOn=1`; mob count ≥ `MezSingleCount` | Second mob mezzed automatically |
| [ ] | 11.2.2 | Mezzed mob not attacked | Non-MA char has mezzed mob as target | Cast skipped; mezzed mob not woken |
| [ ] | 11.2.3 | HP threshold skip | Mob HP below `MezPct` | Mez skipped for that mob |
| [ ] | 11.2.4 | Mana check | Char below mana to cast mez spell | Mez skipped |
| [ ] | 11.2.5 | Spell not ready | Mez spell on cooldown | Mez skipped until ready |

### 11.3 — AE mez

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 11.3.1 | AE mez fires | Mob count in AE range ≥ `MezAECount`; `MezOn=1` or `3` | AE mez spell cast |
| [ ] | 11.3.2 | AE mez suppressed | `MezOn=2` (single only) | AE mez does not fire |
| [ ] | 11.3.3 | AE timer cooldown | AE mez just cast | AE mez does not fire again until timer expires |

### 11.4 — MezBroke event and re-mez

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 11.4.1 | Mob wakes | Mezzed mob wakes naturally or is woken | `MezBroke` event fires; `state.mez.broke = true`; per-slot mez timers cleared |
| [ ] | 11.4.2 | Re-mez fires | After MezBroke | Mez check re-fires on next tick; mob re-mezzed if eligible |

### 11.5 — Immune list

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 11.5.1 | Add to immune list | Target a mob; run `/addimmune` | Mob ID added to `state.mez.immuneIDs`; confirmation printed |
| [ ] | 11.5.2 | Immune mob skipped | Immune mob aggros | Mez not cast on that mob |
| [ ] | 11.5.3 | Dead immune cleared | Immune mob dies | ID pruned from immune list on next cycle |

### 11.6 — BreakMez (pettank role)

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 11.6.1 | BreakMez fires | Pettank role; mezzed mob in camp | `PetBreakMezSpell` cast on mob to wake it for pet |
| [ ] | 11.6.2 | Non-pettank skips | Assist or tank role | BreakMez not called |

---

## Section 12 — Cross-Character Communication

### 12.1 — Actors backend

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 12.1.1 | Module loads | Start script | `Comms.init()` runs; actors backend detected; no error |
| [ ] | 12.1.2 | `/stayhere` broadcast | Run `/stayhere` on one Lua char | Other Lua chars set `returnToCamp = true`; chase cleared |
| [ ] | 12.1.3 | `/chaseme` broadcast | Run `/chaseme` on MA | Other Lua chars begin chasing MA |
| [ ] | 12.1.4 | Camp broadcast | Run `/makecamphere` | Other Lua chars receive and store camp coordinates |
| [ ] | 12.1.5 | Buff broadcast | Wait one buff cycle | `state.buffs.remote[charName]` populated on all Lua chars |
| [ ] | 12.1.6 | Clean shutdown | `/lua stop` | Actors mailbox unregistered; no orphaned handlers |

### 12.2 — DanNet shim (`.mac` interop)

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 12.2.1 | DanNet shim active | One char on `.mac`, one on Lua; DanNet loaded | `.mac` DanNet messages received and acted on by Lua char |
| [ ] | 12.2.2 | Actors preferred | Both backends available | Actors used as primary; DanNet as fallback only |

### 12.3 — Multi-character integration

| Status | # | Scenario | Steps | Expected |
| --- | --- | --- | --- | --- |
| [ ] | 12.3.1 | MA on `.mac`, assist on Lua | `.mac` MA engages target | Lua assist char attacks MA's target |
| [ ] | 12.3.2 | Healer on Lua | Group member takes damage | Lua healer heals `.mac` group members |
| [ ] | 12.3.3 | Puller on `.mac` | Puller initiates pull | Lua assist chars engage pulled mob correctly |
| [ ] | 12.3.4 | Cross-char buff sharing | Buff expires on `.mac` char | Lua buff char rebuffs `.mac` char |

---

*Last updated: 2026-05-19. Covers all implemented functionality through Milestone 12. Milestone 13 (Advanced Combat Rotation) test section to be added when M13 is implemented.*
