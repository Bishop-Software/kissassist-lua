# KissAssist Lua — Test Suite

Two complementary test approaches: **unit tests** (pure Lua, no active character needed) and **integration tests** (run against a live kissassist session in-game).

---

## Unit Tests

Unit tests run entirely inside MQ without needing combat or group members. They cover pure logic, state defaults, and condition evaluation using a mock `mq` module — no real EverQuest state is accessed.

### How to run

Start any character in EverQuest, then:

```
/lua run kissassist-lua test
```

kissassist does **not** need to be running. The test runner is a standalone script.

### What they cover

Suites run in the order listed in `tests/run_tests.lua`. **A new `unit/test_*.lua` file must be added to that list or it won't run.**

| File | What is tested |
|---|---|
| `unit/test_state.lua` | All `State.*` sub-tables exist with correct default values and array sizes |
| `unit/test_utils.lua` | `timerExpired()` / `setTimer()` math; `setFlag` / `setAll` helpers |
| `unit/test_helpers_module.lua` | `dist2D`, `applyDAMod` (all DAMod forms: `+N`, `-N`, absolute, empty) |
| `unit/test_cond.lua` | `Cond.evalStr()` / `Cond.eval()`: truthy/falsy `mq.parse` results, TLO-expanded comparisons including `!=`, all `TARGETCHECK` sub-conditions |
| `unit/test_config_args.lua` | `Config.parseArgs()`: roles, MA name, `assistAt` clamping, startup keyword and debug flags; `paused` starts soft-paused and isn't taken as the MA name (#353) |
| `unit/test_config_cond.lua` | `Config.parseCondArray()` with case-insensitive `\|condN` detection (#172) |
| `unit/test_config_burn.lua` | `Config.parseBurnEntry()`: `.mac` Burn layout `Spell\|Target[\|abort][\|condN]`, old UI layout tolerated |
| `unit/test_charm.lua` | `Charm.init` (charm-class flag, INI defaults) and charm helpers |
| `unit/test_buffs.lua` | `State.buffs` fields for the BUFFSTATE actor system (#113) |
| `unit/test_healing_rez.lua` | Rez spells extracted from `[Heals]` into the auto-rez list |
| `unit/test_comms_announce.lua` | `Comms.announce` uses `/dgtell` only with DanNet on and peers present, else `/echo` |
| `unit/test_merc.lua` | Merc "never assists" regression: `Mercenary.State` handling |
| `unit/test_camp_toggle.lua` | Movement modes (#362): `Control.setMode` manual / camp (here, resume, no camp) / chase, `group` and `others` broadcasts (`CAMP`, `CAMPON`, `CAMPOFF`, `STAY`, `CHASE`); the `/kactl mode` parser and command; `/makecamphere`, `/stayhere` (others only), `/chaseme` (others only), `/trackmedown`, `/campon` / `/campoff` gone; received group messages (STAY stops, CHASE turns camp off, outside the group ignored); DanNet relay as `/waithere` / `/chase on`; `${KissAssist.Mode}` |
| `unit/test_bard_aa_ready.lua` | Bard `castWhat` with an AA on cooldown: direct-cast senders (Regenother, Buffs) return `CAST_RECOVER` without stopping the medley or sending `/alt act`; queued senders aren't queued until it's ready |
| `unit/test_dps_immune.lua` | `Cast.combatCast` stops recasting a DPS spell on a mob that was immune to it, still casts it on other mobs |
| `unit/test_pull_aggro.lua` | `Utils.pullAggroID()` (the `.mac`'s `PullAggroTargetID`): XTarget-based pull aggro for normal and chain pulls (#224) |
| `unit/test_pull_arc.lua` | `Pull.pullAngles()` (the `.mac`'s `SetPullAngles`, including wrap through 0/360) and `Pull.headingTo()` (#226) |
| `unit/test_pull_ready.lua` | `Pull.pullAbilityReady()`: Melee/Pet always, Ranged via `RangedReady`, named pulls via spell/AA/disc/item readiness (#227) |
| `unit/test_pull_wait.lua` | `Pull.startPullWait()` / `Pull.pullWaiting()`: non-blocking PullWait timer, ends on expiry or aggro, sits to med when `MedOn` (#145) |
| `unit/test_pull_range.lua` | `Pull.rangeSet()` (the `.mac`'s `PullRangeSet`): range from Melee/Pet/spell/disc/AA/clicky/`Bow\|Arrow`, scaled by `PullRadiusToUse` (#225) |
| `unit/test_pull_ignore.lua` | `Pull.ignoreAdd()` / `pullIgnoreTick()`: the pull ignore list (`PullIgnore1`, `\|id\|id\|`) stays separate from MobsToIgnoreByID, no duplicates or partial-ID matches, dead entries dropped, cleared every 5 minutes (#144) |
| `unit/test_pull_map.lua` | `Pull.paintMap()` (the `.mac`'s `PaintMap`): `/mapfilter` circles painted once in camp with MQ2Map loaded, repainted after `mapSet` clears (#259) |
| `unit/test_pull_ranking.lua` | `Pull.setRanking()` (the `.mac`'s `UpdatePullRanking`) and `Pull.nameAllowed()`: `:`-marked MobsToPull entries become the pull-first list while ranking is on; off strips the marks (#146) |
| `unit/test_pull_move.lua` | `Pull.pickMoveUse()` (the `.mac`'s startup pick): nav when MQ2Nav has a mesh, else los; advpath only with a loaded path; re-picked after zoning (#264) |
| `unit/test_pull_level.lua` | `Pull.setPullLevel()` / `levelGained()` (PullLevel fixed/linked/auto/off) and `Pull.chainPullBusy()` (ChainPullHP) (#61) |
| `unit/test_pull_hold.lua` | `Pull.holdReasons()`, the Pull tab's held line: each hold (Pull off, medding, Group Watch waits, PullPause, corpse drag, PullWait, no camp, non-puller role) and the PullWith method not ready (spell recast seconds left, not memorized, Ranged) |
| `unit/test_pull_pause.lua` | PullPause (`Pull.setPullPause` / `pullPauseCheck` / `heldByCond`): pull X minutes then rest Y, idle restart, manual hold, `\|condN` hold condition (#61) |
| `unit/test_pull_role.lua` | `Pull.roleToggle()` (PullRoleToggle): pullerpettank group leader with a merc takes the group Puller role for a pull outside camp and drops it back in camp (#61) |
| `unit/test_pull_chain.lua` | `Pull.chainPullNextMob()` (the `.mac`'s `ChainPullNextMob`): mid-fight hand-off to the next pull below ChainPullHP, and every case that keeps fighting instead; chain pull is puller-only (#257) |
| `unit/test_pull_retry.lua` | A failed pull retries in place (`dispatchDone`); `pullWithCast` shrinks the pull distance out of sight, retries fizzles, and stops without casting while soft-paused (#351, #353) |
| `unit/test_afk_camp_on_death.lua` | CampOnDeath camp-out (#243); while soft-paused the stranger and GM holds are skipped but GM end/unload/quit still run (#353) |
| `unit/test_pause.lua` | Soft pause (#353): `Pause.set` is idempotent, stops attack/melee/stick/nav/moveto/advpath/pet/medley and resets combat when pausing, turns MQ2Melee back on when resuming (not while backed off); `loadSettings` (`*WhilePaused`); `warnAggro` throttle |
| `unit/test_tlo.lua` | `${KissAssist}` TLO (#353): member values, registration through a faked `mq.DataType` / `mq.AddTopLevelObject`, name already in use, unregister |
| `unit/test_control.lua` | `Control.set` (`modules/control.lua`, the one setter): every INI key the GUI sets resolves to its state field; value conversion (booleans, numbers, `on`/off, CastingInterruptOn 62); saving under a section; side effects (TargetSwitchingOn MA-only, MaxRadius leash, BuffsOn 2 group pets, DPSOn 2, ChaseAssist, ReturnToCamp new camp, waithere, GroupWatch routing); `/togglevariable` and `/changevarint` adapters |
| `unit/test_kactl.lua` | `/kactl` verbs (#363): the router and `${KissAssist.LastResult}`; `set` (values, `toggle`, `save` under the INI section found in the default config, no value rejected); `pause on|off|toggle`; `stop`; `target <id>|clear` (bad ID changes nothing); `charm on|off|toggle`, `keep`, `set`, `reset`; `medley quiet` (sent only on a change); `list burn|charmimmune add`; `test` (queued for the main loop); 3b replacements for the mac's commands (`backoff`, `burn`, `ignore <id>|clear`, `switch` non-MA only, `ma` group only with `group`, `cast` name + trailing ID, `debug`, `buff now`, `ini write`, `set PullRanking` rebuilds the pull list, `list toobuff`, `info`, `parse`); `Control.run` leaves LastResult alone; the deprecation notice (once per session, names the variable for `/togglevariable`/`/changevarint`, off with `LegacyCmdNotice`); the Lua-only commands they replace (`/kapause`, `/kastop`, `/katest`, `/charmon`, ...) are no longer bound |

Counts change as tests are added; the runner prints the current total.

### Expected output

```
[TEST] Starting KissAssist unit test suite...
[PASS] test_state                 n/n
[PASS] test_utils                 n/n
...
[TEST] Suite complete: N passed, 0 failed (of N total)
```

---

## Integration Tests

Integration tests run from **within a live kissassist session**. They issue slash commands via `mq.cmd()`, yield with `mq.delay()` to let the deferred bind execute, then assert against the live `State` table.

### How to run

Start kissassist normally, then use `/kactl test` (the run is queued and starts on the next main-loop pass):

```
/kactl test all              ← runs all seven suites in sequence
/kactl test debug_cmds       ← run one suite
/kactl test toggle_cmds
/kactl test camp_cmds
/kactl test switchma
/kactl test charm_cmds
/kactl test switchtarget
/kactl test recent
```

All tests save and restore any state they modify — it is safe to run in-game while the character is active.

### What they cover

| File | Assertions | What is tested |
|---|---|---|
| `integration/test_debug_cmds.lua` | 12 | `/debug on/off`, `/debug combat on/off`, `/debug all on/off`, `/kisscheck` and `/zoneinfo` no-crash |
| `integration/test_toggle_cmds.lua` | 45 | `/togglevariable` on bool (`dpsOn`, `meleeOn`) and number (`healsOn`); DPSOn 0/1/2 (`dpsOnOoc`); `/changevarint` for `assistAt` and `campRadius`; unknown-var no-crash guard; `/kactl pause` on/off/toggle (no argument rejected), `/kactl set MeleeOn` off/toggle/no value, `/kactl backoff` on/off, `/kactl debug combat` on/off, `/kactl ignore clear` and `${KissAssist.Paused}` / `.State` / `${KissAssist}` (#353, pauses briefly, so run it out of combat) |
| `integration/test_camp_cmds.lua` | 21 | `/makecamphere` sets `returnToCamp`, clears `chaseAssist`, captures current coords; `/kactl mode manual` keeps the spot; `/kactl mode camp resume` goes back to it (nothing with no camp); `/kactl mode camp here`; `/kactl mode chase <name>`; bad arguments change nothing; `${KissAssist.Mode}`. `/stayhere`, `/chaseme` and other group/others forms aren't run (they would move the live group's boxes) |
| `integration/test_switchma.lua` | ~5–6 | `/switchma <name>` updates `mainAssist` and resets `calledTargetID`; self-name sets `iAmMA=true`; no-arg guard leaves state unchanged; broadcast-skip form still updates state |
| `integration/test_charm_cmds.lua` | 16 | `State.charm` sub-table and field types exist at runtime; `charmArray` has 50 slots; `iAmACharmClass` matches character's class; `charm.on`/`charm.keep` are mutable; `petId`/`petZone` clear correctly |
| `integration/test_switchtarget.lua` | 8 | `/kactl target clear` and `<id>` update the aggro/combat target fields; a bad ID or no argument changes nothing; `${KissAssist.LastResult}` ok / error |
| `integration/test_recent.lua` | 15–16 | Recent PRs without a fight (#246): mac aliases in `MacroQuest.ini` (delete list and KissTell gone, `/ktdismount` kept); window title = parsed `WinTitleText`; CheckStuckGems leaves a normal client alone, Origin/CastingWindow lookups resolve; `petHoldCommand` follows the live Companion's Discipline rank; `stopMoving` returns at once when still; with a pet and PetHoldOn, the pet is really on hold/ghold. Re-sets the window title; puts the pet on hold if PetHoldOn |

**Total: ~81 integration assertions**

---

## Infrastructure

| File | Purpose |
|---|---|
| `tests/run_tests.lua` | Unit test runner — runs the suites in its explicit list (register new `unit/test_*.lua` files there) |
| `tests/mock_mq.lua` | Programmable fake `mq` module: stubbed TLO, `cmd`, `parse`, `event`, `bind`, `delay`. No `DataType` / `AddTopLevelObject`; `test_tlo` adds fakes and removes them again |
| `tests/test_helpers.lua` | Assert utilities used by both unit and integration tests: `assert_eq`, `assert_true`, `assert_false`, `assert_near`, `assert_raises`, `printSummary` |

---

## What Cannot Be Automated

The following require live combat, group members, or specific game states and remain manual per the test plan:

- Combat behavior (rotations firing on real mobs, aggro, target switching)
- Heals and cures (characters taking damage)
- Buffs (group members present, buff bar inspection)
- Pulling and movement (mobs, pathing, stuck recovery)
- Pet and bard live behavior
- Cross-character `.mac` interop (Milestone 12)
- Feign death, group escape, corpse recovery
- Stranger/GM hold sequences (AFK Tools)
- Soft pause (`/kactl pause`, #353) in action: the main loop doing nothing while paused; a pause sent mid-fight, mid-pull, mid-return-to-camp, mid-chase or mid-buff-cycle stopping it at once; `HealWhilePaused` / `MoveWhilePaused` / `WarnAggroWhilePaused`; the Pause button and PAUSED status; MQ2Boxr reading `${KissAssist.Paused}`
