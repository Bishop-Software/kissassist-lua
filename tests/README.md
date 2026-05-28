# KissAssist Lua — Test Suite

Two complementary test approaches: **unit tests** (pure Lua, no active character needed) and **integration tests** (run against a live kissassist session in-game).

---

## Unit Tests

Unit tests run entirely inside MQ without needing combat or group members. They cover pure logic, state defaults, and condition evaluation using a mock `mq` module — no real EverQuest state is accessed.

### How to run

Start any character in EverQuest, then:

```
/lua run kissassist-lua tests/run_tests
```

kissassist does **not** need to be running. The test runner is a standalone script.

### What they cover

| File | Assertions | What is tested |
|---|---|---|
| `unit/test_state.lua` | 86 | All 16 `State.*` sub-tables exist with correct default values and array sizes |
| `unit/test_utils.lua` | 15 | `timerExpired()` / `setTimer()` math; `setFlag` / `setAll` helpers |
| `unit/test_helpers_module.lua` | 26 | `dist2D`, `slotIsDebuff` boundary cases, `applyDAMod` (all DAMod forms: `+N`, `-N`, absolute, empty) |
| `unit/test_cond.lua` | 22 | `Cond.eval()`: `conOn=false` bypass, truthy/falsy `mq.parse` results, all `TARGETCHECK` sub-conditions (nil target, PC type, dead, 0 HP, name substring) |
| `unit/test_config_args.lua` | 56 | `Config.parseArgs()`: all 10 roles, uppercase normalisation, `assistAt` boundary clamping (0/101 ignored), all startup keyword flags (`debug`, `debugall`, `debugcombat`, parse-mode) |

**Total: 205 unit assertions**

### Expected output

```
[TEST] Starting KissAssist unit test suite...
[PASS] test_state            86/86 assertions
[PASS] test_utils            15/15 assertions
[PASS] test_helpers_module   26/26 assertions
[PASS] test_cond             22/22 assertions
[PASS] test_config_args      56/56 assertions
[TEST] Suite complete: 205 passed, 0 failed
```

---

## Integration Tests

Integration tests run from **within a live kissassist session**. They issue slash commands via `mq.cmd()`, yield with `mq.delay()` to let the deferred bind execute, then assert against the live `State` table.

### How to run

Start kissassist normally, then use the `/katest` bind:

```
/katest all                  ← runs all four suites in sequence
/katest debug_cmds           ← run one suite
/katest toggle_cmds
/katest camp_cmds
/katest switchma
```

All tests save and restore any state they modify — it is safe to run in-game while the character is active.

### What they cover

| File | Assertions | What is tested |
|---|---|---|
| `integration/test_debug_cmds.lua` | 12 | `/debug on/off`, `/debug combat on/off`, `/debug all on/off`, `/kisscheck` and `/zoneinfo` no-crash |
| `integration/test_toggle_cmds.lua` | 12 | `/togglevariable` on bool (`dpsOn`, `meleeOn`) and number (`healsOn`); `/changevarint` for `assistAt` and `campRadius`; unknown-var no-crash guard |
| `integration/test_camp_cmds.lua` | 11 | `/makecamphere` sets `returnToCamp`, clears `chaseAssist`, captures current coords; `/campoff` clears flag; `/stayhere` sets flag and coords |
| `integration/test_switchma.lua` | ~5–6 | `/switchma <name>` updates `mainAssist` and resets `calledTargetID`; self-name sets `iAmMA=true`; no-arg guard leaves state unchanged; broadcast-skip form still updates state |

**Total: ~46 integration assertions**

---

## Infrastructure

| File | Purpose |
|---|---|
| `tests/run_tests.lua` | Unit test runner — discovers and runs all `unit/test_*.lua` files |
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
