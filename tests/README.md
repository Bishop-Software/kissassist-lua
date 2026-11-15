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
| `unit/test_config_args.lua` | `Config.parseArgs()`: roles, MA name, `assistAt` clamping, startup keyword and debug flags |
| `unit/test_config_cond.lua` | `Config.parseCondArray()` with case-insensitive `\|condN` detection (#172) |
| `unit/test_config_burn.lua` | `Config.parseBurnEntry()`: `.mac` Burn layout `Spell\|Target[\|abort][\|condN]`, old UI layout tolerated |
| `unit/test_charm.lua` | `Charm.init` (charm-class flag, INI defaults) and charm helpers |
| `unit/test_buffs.lua` | `State.buffs` fields for the BUFFSTATE actor system (#113) |
| `unit/test_healing_rez.lua` | Rez spells extracted from `[Heals]` into the auto-rez list |
| `unit/test_comms_announce.lua` | `Comms.announce` uses `/dgtell` only with DanNet on and peers present, else `/echo` |
| `unit/test_merc.lua` | Merc "never assists" regression: `Mercenary.State` handling |
| `unit/test_dps_immune.lua` | `Cast.combatCast` stops recasting a DPS spell on a mob that was immune to it, still casts it on other mobs |
| `unit/test_pull_aggro.lua` | `Utils.pullAggroID()` (the `.mac`'s `PullAggroTargetID`): XTarget-based pull aggro for normal and chain pulls (#224) |
| `unit/test_pull_arc.lua` | `Pull.pullAngles()` (the `.mac`'s `SetPullAngles`, including wrap through 0/360) and `Pull.headingTo()` (#226) |
| `unit/test_pull_ready.lua` | `Pull.pullAbilityReady()`: Melee/Pet always, Ranged via `RangedReady`, named pulls via spell/AA/disc/item readiness (#227) |
| `unit/test_pull_wait.lua` | `Pull.startPullWait()` / `Pull.pullWaiting()`: non-blocking PullWait timer, ends on expiry or aggro, sits to med when `MedOn` (#145) |
| `unit/test_pull_range.lua` | `Pull.rangeSet()` (the `.mac`'s `PullRangeSet`): range from Melee/Pet/spell/disc/AA/clicky/`Bow\|Arrow`, scaled by `PullRadiusToUse` (#225) |
| `unit/test_pull_ignore.lua` | `Pull.ignoreAdd()`: ignore-by-ID pull list format `\|id\|id\|`, no duplicates, no partial-ID matches (#144) |
| `unit/test_pull_map.lua` | `Pull.paintMap()` (the `.mac`'s `PaintMap`): `/mapfilter` circles painted once in camp with MQ2Map loaded, repainted after `mapSet` clears (#259) |
| `unit/test_pull_ranking.lua` | `Pull.setRanking()` (the `.mac`'s `UpdatePullRanking`) and `Pull.nameAllowed()`: `:`-marked MobsToPull entries become the pull-first list while ranking is on; off strips the marks (#146) |
| `unit/test_pull_move.lua` | `Pull.pickMoveUse()` (the `.mac`'s startup pick): nav when MQ2Nav has a mesh, else los; advpath only with a loaded path; re-picked after zoning (#264) |
| `unit/test_pull_level.lua` | `Pull.setPullLevel()` / `levelGained()` (PullLevel fixed/linked/auto/off) and `Pull.chainPullBusy()` (ChainPullHP) (#61) |

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

Start kissassist normally, then use the `/katest` bind:

```
/katest all                  ← runs all six suites in sequence
/katest debug_cmds           ← run one suite
/katest toggle_cmds
/katest camp_cmds
/katest switchma
/katest charm_cmds
/katest switchtarget
```

All tests save and restore any state they modify — it is safe to run in-game while the character is active.

### What they cover

| File | Assertions | What is tested |
|---|---|---|
| `integration/test_debug_cmds.lua` | 12 | `/debug on/off`, `/debug combat on/off`, `/debug all on/off`, `/kisscheck` and `/zoneinfo` no-crash |
| `integration/test_toggle_cmds.lua` | 12 | `/togglevariable` on bool (`dpsOn`, `meleeOn`) and number (`healsOn`); `/changevarint` for `assistAt` and `campRadius`; unknown-var no-crash guard |
| `integration/test_camp_cmds.lua` | 11 | `/makecamphere` sets `returnToCamp`, clears `chaseAssist`, captures current coords; `/campoff` clears flag; `/stayhere` sets flag and coords |
| `integration/test_switchma.lua` | ~5–6 | `/switchma <name>` updates `mainAssist` and resets `calledTargetID`; self-name sets `iAmMA=true`; no-arg guard leaves state unchanged; broadcast-skip form still updates state |
| `integration/test_charm_cmds.lua` | 16 | `State.charm` sub-table and field types exist at runtime; `charmArray` has 50 slots; `iAmACharmClass` matches character's class; `charm.on`/`charm.keep` are mutable; `petId`/`petZone` clear correctly |
| `integration/test_switchtarget.lua` | ~6 | `/kaswitchtarget` updates the aggro/combat target fields |

**Total: ~70 integration assertions**

---

## Infrastructure

| File | Purpose |
|---|---|
| `tests/run_tests.lua` | Unit test runner — runs the suites in its explicit list (register new `unit/test_*.lua` files there) |
| `tests/mock_mq.lua` | Programmable fake `mq` module: stubbed TLO, `cmd`, `parse`, `event`, `bind`, `delay` |
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
