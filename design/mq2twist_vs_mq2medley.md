# MQ2Twist vs MQ2Medley — Plugin Comparison

Researched 2026-04-27 to inform bard song management for the KissAssist Lua port.

**Decision: MQ2Medley replaces MQ2Twist for the Lua port.** See conclusion below.

---

## Comparison Table

| Aspect | MQ2Twist | MQ2Medley |
|---|---|---|
| **Core purpose** | Static fixed-sequence rotation — define gem numbers, repeat in order | Dynamic declarative scheduler — named medleys with per-song conditions and priority |
| **TLO exposed** | `Twist.Twisting` (bool), `Twist.Current` (int gem), `Twist.Next` (int gem), `Twist.List` (string) | `Medley.Active` (bool), `Medley.Medley` (string name), `Medley.TTQE` (double, seconds to queue empty) |
| **Start from Lua** | `mq.cmd('/twist 1 2 3')` | `mq.cmd('/medley burnset')` |
| **Stop from Lua** | `/twist stop` (pauses, remembers queue); `/twist clear` (resets) | `/medley stop` (clears state entirely); `/medley clear` |
| **Mid-combat switching** | Stop → restart — all song timers reset | `/medley newname` — tracks remaining buff durations, skips redundant recasts |
| **Per-song conditions** | None — all listed songs cast every cycle | Yes — each song entry: `Name^Duration_Expression^Condition_Expression` |
| **One-off song injection** | `/twist once` (limited, single-shot sequence) | `/medley queue <song> [-targetid\|-interrupt]` — inserts one cast without breaking the active medley |
| **INI format** | `[MQ2Twist]` global settings + `[Click_21..40]` for item clicks. Simple gem/slot list. | `[MQ2Medley]` global + one `[MQ2Medley-setname]` section per named medley. Songs defined as `songN=Name^Duration^Condition`. |
| **Condition expressions** | Not supported | Evaluated via `${Math.Calc}` — supports any MQ2 TLO expression |
| **Maintenance** | Last commit: Nov 2025. 42 commits. | Last commit: Nov 2025. 45 commits. |

---

## Key Differences

### Configuration philosophy
- **Twist:** Imperative — define gem numbers in INI, activate via `/twist 1 2 3`. Static.
- **Medley:** Declarative — define *named sets* with conditions in INI, activate by name. Dynamic.

### Song switching efficiency
- **Twist:** Changing sets requires `/twist stop` + `/twist 4 5 6`. All timers reset — songs will re-cast even if they still have duration remaining.
- **Medley:** `/medley newname` is atomic. Plugin tracks remaining buff duration on running songs and avoids redundant recasts. Critical for Bards who shift between burn and sustain rotations mid-combat.

### Queue support
- **Twist:** `/twist once` is a coarse workaround.
- **Medley:** `/medley queue <song>` injects a single-shot cast (e.g. an emergency slow or mez) into the active medley without tearing it down. This is exactly what `bard.lua` needs for event-driven interrupts from `events.lua`.

### Lua queryable state
- **Twist:** `Twist.Twisting` and `Twist.Current` tell you what's happening but not when the next slot will open.
- **Medley:** `Medley.TTQE` (time-to-queue-empty) lets `bard.lua` make timing decisions without polling — cleaner integration.

---

## Impact on the Lua Port

### bard.lua scope change
The `.mac` `DoBardStuff` sub drives Twist directly (gem lists, `BardWasTwisting`, `TwistOn`, `TwistHold`, `Twisting` flags). The Lua `bard.lua` will instead:

1. Define named medley sets in the character INI (`[MQ2Medley-melee]`, `[MQ2Medley-burn]`, `[MQ2Medley-oor]`, etc.)
2. Call `/medley <setname>` on context transitions (combat start, burn triggered, out of range, etc.)
3. Use `/medley queue` for single-shot songs triggered by events
4. Query `Medley.Active` and `Medley.TTQE` instead of `Twist.Twisting` / `Twist.Current`

### State.bard changes
`State.bard` fields that mapped to Twist concepts (`twistHold`, `wasTwisting`, `startTwist`) are replaced by:
- `State.bard.activeMedley` — name of the current medley set
- `State.bard.gomActive`, `State.bard.dpsTwisting` — retained (context flags, not Twist-specific)

### INI migration impact
Users will need to define `[MQ2Medley-*]` sections in their character INIs. The `.mac` `[MQ2Twist]` INI section is not forward-compatible — this is a one-time manual migration for Bard characters. Non-bard classes are unaffected.

### Required plugin list
- **Remove:** `MQ2Twist` (no longer required)
- **Add:** `MQ2Medley` (required for Bard roles; optional/no-op for all other roles)

---

## Conclusion

MQ2Medley is the correct choice for the Lua port. The three decisive factors:

1. **Less Lua logic.** Conditional song selection lives in INI expressions, not `bard.lua` code. The module only needs to call `/medley <setname>` on state transitions.
2. **Smarter switching.** Duration-aware set switching eliminates the "stop and restart all timers" problem that would require workaround logic in Lua.
3. **Queue injection.** `/medley queue` cleanly handles event-driven one-shot casts that `events.lua` will need to trigger without disrupting the active rotation.

---

## References

- MQ2Twist docs: https://www.redguides.com/docs/projects/mq2twist/
- MQ2Twist repo: https://github.com/RedGuides/MQ2Twist
- MQ2Medley docs: https://www.redguides.com/docs/projects/mq2medley/
- MQ2Medley repo: https://github.com/RedGuides/MQ2Medley
