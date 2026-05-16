# KissAssist Lua — In-Game Test Plan (Milestones 1–5)

All tests are manual and in-game. No automated test framework exists.
Tests are ordered from cheapest (startup/config) to most interactive (casting).

**Verification methods used:**
- **Chat output** — printf lines visible in EQ game chat
- **mq_eval** — use mq-mcp `mq_eval` tool to inspect Lua state live
- **Observation** — watch in-game character behavior

**Notation:**
- `[EQ]` — run from EQ chat bar  
- `[mq_eval]` — run via mq-mcp mq_eval tool  
- `[ ]` — unchecked test (to be run)  
- `[x]` — passed  
- `[!]` — known issue / deferred

---

## Section 1 — Startup & Config (Milestone 1)

### 1.1 Basic startup

**Setup:** No script running. Character is logged in.

| # | Action | Expected output / state |
|---|--------|------------------------|
| 1.1.1 | `[EQ] /lua run kissassist-lua assist TankName 95` | Prints `KissAssist 1.0.0 starting... Role: assist`; prints `Main Assist: TankName Assist At: 95%`; prints `KissAssist ready. Entering main loop.` |
| 1.1.2 | `[EQ] /lua run kissassist-lua tank` | Prints role `tank`; no MA line |
| 1.1.3 | `[EQ] /lua run kissassist-lua puller TankName` | Prints role `puller`, MA = TankName |
| 1.1.4 | `[EQ] /lua run kissassist-lua assist ma TankName assistat 80` | Prints `Assist At: 80%` |
| 1.1.5 | After any startup: `[mq_eval] return mq.TLO.Lua.Script('kissassist-lua').Status()` | Returns `"Running"` |

---

### 1.2 Debug flags

| # | Action | Expected |
|---|--------|----------|
| 1.2.1 | `/lua run kissassist-lua assist debug` | `state.debug.general == true`; other flags false |
| 1.2.2 | `/lua run kissassist-lua assist debugall` | All `state.debug.*` fields true |

**Verify with:**
```lua
-- [mq_eval] Check general debug flag
local s = require('modules.state'); return tostring(s.debug.general)
```
> Note: kissassist-lua runs in its own Lua VM — `require` from mq_eval will get a fresh module, not the live instance. Verify debug behavior by watching chat output from debug-category prints instead.

---

### 1.3 CLI arg edge cases

| # | Action | Expected |
|---|--------|----------|
| 1.3.1 | `/lua run kissassist-lua 75` | `assistAt = 75` (bare number sets assistAt%) |
| 1.3.2 | `/lua run kissassist-lua SomePlayer` | `mainAssist = "SomePlayer"` (bare non-role string = MA name) |
| 1.3.3 | `/lua run kissassist-lua ini MyCustom.ini` | Uses `MyCustom.ini` instead of auto-resolved name |

---

### 1.4 INI migration (first run)

**Setup:** A valid `KissAssist_<Server>_<Name>_<Class>.ini` exists in `mq.configDir`. No `.lua` pickle exists yet.

| # | Action | Expected |
|---|--------|----------|
| 1.4.1 | Start the script | Prints `Migrating KissAssist_*.ini to pickle...` then `Migration complete. Backup: KissAssist_*.ini.bak` |
| 1.4.2 | Check filesystem | `mq.configDir/kissassist-lua/KissAssist_*.lua` exists; original `.ini` renamed to `.ini.bak` |
| 1.4.3 | Start again | Prints `Loaded config from KissAssist_*.lua` (no re-migration) |

---

### 1.5 Config.get accessor

**Setup:** Script running with loaded config.

| # | Action | Expected |
|---|--------|----------|
| 1.5.1 | Call `Config.get('General', 'KissAssistVer', 'none')` | Returns version string from INI, not `'none'` |
| 1.5.2 | Call `Config.get('General', 'MissingKey', 'fallback')` | Returns `'fallback'` |
| 1.5.3 | Call `Config.get('MissingSection', 'Key', 'default')` | Returns `'default'` |

---

### 1.6 State initialization from TLOs

**Setup:** Script started and in main loop.

| # | Action | Expected |
|---|--------|----------|
| 1.6.1 | Compare campX/Y/Z printed at startup to `/loc` | Match character's starting position |
| 1.6.2 | Start on a Bard — `state.session.iAmABard` | `true` for BRD, `false` for all other classes |
| 1.6.3 | Check `state.session.zoneName` | Matches `Zone.ShortName()` |
| 1.6.4 | Check `state.cast.gemSlots` | `8 + Mnemonic Retention rank` (e.g. 12 for rank 4) |
| 1.6.5 | Start in a DMZ zone (ID 345, 344, 202, 203, 279, 151, or 33506) | `state.misc.dmz == true` |

---

### 1.7 Plugin validation

| # | Action | Expected |
|---|--------|----------|
| 1.7.1 | Start with all required plugins loaded | No missing-plugin warnings |
| 1.7.2 | Unload `MQ2Posse`, start script | Warning: `missing required plugins: MQ2Posse` — script continues |

---

### 1.8 Main loop and shutdown

| # | Action | Expected |
|---|--------|----------|
| 1.8.1 | Script running for 30+ seconds | No errors; `Status()` remains `"Running"` |
| 1.8.2 | `[EQ] /lua stop kissassist-lua` | Prints `KissAssist 1.0.0 stopped.`; `Status()` returns `"Idle"` or `-1` |

---

## Section 2 — Events (Milestone 2)

**Setup for all 2.x tests:** Script running with debug cast enabled: `/debug cast on`

### 2.1 Cast result events

These fire from game text. Trigger each by causing the condition in-game or by looking for the print in chat after a failed cast.

| # | Trigger | Event name | Expected `state.cast.castReturn` | Chat output |
|---|---------|------------|-----------------------------------|-------------|
| 2.1.1 | Begin casting any spell | CAST_BEGIN | `CAST_SUCCESS` (optimistic) | `[debug cast] CAST_BEGIN` |
| 2.1.2 | Spell fizzles | CAST_FIZZLE | `CAST_FIZZLE` | `[debug cast] CAST_FIZZLE` |
| 2.1.3 | Casting interrupted (move/hit) | CAST_INTERRUPTED | `CAST_INTERRUPTED` | `[debug cast] CAST_INTERRUPTED` |
| 2.1.4 | Target resists | CAST_RESISTED | `CAST_RESISTED` | `[debug cast] CAST_RESISTED` |
| 2.1.5 | Spell takes hold / blocked | CAST_TAKEHOLD | `CAST_TAKEHOLD` | `[debug cast] CAST_TAKEHOLD` |
| 2.1.6 | Target immune (e.g. snare) | CAST_IMMUNE | `CAST_IMMUNE` | `[debug cast] CAST_IMMUNE` |
| 2.1.7 | Out of mana | CAST_OUTOFMANA | `CAST_OUTOFMANA` | `[debug cast] CAST_OUTOFMANA` |
| 2.1.8 | Recast timer not met | CAST_NOTREADY | `CAST_NOTREADY` | `[debug cast] CAST_NOTREADY` |
| 2.1.9 | Haven't recovered yet | CAST_RECOVER | `CAST_RECOVER` | `[debug cast] CAST_RECOVER` |
| 2.1.10 | Must be standing | CAST_STANDING | `CAST_RESTART`; `/stand` issued | `[debug cast] CAST_STANDING` |
| 2.1.11 | Cannot see target | CAST_CANNOTSEE | `CAST_CANNOTSEE` | `[debug cast] CAST_CANNOTSEE` |
| 2.1.12 | Gate collapses | CAST_COLLAPSE | `CAST_COLLAPSE` | `[debug cast] CAST_COLLAPSE` |
| 2.1.13 | "You are stunned" | CAST_STUNNED | `CAST_STUNNED` | `[debug cast] CAST_STUNNED` |
| 2.1.14 | Must first select a target | CAST_NOTARGET | `CAST_NOTARGET` | `[debug cast] CAST_NOTARGET` |
| 2.1.15 | Target out of range | CAST_OUTOFRANGE | `CAST_OUTOFRANGE` | `[debug cast] CAST_OUTOFRANGE` |
| 2.1.16 | Missing components | CAST_COMPONENTS | `CAST_COMPONENTS` | `[debug cast] CAST_COMPONENTS` |
| 2.1.17 | "This spell does not work here" | CAST_OUTDOORS | `CAST_OUTOFMANA` (**intentional**: preserves .mac quirk) | `[debug cast] CAST_OUTDOORS` |

---

### 2.2 Combat and session events

**Setup:** Enable combat debug: `/debug combat on`

| # | Trigger | Event | Expected state change | Verify |
|---|---------|-------|-----------------------|--------|
| 2.2.1 | Get hit by a mob | GotHit | `state.combat.gotHitToggle = true`; `state.timers.sitToMed` set ~6s from now | Debug print `GotHit: <mob>` |
| 2.2.2 | Die | ImDead | `state.session.iAmDead = true`; "I have died" printed; second death event skipped (deduplicated) | Debug print `ImDead` |
| 2.2.3 | Zone to new area | Zoned | `state.timers.justZoned > os.clock()`; `state.session.zoneName` updated; `state.misc.dmz` updated | Debug print `Zoned: <msg>` |
| 2.2.4 | Zone to DMZ (e.g. Guild Hall, zone ID 344) | Zoned | `state.misc.dmz = true` | Chat print |
| 2.2.5 | `/camp` | Camping | `state.terminate = true`; script stops | Script stops; prints stopped message |
| 2.2.6 | MA broadcasts attack target (AttackCalled pattern) | AttackCalled | `state.combat.calledTargetID` set to mob ID | Debug print `AttackCalled: <MA> ID:<mobID>` |
| 2.2.7 | AttackCalled when `iAmMA = true` | AttackCalled | `calledTargetID` unchanged (guarded) | — |
| 2.2.8 | Terrain too steep to camp | TooSteep | `state.misc.campfireOn = false`; printf printed | Chat: `TooSteep: CampfireOn disabled.` |
| 2.2.9 | Player joins group | Joined | `state.buffs.forceBuffs = true`; `state.timers.joinedParty` set | Debug print `Joined: <name>` |
| 2.2.10 | Mez message fires (mob awakened) | MezBroke | `state.mez.broke = true` | Debug print `MezBroke: <mob> by <breaker>` |

---

### 2.3 Buff, pet, and utility events

| # | Trigger | Event | Expected |
|---|---------|-------|----------|
| 2.3.1 | GoM fires (non-BRD/BER/MNK/ROG/WAR) | GoMOn | `state.bard.gomActive = true` (if in combat and gomTimer expired) |
| 2.3.2 | GoM fades | GoMOff | `state.bard.gomActive = false` |
| 2.3.3 | "Your <spell> spell has worn off of <name>" | WornOff | `state.buffs.forceBuffs = true`; `state.timers.readBuffs = 0` |
| 2.3.4 | Pet says "By your command, master" | PetSusStateAdd1 | `state.pet.suspendState = true`; `state.pet.activeState = false`; `totCount = 1` |
| 2.3.5 | Pet says "I live again..." | PetSusStateSub | `state.pet.activeState = true`; `state.pet.suspendState = false` |
| 2.3.6 | Player sends a /tell | YouGotTell | Prints `====> <name> Sent you a Tell: <text> <====` |
| 2.3.7 | Tell from a pet | YouGotTell | Suppressed (no print) |
| 2.3.8 | `[MQ2] KTDismount` fires | KTDismount | `state.misc.mountOn = false`; `/dismount` issued if mounted |
| 2.3.9 | KissAssist Debug Off Marker in chat | MLogOff | `state.debug.logging = false`; `/mlog off` if logging was on |

---

### 2.4 Binds — fully implemented

**Setup:** Script running.

| # | Command | Expected |
|---|---------|----------|
| 2.4.1 | `/debug` | Toggles `state.debug.general`; prints `>> Debug general On/Off` |
| 2.4.2 | `/debug all on` | All debug flags set to true; prints `>> Debug All On` |
| 2.4.3 | `/debug all off` | All debug flags false; prints `>> Debug All Off` |
| 2.4.4 | `/debug cast on` | `state.debug.cast = true` |
| 2.4.5 | `/debug combat off` | `state.debug.combat = false` |
| 2.4.6 | `/debug help` | Prints usage line |
| 2.4.7 | `/debug cast on log` | Enables cast debug AND toggles mlog |
| 2.4.8 | `/burn on` | `state.combat.burnOn = true`; prints `Turning Burn On.` |
| 2.4.9 | `/burn off` | `state.combat.burnOn = false`; `burnActive = burnCalled = false`; `burnID = 0`; prints `Turning Burn Off.` |
| 2.4.10 | `/burn on doburn` (with NPC targeted) | `burnCalled = true`; `burnID` set to target's ID |
| 2.4.11 | `/backoff` (no args) | Toggles `state.dps.paused`; prints `Backing off — DPS paused.` or `Resuming — DPS active.` |
| 2.4.12 | `/backoff on` | `state.dps.paused = true`; `state.combat.combatStart = false` |
| 2.4.13 | `/backoff off` | `state.dps.paused = false` |
| 2.4.14 | `/makecamphere` | `state.movement.campX/Y/Z` updated to current position; `returnToCamp = true`; `chaseAssist = false`; prints coordinates |
| 2.4.15 | `/aggroinfo` | Prints XTarget slot info + MA + group MA info; no crash |
| 2.4.16 | `/zoneinfo` | Prints zone name, MobsToPullRaw, etc.; no crash |
| 2.4.17 | `/addfriend` (PC targeted) | `/posse add/save/load` called; prints `>> Added <name> to Posse list.` |
| 2.4.18 | `/addfriend` (no target or NPC) | Prints `--ADDFRIEND: Target a PC...` |

---

### 2.5 Binds — stubs (verify no crash, correct message)

| # | Command | Expected message |
|---|---------|-----------------|
| 2.5.1 | `/switchnow` | `>> Switch target called.` |
| 2.5.2 | `/switchma NewMA` | `>> SwitchMA: NewMA — full logic in M4` |
| 2.5.3 | `/kisscast SomeSpell` | `>> KissCast: SomeSpell — M3` |
| 2.5.4 | `/stayhere` | `>> StayHere — cross-char broadcast in M9` |
| 2.5.5 | `/chaseme` | `>> ChaseMe <myname> — cross-char broadcast in M9` |
| 2.5.6 | `/trackmedown` | `>> TrackMeDown — M7` |
| 2.5.7 | `/buffgroup` | `>> BuffGroup — full run in M6`; `state.timers.readBuffs = 0` |
| 2.5.8 | `/campfire` | `>> Campfire disabled` (when `campfireOn=false`) |
| 2.5.9 | `/addpull` | `>> AddToPull — M7` |
| 2.5.10 | `/addignore` | `>> AddToIgnore — M7` |
| 2.5.11 | `/addimmune` | ~~stub~~ — implemented Step 5.1; see Section 5.2 |
| 2.5.12 | `/writespells` | `>> WriteMySpells — M10` |
| 2.5.13 | `/kisscheck` | `>> KissCheck (INI scan) — M10` |
| 2.5.14 | `/kasettings` | `>> KaSettings — M11` |
| 2.5.15 | `/kissedit` | Opens INI in MQ2Notepad (or warns if plugin missing) |

---

## Section 3 — Casting Engine (Milestone 3)

**Setup:** Script running. Character is a caster class with spells in gem slots.
Enable cast debug throughout: `/debug cast on`

---

### 3.1 castTarget

| # | Setup | Action | Expected |
|---|-------|--------|----------|
| 3.1.1 | Any NPC in zone | Call `castTarget(spawnID)` via castWhat dispatch | Target switches to that NPC within 500ms |
| 3.1.2 | `whatID = 0` | castTarget called with 0 | No action (guarded) |
| 3.1.3 | Target already correct | castTarget called with current target ID | No visible delay; target unchanged |

---

### 3.2 castCommand

| # | Setup | Action | Expected |
|---|-------|--------|----------|
| 3.2.1 | Script running | `/kisscast command:/say hello` — routed via castWhat → castCommand | Character says "hello" in chat; returns `CAST_SUCCESS` |
| 3.2.2 | | `castWhat('command:/melody med', 0, 'buffs')` | Executes `/melody med`; returns `CAST_SUCCESS` |

---

### 3.3 castSpell

**Prerequisite:** Have a spell memed in a gem slot.

| # | Action | Expected |
|---|--------|----------|
| 3.3.1 | Call `castWhat('<MemedSpellName>', targetID, 'DPS')` on valid target | Character casts spell; returns `CAST_SUCCESS` |
| 3.3.2 | Call `castWhat('<NotMemedSpell>', 0, 'DPS')` (spell in book, not memed, no miscGem configured) | Returns `CAST_NO_RESULT` with printf "Skip Casting X. Spell Not Memed." |
| 3.3.3 | Invis + call castWhat with a non-heal sentFrom | Returns `CAST_CANCELLED`; no cast attempted |
| 3.3.4 | Interrupt cast mid-spell (take damage with CastingInterrupt conditions met) | Returns `CAST_INTERRUPTED` |
| 3.3.5 | Cast a short-recast spell that fizzles | Retries automatically; returns `CAST_FIZZLE` only if both attempts fizzle |
| 3.3.6 | Cast while sitting | Script stands first, then casts; re-sits if not in combat |
| 3.3.7 | Splash (free-target) spell with `CanSplashLand = false` | Returns `CAST_NO_RESULT`; prints "Skip X — splash will not land here." |

---

### 3.4 castAA

**Prerequisite:** Have a usable AA ability (e.g. First Strike, Recall, any ready AA).

| # | Action | Expected |
|---|--------|----------|
| 3.4.1 | `castWhat('FirstStrike', 0, 'DPS')` (or any ready AA) | `/alt act <ID>` fires; returns `CAST_SUCCESS` |
| 3.4.2 | AA with cast time (e.g. Adrenaline Rush) | Waits for CastingWindow to open; polls until done |
| 3.4.3 | AA not ready | `castWhat` returns `CAST_RECOVER` (rtc=0, spell not found via other checks) |
| 3.4.4 | Invis guard | Returns `CAST_CANCELLED` |
| 3.4.5 | Banestrike with non-matching race target in combat, dist > 70 | Returns `CAST_NO_RESULT` silently |

---

### 3.5 castDisc

**Prerequisite:** Have a combat discipline available (not on cooldown).

| # | Action | Expected |
|---|--------|----------|
| 3.5.1 | `castWhat('<DiscName>', 0, 'DPS')` — disc ready | `/disc <ID>` fires (live) or `/disc "<name>"` (emu); returns `CAST_SUCCESS` |
| 3.5.2 | Self-targeted duration disc already active | Skipped; returns `CAST_SUCCESS` without casting again |
| 3.5.3 | Non-self target disc | Always attempts cast (no active-disc guard) |
| 3.5.4 | Invis guard | Returns `CAST_CANCELLED` |

---

### 3.6 castItem

**Prerequisite:** Have an item with a clicky effect in inventory.

| # | Action | Expected |
|---|--------|----------|
| 3.6.1 | `castWhat('<ItemName>', 0, 'buffs')` — item with cast time | `/useitem "<ItemName>"` fires; polls CastingWindow; returns `CAST_SUCCESS` when cooldown starts |
| 3.6.2 | Instant-click item (cast time = 0) | `/useitem` fires; 100ms delay; returns `CAST_SUCCESS` |
| 3.6.3 | Prestige item on non-gold account | Returns `CAST_NO_RESULT`; no useitem issued |
| 3.6.4 | Invis + non-heal context | Returns `CAST_CANCELLED` |

---

### 3.7 castMemSpell

**Prerequisite:** A spell in your spell book that is NOT currently memed. An empty gem slot, or a slot you can overwrite.

| # | Action | Expected |
|---|--------|----------|
| 3.7.1 | `Cast.castMemSpell('SpellName', slotNum, 0)` — spell in book, slot empty | Spell appears in gem slot within 15s; SpellBookWnd closed after |
| 3.7.2 | Spell already in correct gem | Returns immediately (guarded by `currentGem == gemNum`) |
| 3.7.3 | Spell not in spell book | Prints "Could Not find the spell X in your spell book."; returns |
| 3.7.4 | Item on cursor when starting | Calls `/autoinventory` first; then proceeds |
| 3.7.5 | Non-empty slot (has another spell) | Right-clicks to clear slot first; then mems |

---

### 3.8 castMem (auto-mem for castWhat rtc=7)

**Prerequisite:** `state.cast.miscGem` configured to a valid gem slot number. Target spell in book, not memed.

| # | Action | Expected |
|---|--------|----------|
| 3.8.1 | `castWhat('<UnmmedSpell>', 0, 'buffs')` — in book, miscGem configured | Spell memed to miscGem; then cast; returns `CAST_SUCCESS` |
| 3.8.2 | Long-recast spell (>30s) with miscGemLW configured | Memed to miscGemLW; waits for ready; casts |
| 3.8.3 | castMem called while casting | Returns `false` immediately |
| 3.8.4 | castMem called while moving (non-bard) | Returns `false` immediately |
| 3.8.5 | castMem in buff context with mob within 200 units | Returns `false`; prints "Cannot mem a spell during combat..." |
| 3.8.6 | Insufficient mana for spell | Returns `false` |

---

### 3.9 castReMem (slot restoration)

**Prerequisite:** `miscGemRemem` configured. A spell has been cast from miscGem (reMemCast=true).

| # | Action | Expected |
|---|--------|----------|
| 3.9.1 | After successful misc-gem cast, call `castReMem(spellName, true, 'buffs')` out of combat | Original spell restored to miscGem slot; `reMemCast = false`; `reMemWaitShort = 'null'` |
| 3.9.2 | `forceReMem = false` | Flags set but no restore happens |
| 3.9.3 | `sentFrom = 'buffs'` with mob within 200 units | Skips restore (aggro guard) |
| 3.9.4 | `rezSick` buff active | Skips restore |

---

### 3.10 castWhat dispatcher routing

For each type, verify the correct sub-function is invoked and returns expected status.

| # | castWhat argument | Expected route | Expected return |
|---|-------------------|---------------|-----------------|
| 3.10.1 | `'command:/say test'` | castCommand | `CAST_SUCCESS` |
| 3.10.2 | Ready item with exact-name prefix `'='` (via rtc=1) | castItem | `CAST_SUCCESS` |
| 3.10.3 | Ready AA name | castAA | `CAST_SUCCESS` |
| 3.10.4 | Ready disc name | castDisc | `CAST_SUCCESS` |
| 3.10.5 | Skill name (e.g. `'Begging'`) | castSkill | `CAST_SUCCESS` |
| 3.10.6 | Memed spell, ready | castSpell | `CAST_SUCCESS` |
| 3.10.7 | Spell in book, not memed, miscGem=0 | rtc=7 → castMem fails → `CAST_NO_RESULT` | `CAST_NO_RESULT` |
| 3.10.8 | Completely unknown name | — | `CAST_NOT_FOUND` |
| 3.10.9 | Spell memed but gem timer not expired | rtc=0 | `CAST_RECOVER` |
| 3.10.10 | Non-self spell with `whatID` different from current target | castTarget called first; then cast | Correct NPC targeted before cast |
| 3.10.11 | Self-targeted spell | No castTarget call | Target unchanged |
| 3.10.12 | Already casting (non-bard, CastingWindow open) | Guard at top | `CAST_CASTING` |
| 3.10.13 | Pull context (`sentFrom` contains `'pull'`) with `aggroTargetID` set | Short-circuit after target acquired | `CAST_SUCCESS` immediately |
| 3.10.14 | Disc rtc=3, endurance < disc cost | Skipped | `CAST_NO_RESULT` |

---

### 3.11 /memmyspells bind

**Prerequisite:** Character INI has `[Spells]` section with `Gem1..GemN` populated.

| # | Action | Expected |
|---|--------|----------|
| 3.11.1 | `/memmyspells` | All configured gems filled; character sits, mems each spell, stands when done |
| 3.11.2 | Spell already in correct gem | Skipped (no re-mem) |
| 3.11.3 | Spell in wrong slot | Unmemed from wrong slot; re-memed in correct slot |
| 3.11.4 | Spell name with ` Rk. II` suffix in INI | Rank suffix stripped; `Spell[base].RankName()` used to resolve correct rank |
| 3.11.5 | Spell not in book | Prints "Could Not find the spell X in your spell book."; continues with rest |
| 3.11.6 | `/memmyspells 2` (alternate spell set) | Reads `[Spells2]` section; falls back to `[Spells]` if not found |
| 3.11.7 | After loop: `miscGem > 0` | `state.cast.reMemMiscSpell` refreshed from live gem |
| 3.11.8 | `/memmyspells` with no `[Spells]` section | Prints "No Spells found in INI..." and aborts |

---

## Section 4 — Combat Core (Milestone 4 — Steps 4.1–4.8)

---

### 4.1 Combat.init — module load and state wiring (Step 4.1)

**Setup:** Valid pickle config exists with `[DPS]`, `[Melee]`, `[Burn]`, `[General]` sections populated.
Start with `/lua run kissassist-lua assist TankName debug`.

| # | Action | Expected |
|---|--------|----------|
| 4.1.1 | Start script, watch chat | Debug line: `Combat.init: dpsOn=... meleeOn=... assistAt=... meleeDistance=... dps#=... burn#=... campRadius=...` |
| 4.1.2 | Verify `dpsOn` from INI | `[DPS] DPSOn=1` → `dpsOn = true`; `DPSOn=0` → `false` |
| 4.1.3 | Verify `meleeOn` from INI | `[Melee] MeleeOn=1` → `meleeOn = true` |
| 4.1.4 | Verify `assistAt` from INI | `[Melee] AssistAt=85` → `assistAt = 85`; absent key → falls back to CLI arg (default 95) |
| 4.1.5 | Verify `meleeDistance` | `[Melee] MeleeDistance=25` → `meleeDistance = 25` |
| 4.1.6 | Verify `campRadius` | `[General] CampRadius=40` → `state.movement.campRadius = 40` |
| 4.1.7 | Verify DPS array populated | `dps#` in debug line matches number of non-empty `DPS1..DPSN` entries in INI |
| 4.1.8 | Verify Burn array populated | `burn#` matches number of non-empty `Burn1..BurnN` entries |
| 4.1.9 | Start with empty/missing DPS section | `dps# = 0`; no crash |
| 4.1.10 | `burnOnNamed` | `[Burn] BurnAllNamed=1` → `state.combat.burnOnNamed = true` |

---

### 4.2 Combat.mobRadar — mob detection (Step 4.2)

**Setup:** Script running. Add a temporary test bind for invocation (or wire Step 4.4 first and observe in combat).

**Add test bind temporarily (remove after testing):**
```lua
-- In binds.lua onDebug or a scratch bind:
mq.bind('/katestmobRadar', function()
    local Combat = require('modules.combat')
    local State  = require('modules.state')
    Combat.mobRadar('los', State.combat.meleeDistance)
    printf('mobCount=%d aggro=%s', State.combat.mobCount, State.combat.aggroTargetID)
end)
```

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.2.1 | No mobs in range | Open area with no NPCs | `mobCount = 0`; `aggroTargetID = ''` |
| 4.2.2 | Aggressive NPC in XTarget | Stand near an aggressive NPC that has auto-aggroed (slot shows "Auto Hater") | `mobCount ≥ 1`; `aggroTargetID = <NPC spawn ID>` |
| 4.2.3 | NPC corpse only | Kill a mob; only corpse remains on XTarget | `mobCount = 0` (corpse filtered out) |
| 4.2.4 | NPC beyond `meleeDistance` | Target a hater-type NPC outside configured distance | Not counted; `mobCount = 0` |
| 4.2.5 | NPC within distance | Same NPC, move within `meleeDistance` | `mobCount = 1` |
| 4.2.6 | Multiple haters | Multiple NPCs all on XTarget "Auto Hater" slots within range | `mobCount` equals the count of in-range living haters |
| 4.2.7 | `aggroTargetID` is closest | Two haters at different distances | `aggroTargetID` resolves to the closer one's ID |
| 4.2.8 | DMZ zone guard | Start in a DMZ zone (e.g. Plane of Knowledge, ID 344) outside an instance | `mobRadar` returns without scanning; `mobCount` unchanged from prior value |
| 4.2.9 | LOSBeforeCombat off (default) | NPC behind a wall, `LOSBeforeCombat=0` | NPC counted regardless of LOS |
| 4.2.10 | LOSBeforeCombat on | `[General] LOSBeforeCombat=1`; NPC behind a wall | NPC NOT counted; `mobCount = 0` for that NPC |
| 4.2.11 | XTSlot fallback — count=0 | `xTSlot` set to a slot holding a living non-auto-hater NPC; no haters elsewhere | `mobCount = 1`; `aggroTargetID` set to that NPC's ID |
| 4.2.12 | Debug output | Run with `debug` flag | Prints `mobRadar(los,N): mobCount=X aggro=Y` |

---

### 4.3 Combat.assist / Combat.getCombatTarget / Combat.combatTargetCheck (Step 4.3)

**Setup:** Script running with a real group. One character set as MA (`assist TankName`). Have at least one aggressive NPC in range.

**Shared test bind (remove after testing):**
```lua
mq.bind('/katestassist', function()
    local Combat = require('modules.combat')
    local State  = require('modules.state')
    Combat.assist('test')
    printf('myTargetID=%d myTargetName=%s', State.combat.myTargetID, State.combat.myTargetName)
end)
```

#### 4.3.1 — Combat.assist (non-MA path)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.3.1.1 | Normal assist — group MA set | MA has an NPC targeted; group `MainAssist` assigned in-game | `myTargetID` = MA's target ID; `myTargetName` set |
| 4.3.1.2 | GroupAssistTarget shortcut | `Group.MainAssist.ID == maSpawn.ID` | Uses `Me.GroupAssistTarget.ID` directly (no `/assist` command) |
| 4.3.1.3 | Fallback `/assist` when no group MA | No group `MainAssist` assigned | Sends `/assist TankName`; waits for `AssistComplete` |
| 4.3.1.4 | MA out of range | MA farther than 200 units | Skips assist; `myTargetID` unchanged |
| 4.3.1.5 | Offtank — MA dead/far | Role = `offtank`; MA gone | Returns immediately; no target set |
| 4.3.1.6 | Aggro fallback when MA gone | `aggroTargetID` set; MA absent | Targets `aggroTargetID` if within `meleeDistance` |
| 4.3.1.7 | DPS paused guard | `state.dps.paused = true` | Returns immediately; no target change |
| 4.3.1.8 | Hovering guard | Character is dead/hovering | Returns immediately |
| 4.3.1.9 | Invalid target (bad type) | MA targets a corpse or aura | `validateTarget` returns false; `myTargetID = 0` |
| 4.3.1.10 | Valid target → state set | MA targets a live NPC | `myTargetID`, `myTargetName`, `lastTargetID` all updated |
| 4.3.1.11 | Debug output | Run with `debug` flag | Prints `assist: myTarget=<name> id=<n>` |

#### 4.3.2 — Combat.getCombatTarget (MA path)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.3.2.1 | Single hater on XTarget | One NPC on auto-hater slot | Targets that NPC directly via `aggroTargetID` |
| 4.3.2.2 | Named mob priority | Multiple haters including a named NPC | Named NPC targeted first |
| 4.3.2.3 | Alert-4 (mez-immune) priority | Alert 4 has a non-corpse hater; no named | Alert-4 NPC targeted before others |
| 4.3.2.4 | Multi-mob closest selection | 3+ haters, no named/alert-4 | Closest hater targeted |
| 4.3.2.5 | Most-hurt upgrade | Most-hurt NPC in camp range | `mostHurtID` used if within `meleeDistance` of camp |
| 4.3.2.6 | ReturnToCamp distance gate | Most-hurt NPC outside camp radius | Falls back to closest; out-of-range mob not targeted |
| 4.3.2.7 | Stale `aggroTargetID2` cleared | `aggroTargetID2` points to a corpse | Cleared to `'0'` before processing |
| 4.3.2.8 | Non-MA character | Role = `assist`, not MA | Returns immediately; no target selection |
| 4.3.2.9 | MezMobFlag blurred scan | `aggroID = 0`, `mobCount > 0`, `mez.mobFlag = true` | Scans for nearby unalerted NPC; targets if in camp range |
| 4.3.2.10 | Mezzed mob detected | Blurred scan finds a mezzed NPC | Sets `aggroTargetID2`, `myTargetID`; returns early |
| 4.3.2.11 | `validateTarget` rejection | Best-selected NPC fails validation | `myTargetID = 0`; no target locked |
| 4.3.2.12 | Debug output | Run with `debug` flag | Prints `getCombatTarget: myTarget=<name> id=<n>` |

#### 4.3.3 — Combat.combatTargetCheck

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.3.3.1 | Dead target cleared | `myTargetID` points to a corpse | `myTargetID = 0`; `lastTargetID` updated; returns |
| 4.3.3.2 | Non-MA syncs to group assist | Group MA set; MA switches targets | `myTargetID` updated to new `GroupAssistTarget.ID` |
| 4.3.3.3 | MA re-locks own target | MA's game target drifts; `targetSwitchingOn = false` | `/target id myTargetID` re-issued |
| 4.3.3.4 | MA accepts new target (switching on) | `targetSwitchingOn = true`; MA manually targets new NPC | `myTargetID` updated; tank-announce echoed |
| 4.3.3.5 | MA ignores PC target (switching on) | MA accidentally targets a PC | `myTargetID` unchanged; PC skipped |
| 4.3.3.6 | CalledTargetID accepted (no group MA) | No group MA; event sets `calledTargetID = N` | `myTargetID = N`; `calledTargetID = 0` |
| 4.3.3.7 | DPS paused — SetTarget 0 | `dps.paused = true`, `setTarget = 0` | Returns immediately |
| 4.3.3.8 | DPS paused — SetTarget 2 bypass | `dps.paused = true`, `setTarget = 2` | Proceeds normally |
| 4.3.3.9 | XTarAutoSet re-targets | `xTarAutoSet = true`; `myTargetID` changed; not MA | `/target id N` issued; `/xtarget set` called |
| 4.3.3.10 | Debug output | Run with `debug` flag | Prints `combatTargetCheck: myTarget=... id=... lastID=...` |

### 4.4 Combat.checkForCombat / Combat.combatReset / Combat.checkForAdds / Combat.feignAggroCheck (Step 4.4)

**Setup:** Script running with `dpsOn = true` or `meleeOn = true`. Character in a zone with valid mobs.

#### 4.4.1 — Combat.checkForCombat entry guards

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.4.1.1 | ChaseAssist + moving guard | `chaseAssist = true`; character moving; not MA | Returns immediately; no radar/assist called |
| 4.4.1.2 | DMZ guard | Zone is a DMZ; not in instance | Returns immediately after mobRadar |
| 4.4.1.3 | Hovering guard | `Me.Hovering() = true` | Returns immediately |
| 4.4.1.4 | Dead + no aggro guard | `iAmDead = true`; `aggroTargetID = 0` | Returns immediately |
| 4.4.1.5 | No mobs + no aggro guard | `mobCount = 0`; `aggroTargetID = 0` | Returns immediately |
| 4.4.1.6 | DPS + melee both off | `dpsOn = false`; `meleeOn = false` | Returns immediately |
| 4.4.1.7 | iAmDead clears when rezzed | `iAmDead = true`; rez sickness buff present | `iAmDead` cleared to `false` |
| 4.4.1.8 | Main loop wiring | Script running with `dpsOn = true` and mob present | `checkForCombat` called each main loop tick |

#### 4.4.2 — Non-MA assist path

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.4.2.1 | Assist loop acquires target | Non-MA; mob in range; MA has target | `Combat.assist` called; `myTargetID` set |
| 4.4.2.2 | EngageWaitTimer=0 exits loop immediately | `waitTime = 0`; no target set after assist | Loop exits without spinning |
| 4.4.2.3 | Loop exits when myTargetID set | `myTargetID` locked after first assist call | Inner loop breaks without re-calling assist |
| 4.4.2.4 | Offtank with dead MA — deferred | Role = `offtank`; MA gone | Breaks out of assist loop (switchMA deferred) |

#### 4.4.3 — MA path (getCombatTarget + engage wait)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.4.3.1 | MA waits for mob in radius | MA role; mob approaching camp; `aggroTargetID` set | Loops until `mobCount > 0`, then calls `getCombatTarget` |
| 4.4.3.2 | EngageWaitTimer expires | `waitTime = 0`; mob never enters radius | Loop exits immediately; `getCombatTarget` still called |
| 4.4.3.3 | Puller-role MA skips wait | Role = `pullertank`; `aggroTargetID` set | Skips wait loop; calls `getCombatTarget` directly |
| 4.4.3.4 | Mob corpse during wait | Mob dies while MA waiting | Wait loop breaks; `getCombatTarget` still called |

#### 4.4.4 — Post-combat guards

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.4.4.1 | FeignAggroCheck called | `Me.Feigning() = true` after assist path | `feignAggroCheck` called; waits out aggroOff timer |
| 4.4.4.2 | ChainPull==2 exits | `pull.chainPull = 2` | Returns immediately after combat block |
| 4.4.4.3 | Non-manual target dead → CombatReset | `role = 'assist'`; `myTargetID` points to corpse | `combatReset(0, ...)` called; target fields cleared |

#### 4.4.5 — Combat.combatReset

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.4.5.1 | Core field reset | Call `combatReset(0, 'test')` | `myTargetID=0`, `combatStart=false`, `attacking=false`, `validTarget=false` |
| 4.4.5.2 | Attack off issued | Call `combatReset(0, 'test')` | `/attack off` command sent |
| 4.4.5.3 | Target cleared | Call `combatReset(0, 'test')` | `/target clear` command sent |
| 4.4.5.4 | Burn state cleared for dead burn target | `burnID = N`; mob N is a corpse | `burnCalled=false`, `burnID=0`; echo printed |
| 4.4.5.5 | TargetSwitchingOn reset for non-MA | Non-MA; `targetSwitchingOn=true` | Reset to `false` |
| 4.4.5.6 | Tank timer set | Call `combatReset` | `timers.tank` set to `os.clock() + 30` |
| 4.4.5.7 | AggroOff wait | `timers.aggroOff` active | Waits up to 2s; continues when timer expires |
| 4.4.5.8 | Event drain | Pending events in queue | `doevents` loop runs until `eventFlag` is false |
| 4.4.5.9 | Debug output | Run with `debug` flag | Prints `combatReset: enter ...` and `done ...` |

#### 4.4.6 — Combat.checkForAdds

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.4.6.1 | mobCount ≤ 1 guard | `mobCount = 1` | Returns immediately |
| 4.4.6.2 | Dead guard | `iAmDead = true`; `mobCount = 3` | Returns immediately |
| 4.4.6.3 | DPS paused guard | `dps.paused = true`; `mobCount = 3` | Returns immediately |
| 4.4.6.4 | Re-acquire valid living target | `myTargetID` set; target not acquired; within campRadius | `/target id N` sent; returns |
| 4.4.6.5 | Add spam popup | `aggroID` set; `myTargetID = 0`; add within campRadius; spam timer expired | `/popup Add(s) in camp detected` shown |
| 4.4.6.6 | Add spam throttle | Add spam popup just fired (5s ago) | Popup suppressed until `timers.addSpam` expires |
| 4.4.6.7 | Tank role targets aggro | Role = `tank`; no current target; `aggroTargetID` set | `/target id aggroID` sent |
| 4.4.6.8 | Stale myTargetID cleaned | `myTargetID` points to a corpse; target not NPC | `lastTargetID` updated; `myTargetID=0`; `/target clear` sent |
| 4.4.6.9 | Debug output | Run with `debug` flag | Prints `checkForAdds: mobCount=N from=...` |

#### 4.4.7 — Combat.feignAggroCheck

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.4.7.1 | AggroOff timer active — waits | `timers.aggroOff` set to future; `Me.Feigning() = true` | Loops calling `doevents` + delay until feign drops or timer expires |
| 4.4.7.2 | AggroOff timer expired — single doevents | `timers.aggroOff = 0` | Calls `doevents` once and returns |
| 4.4.7.3 | Not feigning — exits immediately | `timers.aggroOff` active; `Me.Feigning() = false` | While loop exits immediately |

---

### 4.5 Combat.fight — melee engagement loop (Step 4.5)

**Setup:** Script running in an area with attackable NPCs. MA designated. `meleeOn=1`, `dpsOn=1` in INI. Stand near an NPC that the MA will target.

#### 4.5.1 Entry guards

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.1 | `myTargetID == 0` when fight() is entered | Returns immediately; no attack |
| 4.5.2 | NPC out of LOS (non-hunter role) | Returns; no `CombatStart` |
| 4.5.3 | Hunter role, NPC out of LOS | Does NOT return on LOS check; continues to engage |
| 4.5.4 | `dps.paused == true` | Returns immediately |
| 4.5.5 | Target is mezzed, non-MA, HP ≤ assistAt | Waits 500ms and returns; does not attack |
| 4.5.6 | Puller role, `pulling == true`, outside campRadius | Returns; does not engage |

#### 4.5.2 CombatRadius calculation

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.7 | `MaxRangeTo` ≤ `meleeDistance` | `combatRadius = meleeDistance` |
| 4.5.8 | `MaxRangeTo` > `meleeDistance` (e.g. ranged mob) | `combatRadius = MaxRangeTo + 5` |

#### 4.5.3 CombatStart and ATTACKING announce

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.9 | First time fight() engages target | `combatStart = true`; chat shows `ATTACKING -> <name> <-` |
| 4.5.10 | Tank/hunter role | Also echoes `[KA] TANKING-> <name> <- ID:<id>` |
| 4.5.11 | PetTank role | Echoes `[KA] <PetName> is TANKING-> <name> <- ID:<id>` |
| 4.5.12 | CombatStart already true | Announce not repeated on subsequent calls |

#### 4.5.4 Melee initiation

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.13 | `meleeOn=true`, character sitting | `/stand` issued before attack |
| 4.5.14 | Tank/hunter with Taunt skill ready | `/doability Taunt` issued on first engage |
| 4.5.15 | Not yet in combat, `beforeArray[1] ~= 'null'` | `beforeAttack(myID, 1)` fires configured pre-combat abilities |
| 4.5.16 | `attacking = true` already | No repeated `/attack on` or `beforeAttack` on re-entry |
| 4.5.17 | `meleeOn=false`, pet configured, mob in pet range | Pet sent to attack; `attacking = true` set via pet path |

#### 4.5.5 beforeAttack helper

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.18 | Entry is a ready item (exact name) | `/useitem` issued; echoes `## Before Attack >> <name> <<` |
| 4.5.19 | Entry is a ready AA | `/alt act <id>` issued |
| 4.5.20 | Entry is a ready disc with sufficient endurance | `/disc "<name>"` issued |
| 4.5.21 | Entry is a ready activated skill | `/doability "<name>"` issued |
| 4.5.22 | Target clears mid-loop | Returns immediately without processing remaining entries |
| 4.5.23 | `condCheck=2`, entry has no `\|cond` | Entry skipped |
| 4.5.24 | `condCheck=2`, entry has `\|cond` | Entry processed normally |

#### 4.5.6 combatPet helper

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.25 | No pet summoned | Returns immediately |
| 4.5.26 | Pet already in combat | Returns; no `/pet attack` |
| 4.5.27 | Mob distance < `petAttackRange`, not mezzed | `/pet attack` + `/pet swarm` issued; `timers.petAttack` set +3s |
| 4.5.28 | Mob distance ≥ `petAttackRange` | `/pet follow` if not already following |
| 4.5.29 | PetTank + ReturnToCamp: me in camp, mob in range | `/pet attack` + `/pet swarm` |
| 4.5.30 | PetTank + ReturnToCamp: pet outside campRadius | `/pet follow` issued |
| 4.5.31 | Target mezzed | Returns without sending pet |

#### 4.5.7 Inner combat loop

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.32 | Target becomes corpse mid-loop | `combatReset(0, ...)` called; loop breaks; `attacking = false`; `/attack off` |
| 4.5.33 | `dps.paused` becomes true mid-loop | Treated as dead target: `combatReset + break` |
| 4.5.34 | `combatTargetCheck(1)` changes `myTargetID` | Next iteration uses updated ID |
| 4.5.35 | Target in range, `attacking=true`, standing | `/attack on` re-issued each iteration if standing/mounted |
| 4.5.36 | `targetSwitchingOn=false`, current target drifts from myTargetID | `/target id <myTargetID>` re-issued |
| 4.5.37 | MA: current target dead, TargetSwitchingOn=true, new target found | `combatTargetCheck(1)` acquires next target; loop continues |
| 4.5.38 | MA: TargetSwitchingOn=true, no next target | `lastTargetID` restored; `combatReset + break` |
| 4.5.39 | Non-MA: target dead, TargetSwitchingOn=false | `combatReset(0, '_targetGone') + break` |
| 4.5.40 | Character feigning after iteration | `feignAggroCheck()` called; if still feigning, loop breaks |
| 4.5.41 | Tank/pullertank role enters combat | `mez.mobFlag = true` set |

#### 4.5.8 Out-of-HP-range else-if block

| # | Scenario | Expected |
|---|----------|----------|
| 4.5.42 | Mob in range, HP > assistAt (approaching) | `combatTargetCheck(1)` called; `beforeAttack(myID, 2)` fires `\|cond` entries |
| 4.5.43 | `petCombatOn=true`, mob in petAttackRange, HP ≤ petAssistAt | `combatPet()` called in this block |

---

### 4.6 Cast.combatCast — DPS rotation (Step 4.6)

**Setup:** Script running. MA designated. `dpsOn=1` in INI. `[DPS]` section has at least two entries (one spell, one AA). Stand near an attackable NPC. `meleeOn=1`.

#### 4.6.1 Basic DPS rotation

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.1 | `dpsOn=true`, script enters combat | `Cast.combatCast()` called from fight() inner loop; DPS spells/AAs fire in order |
| 4.6.2 | Ready memed spell in DPS array at HP < threshold | `castWhat` called; spell casts; echoes `** SpellName on >> <target> <<` |
| 4.6.3 | Ready AA in DPS array | `/alt act <ID>` fires via castAA path |
| 4.6.4 | Ready disc in DPS array | `/disc <ID>` fires via castDisc path |
| 4.6.5 | Entry with no HP threshold (malformed: `SpellName||Mob`) | Loop breaks on that entry; entries after it not attempted |
| 4.6.6 | DPS array empty or all entries at index > debuffCount | `mashButtons` called immediately; returns without error |

#### 4.6.2 Target validation and corpse guard

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.7 | Target becomes corpse between DPS entries | `combatCast` returns immediately on next iteration |
| 4.6.8 | `dps.paused = true` mid-rotation | Returns immediately; no further casts |
| 4.6.9 | `myTargetID = 0` on entry | Returns immediately |

#### 4.6.3 HP% gate

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.10 | `dpsOn=true`, target HP 98%, entry threshold 95% | Entry skipped (HP > dpsAt) |
| 4.6.11 | Target HP 90%, entry threshold 95% | Entry cast |
| 4.6.12 | `iAmMA=true`, entry threshold 80%, global assistAt 95% | Uses assistAt 95% (MA ignores per-entry threshold) |

#### 4.6.4 Target type resolution

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.13 | Entry has `Me` target type | `castTargetID = Me.ID`; castWhat targets self |
| 4.6.14 | Entry has `MA` target type, non-pettank role | `castTargetID = Spawn[=MainAssist].ID` |
| 4.6.15 | Entry has `MA` target type, pettank role | `castTargetID = Me.Pet.ID` |
| 4.6.16 | Entry has `Group2` target type | `castTargetID = Group.Member(2).ID` |
| 4.6.17 | `Me` target type, buff already on me | Entry skipped; no re-cast |

#### 4.6.5 DPS stacking guard (castDPSSpellCheck)

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.18 | DoT spell already on target, cast by me | Entry skipped via `castDPSSpellCheck` |
| 4.6.19 | Same DoT on target but cast by another player | NOT skipped (different caster) |
| 4.6.20 | DoT not on target | Cast proceeds normally |
| 4.6.21 | Spell uses SPA-470 (proc DoT trigger), trigger already on target by me | Entry skipped |

#### 4.6.6 Weave/Mash/Ambush skips

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.22 | Entry string contains `\|weave` | Skipped in DPS loop (goto next_dps) |
| 4.6.23 | Entry string contains `\|mash` | Skipped in DPS loop |
| 4.6.24 | Entry string contains `\|ambush` | Skipped in DPS loop |

#### 4.6.7 Attack-off for self/MA casts

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.25 | `Me` targeted spell, non-MA caster, in combat | `/attack off` before cast; restored after |
| 4.6.26 | MA-targeted spell, MA caster | No attack-off (iAmMA guard) |

#### 4.6.8 MashButtons

| # | Scenario | Expected |
|---|----------|----------|
| 4.6.27 | `mashArray[1]` = ready AA name | `/alt act <ID>` fired; echoes `## Mashing >> <name> <<` if went on cooldown |
| 4.6.28 | `mashArray[1]` = ready item name | `/useitem "<name>"` fired |
| 4.6.29 | `mashArray[1]` = ready disc (sufficient endurance) | `/disc <ID>` fired (live) or `/disc "<name>"` (emu) |
| 4.6.30 | `mashArray[1]` = `'null'` | Returns immediately without firing anything |
| 4.6.31 | Target becomes corpse during mash loop | Returns immediately |
| 4.6.32 | `dpsOn=false` | `mashButtons` returns immediately; no mash fires |
| 4.6.33 | Character sitting | `mashButtons` returns (not STAND/MOUNT state) |

---

### 4.7 Cast.doBurn — Burn sequence (Step 4.7)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 4.7.1 | Basic burn fires | `burnOn=true`, `burnArray` has one valid spell, `burnID` set by `/kaburn` | `Cast.castWhat` called with spell; `burnActive` set to `true` |
| 4.7.2 | `burnOn=false` guard | `burnOn=false` | Returns immediately; prints "Burn is turned Off." |
| 4.7.3 | Hovering guard | `Me.Hovering()=true` | Returns immediately without iterating array |
| 4.7.4 | Wrong zone guard | `campZone` set to a different zone ID | Returns immediately |
| 4.7.5 | Announce on first activation | `burnActive=false` before call | `/echo BURN ACTIVATED => Autobots Transform <=` sent once |
| 4.7.6 | No announce on repeat call | `burnActive=true` before call | No activation echo |
| 4.7.7 | Tribute activation | `useTribute=true`, `Me.TributeActive()=false` | `/tribute personal on` + `/trophy personal on` sent; `timers.tribute` set to `now + 570` |
| 4.7.8 | Tribute already active | `useTribute=true`, `Me.TributeActive()=true` | No tribute commands sent |
| 4.7.9 | `null` entry skipped | `burnArray = {'null\|Mob'}` | Entry skipped; no castWhat call |
| 4.7.10 | `Mob` target resolves to myTargetID | Entry `SpellName\|Mob` | `burnTargetID = state.combat.myTargetID` |
| 4.7.11 | `Me` target resolves to self | Entry `SpellName\|Me` | `burnTargetID = Me.ID()` |
| 4.7.12 | `MA` target resolves to main assist | Entry `SpellName\|MA` | `burnTargetID = Spawn['=MainAssist'].ID()` |
| 4.7.13 | `Pet` target resolves to pet | Entry `SpellName\|Pet` | `burnTargetID = Me.Pet.ID()` |
| 4.7.14 | Unknown target defaults to myTargetID | Entry `SpellName\|group1` | `burnTargetID = myTargetID` |
| 4.7.15 | CAST_SUCCESS echoes + waits (non-bard) | Spell returns `CAST_SUCCESS`; CastingWindow open briefly | `Casting >> BURN1:SpellName` printed; waits for CastingWindow to close |
| 4.7.16 | Bard skips cast-wait | `iAmABard=true`; spell returns `CAST_SUCCESS` | No cast-window wait loop |
| 4.7.17 | Hovering mid-loop aborts | Second entry; `Me.Hovering()=true` during loop | Loop breaks; no further entries cast |
| 4.7.18 | NamedWatch — named target triggers burn | `burnOnNamed=true`; `namedCheck=false`; target `Named()=true`; within `meleeDistance` | `/echo *** Mob:(Name) is a NAMED!`; `doBurn()` called; `namedCheck=true` |
| 4.7.19 | NamedWatch — non-named target not triggered | `burnOnNamed=true`; target `Named()=false`; empty `namedWatchList` | No burn triggered; `namedCheck` stays false |
| 4.7.20 | NamedWatch — watchlist match triggers burn | `burnOnNamed=true`; target in `namedWatchList` by name+ID | `doBurn()` called; `namedCheck=true` |
| 4.7.21 | NamedWatch — out of range, no trigger | `burnOnNamed=true`; target distance > `meleeDistance` | No burn triggered even if Named |
| 4.7.22 | NamedWatch — already checked, no re-trigger | `namedCheck=true` | NamedWatch block skipped entirely |
| 4.7.23 | `/kaburn` sets burnID | Call `onBurn()` bind handler with no arg while in combat | `state.combat.burnID = myTargetID`; fight loop dispatches `doBurn()` next tick |
| 4.7.24 | burnActive cleared on combatReset | Kill mob; `combatReset` called | `burnActive=false` reset for next fight |

### 4.8 DoDebuffStuff + AggroCheck (Step 4.8)

**Setup:** Script running in combat. Character has `[DPS]` entries with hp threshold ≥ 101 (debuff slots), `[Aggro]` section populated.

#### 4.8.1 — Combat.aggroCheck

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| 4.8.1.1 | No myTargetID — returns early | `myTargetID=0` | Returns immediately; no castWhat call |
| 4.8.1.2 | Target is corpse — returns early | Target type is `corpse` | Returns immediately |
| 4.8.1.3 | `<` gain-aggro — fires when below threshold | Entry `Taunt\|110\|<\|Mob`; `Me.PctAggro=80` | `castWhat('Taunt', myTargetID, 'Aggro')` called |
| 4.8.1.4 | `<` gain-aggro — skips when above threshold | Same entry; `Me.PctAggro=115` | Skipped; no cast |
| 4.8.1.5 | `>` lose-aggro — fires when above threshold | Entry `Jolt\|80\|>\|Mob`; `Me.PctAggro=95` | `castWhat('Jolt', myTargetID, 'Aggro')` called |
| 4.8.1.6 | `>` lose-aggro — skips when below threshold | Same entry; `Me.PctAggro=60` | Skipped |
| 4.8.1.7 | `<<` secondary — fires when secondary holder above threshold | Entry `Spell\|120\|<<\|Mob`; `SecondaryPctAggro=25` | Fires (adjPct=20, secPct=25 ≥ 20) |
| 4.8.1.8 | `Me` target resolves to self | Entry with `\|Me` | `castTargetID = Me.ID()` |
| 4.8.1.9 | `MA` target resolves to mainAssist | Entry with `\|MA` | `castTargetID = Spawn['=MainAssist'].ID()` |
| 4.8.1.10 | `Pet` target resolves to pet | Entry with `\|Pet` | `castTargetID = Me.Pet.ID()` |
| 4.8.1.11 | Cast SUCCESS → echoes and breaks | castWhat returns `CAST_SUCCESS` | Prints `Casting >> SpellName << to control AGGRO(<) on MobName`; loop stops |
| 4.8.1.12 | `aggroOn=false` — skipped entirely | `aggroOn=false` in `state.combat` | aggroCheck block never entered in fight() |
| 4.8.1.13 | aggroOff timer set on FD lose-aggro cast | `glt='>'`; `Me.Feigning()=true`; cast succeeds | `timers.aggroOff` set to `now + 20` |

#### 4.8.2 — Cast.doDebuffStuff guards

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| 4.8.2.1 | `debuffAllOn=0` — skip | `state.combat.debuffAllOn=0` | Returns immediately |
| 4.8.2.2 | `debuffCount=0` — skip | `state.mez.debuffCount=0` | Returns immediately |
| 4.8.2.3 | DPSPaused — skip | `state.dps.paused=true` | Returns immediately |
| 4.8.2.4 | RespawnWnd open — skip | RespawnWnd open | Returns immediately |
| 4.8.2.5 | Bard+MA+activeTarget — skip | `iAmABard=true`, `iAmMA=true`, `myTargetID≠0`, `aggroTargetID≠''` | Returns immediately |

#### 4.8.3 — debuffCast behavior

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| 4.8.3.1 | Debuff already on mob (dboList hit) | `dboTimer[1]` not expired; mob ID in `dboList[1]` | Slot skipped; no cast |
| 4.8.3.2 | Timer expired → re-debuffs | `dboTimer[1]` expired | Proceeds to cast check |
| 4.8.3.3 | Mob out of spell range — skip | Mob distance > spell range | Slot skipped |
| 4.8.3.4 | Spell not ready, fwait=false — skip | Spell on cooldown; `fwait=false` | Skipped immediately |
| 4.8.3.5 | Spell not ready, fwait=true — waits | Spell on short cooldown (< 2s); `fwait=true` | Waits up to 2s for ready, then casts |
| 4.8.3.6 | SUCCESS updates dboList + dboTimer | Cast succeeds | Mob ID appended to `dboList[i]`; `dboTimer[i]` set to `now + duration` |
| 4.8.3.7 | SUCCESS echoes | Cast succeeds | Prints `** Debuff SpellName on MobName` |

#### 4.8.4 — DoDebuffStuff multi-mob behavior

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| 4.8.4.1 | Primary mob debuffed | `firstMobID` is valid NPC | `debuffCast(firstMobID, true)` called |
| 4.8.4.2 | XTarget add debuffed | Extra auto-hater in XTarget, in range, LOS | `debuffCast(xtID, false)` called |
| 4.8.4.3 | XTarget same as firstMobID — skip | `xt.ID() == firstMobID` | Skipped (already handled as primary) |
| 4.8.4.4 | XTarget out of range — skip | Mob distance ≥ `meleeDistance` | Skipped |
| 4.8.4.5 | XTarget no LOS — skip | `xsp.LineOfSight()=false` | Skipped |
| 4.8.4.6 | PC target — skip | XTarget is player character | Skipped |
| 4.8.4.7 | Stale dboList cleaned | Dead mob ID in `dboList[1]` | ID removed from list on next DoDebuffStuff call |
| 4.8.4.8 | Target restored after multi-mob | Debuffed secondary mob (target drifted) | Target restored to `myTargetID` after loop |

#### 4.8.5 — debuffCount computation in Combat.init

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| 4.8.5.1 | DPS entries with thresh ≥ 101 counted | `dpsArray[1]` has thresh 110; `dpsArray[2]` has thresh 50 | `state.mez.debuffCount=1` |
| 4.8.5.2 | No debuff entries | All DPS entries have thresh ≤ 100 | `state.mez.debuffCount=0`; `combatCast` starts at index 1 |
| 4.8.5.3 | All debuff entries | All DPS entries have thresh ≥ 101 | `debuffCount = #dpsArray`; `combatCast` DPS loop empty |

---

## Section 5 — Healing & Recovery (Milestone 5)

---

### 5.1 Heal.init — module load and state wiring (Step 5.1)

**Setup:** Valid pickle config with `[Heals]`, `[Cures]`, and `[General]` sections populated. Start with `/lua run kissassist-lua assist TankName debug`.

#### 5.1.1 — Config loading

| # | Action | Expected |
|---|--------|----------|
| 5.1.1 | Start script with `[Heals] HealsOn=1` | `state.heal.healsOn = 1`; `state.session.heals = true` |
| 5.1.2 | `[Heals] HealsOn=0` (default) | `state.heal.healsOn = 0`; `state.session.heals = false` |
| 5.1.3 | `[Heals] Heals1=Devout Light Rk. II\|50` through `Heals3=...` | `state.heal.healsArray` has 3 entries; `healsArray[1] = 'Devout Light Rk. II\|50'` |
| 5.1.4 | `[Heals]` section absent or empty | `state.heal.healsArray = {}`; no crash |
| 5.1.5 | `[Cures] CuresOn=1` | `state.heal.curesOn = true` |
| 5.1.6 | `[Cures] Cures1=Expurgation Rk. II\|poison` through `Cures3=...` | `state.heal.curesArray` has 3 entries |
| 5.1.7 | `[General] MedOn=1` (default) | `state.heal.medOn = true` |
| 5.1.8 | `[General] MedOn=0` | `state.heal.medOn = false` |
| 5.1.9 | `[General] MedStart=30`, `MedStop=95` | `state.heal.medStart = 30`; `state.heal.medStop = 95` |
| 5.1.10 | `[General] MedStart` absent | `state.heal.medStart = 20` (mac default) |
| 5.1.11 | `[General] GroupWatchOn=1\|25` (pipe format) | `state.heal.groupWatchOn = true`; `state.heal.groupWatchPct = 25` |
| 5.1.12 | `[General] GroupWatchOn=0` (plain) | `state.heal.groupWatchOn = false`; `groupWatchPct` unchanged (default 20) |
| 5.1.13 | `[Heals] AutoRezOn=1` | `state.heal.autoRezOn = true` |
| 5.1.14 | `[Heals] XTarHeal=1` | `state.heal.xTarHeal = true` |
| 5.1.15 | `[Heals] RezMeLast=1` | `state.heal.rezMeLast = true` |
| 5.1.16 | `[Heals] HealGroupPetsOn=1` | `state.heal.healGroupPetsOn = true` |
| 5.1.17 | `[General] CorpseRecoveryOn=1` | `state.heal.corpsRecoveryOn = true` |
| 5.1.18 | `[General] MedCombat=1` | `state.heal.medCombat = true` |

#### 5.1.2 — Debug output

| # | Action | Expected |
|---|--------|----------|
| 5.1.19 | Start with `debug` flag | Chat shows `[heals] Heal.init done — healsOn=1(N spells) curesOn=true(N) medOn=true medStart=20 medStop=100 sHP=<n> sHPma=<n> sHPrange=<n>` (values from INI) |
| 5.1.20 | No INI / defaults only | No crash; all `state.heal` fields have their default values |

---

### 5.2 /addimmune bind (Step 5.1)

**Setup:** Script running. Various targets available.

| # | Action | Expected |
|---|--------|----------|
| 5.2.1 | `/addimmune` with NPC targeted | `state.mez.immuneIDs` gains `\|<ID>`; prints `>> Mez Immune -> <name> <- ID:<id> Added to immune list.`; INI updated |
| 5.2.2 | `/addimmune` with no target | Prints `--AddMezImmune: Target an NPC to add to the mez immune list.`; no state change |
| 5.2.3 | `/addimmune` targeting a PC | Prints same error message; no state change |
| 5.2.4 | `/addimmune` same NPC twice | Second call prints `>> <name> (ID:<id>) is already on the mez immune list.`; no duplicate in `immuneIDs` |
| 5.2.5 | `/addimmune` with named mob (`CleanName` starts with `#`) | `#` stripped; `immuneIDs` has ID; INI has name without `#` |
| 5.2.6 | `/addimmune` targeting a corpse (`CleanName` ends with `'s corpse'`) | Corpse suffix stripped; base name stored |
| 5.2.7 | INI write path — valid `infoFileName` and `zoneName` | `Ini[infoFileName][zoneName][MezImmune]` contains the mob name after call |
| 5.2.8 | INI write path — second mob added | Existing entry appended with comma separator; no overwrite of first name |

---

### 5.3 Heal.checkHealth — self-triage + single-heal dispatch (Step 5.2)

**Setup:** Script running with `[Heals] HealsOn=1` and at least one entry in healsArray. Use `/debug heals on` to observe dispatch.

#### 5.3.1 — Guard conditions

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.3.1 | `healsOn=0` — no healing | `state.heal.healsOn = 0` | `checkHealth` returns immediately; no cast attempted |
| 5.3.2 | Invis without aggro — no healing | `Me.Invis()=true`, `aggroTargetID=''` | Returns immediately |
| 5.3.3 | Invis with aggro — heals fire | `Me.Invis()=true`, `aggroTargetID='<id>'` | Heals proceed normally |
| 5.3.4 | Medding without `medCombat` — no healing | `state.heal.medding=true`, `medCombat=false` | Returns immediately |
| 5.3.5 | Medding with `medCombat=true` — heals fire | `state.heal.medding=true`, `medCombat=true` | Heals proceed normally |

#### 5.3.2 — Self-heal path

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.3.6 | Self HP below `singleHealPoint` | `Me.PctHPs()=40`, `singleHealPoint=80` | `singleHeal` called; spell from healsArray with threshold ≥ 40 cast on self |
| 5.3.7 | Self HP above threshold — no self-heal | `Me.PctHPs()=90`, `singleHealPoint=80` | No self-cast |
| 5.3.8 | `healsOn=4` (self-only) — returns after self check | `healsOn=4`, `Me.PctHPs()=50` | Self healed; group/MA checks skipped |
| 5.3.9 | Non-healer class — stops after self | `Me.Class.ShortName()='WAR'` | Self-heal check runs; MA and group scans skipped |

#### 5.3.3 — MA out-of-group heal path

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.3.10 | `healsOn=1`, MA below `singleHealPointMA` | MA HP 45%, threshold 80 | `singleHeal` called on MA |
| 5.3.11 | `healsOn=2` — MA OOG heal skipped | `healsOn=2` | MA heal path skipped; group scan runs |
| 5.3.12 | `healsOn=3` — MA healed, no group scan | `healsOn=3` | MA healed if needed; group member loop skipped |
| 5.3.13 | MA is self — no double-heal | `mainAssist = Me.CleanName()` | MA path skipped (`maID == Me.ID()`) |
| 5.3.14 | MA is corpse — skipped | `MA.Type() = 'corpse'` | MA path skipped |

#### 5.3.4 — Group member scan

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.3.15 | Group member below threshold | `Member[1].PctHPs()=30`, `singleHealPoint=80` | That member healed |
| 5.3.16 | Most hurt member chosen | Members at 70%, 40%, 60% | Member at 40% healed |
| 5.3.17 | Member out of range — skipped | `Member.Distance() > singleHealPointRange` | Out-of-range member not considered |
| 5.3.18 | Corpse member — skipped | `Member.Type()='corpse'` | Corpse not considered |
| 5.3.19 | Berserker ≥ level 95 above 70% — skipped | BER member at 75% HP, level 95 | Not healed (BER special rule) |
| 5.3.20 | Berserker ≥ level 95 below 70% — healed | BER member at 65% HP, level 95 | Healed normally |
| 5.3.21 | `healGroupPetsOn=true` — pet considered | `Member[0].Pet.PctHPs()=20`, `singleHealPoint=80` | Pet healed if most hurt |
| 5.3.22 | `healGroupPetsOn=false` — pets ignored | `Member[0].Pet.PctHPs()=10` | Pet not considered |

#### 5.3.5 — singleHeal dispatch

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.3.23 | Moving — no cast | `Me.Moving()=true` | `singleHeal` returns without casting |
| 5.3.24 | Hovering — no cast | `Me.Hovering()=true` | `singleHeal` returns without casting |
| 5.3.25 | healsArray empty — no cast | `state.heal.healsArray = {}` | `singleHeal` iterates nothing; no crash |
| 5.3.26 | Threshold computation — singleHealPoint from array | `healsArray = {'ClericSpell\|70\|G', 'FastHeal\|40\|G'}` | `singleHealPoint = 70` after `Heal.init()` |
| 5.3.27 | MA threshold computed separately | `healsArray = {'CLRSpell\|70\|', 'MASpell\|90\|MA'}` | `singleHealPoint=70`, `singleHealPointMA=90` |
| 5.3.28 | `session.heals` wired | `healsOn=1` after `Heal.init()` | `state.session.heals = true`; castMem no longer blocked |

---

### 5.4 Heal.doGroupHealStuff + Heal.doWeMed (Step 5.3)

#### 5.4.1 — groupHealArray population at init

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.4.1 | Group-type spell included | `healsArray = {'GroupHeal\|80\|'}` where `Spell.TargetType()='Group v2'` | `groupHealArray` contains the entry; `groupHealTimers[1] = 0` |
| 5.4.2 | Single-target spell excluded | `healsArray = {'SingleHeal\|80\|'}` where `TargetType='Single'` | `groupHealArray` empty |
| 5.4.3 | Self-target spell excluded | `healsArray = {'SelfHeal\|80\|'}` where `TargetType='Self'` | `groupHealArray` empty |
| 5.4.4 | Targeted AE without MA/ME tag included | `TargetType='Targeted AE'`, tag='' | Included in `groupHealArray` |
| 5.4.5 | Targeted AE with MA tag excluded | `TargetType='Targeted AE'`, tag='MA' | Excluded from `groupHealArray` |
| 5.4.6 | medStat derived — caster class | `Me.Class.ShortName()='CLR'` | `state.heal.medStat = 'Mana'` |
| 5.4.7 | medStat derived — melee class | `Me.Class.ShortName()='WAR'` | `state.heal.medStat = 'Endurance'` |
| 5.4.8 | medStat derived — bard | `Me.Class.ShortName()='BRD'` | `state.heal.medStat = 'Mana'` |

#### 5.4.2 — Heal.doGroupHealStuff dispatch

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.4.9 | groupHealArray empty — no cast | `groupHealArray = {}` | Returns immediately; no cast |
| 5.4.10 | Injured count ≤ 1 — no cast | `Group.Injured(80)=1` | Spell not cast (needs > 1) |
| 5.4.11 | Injured count > 1, timer expired — cast fires | `Group.Injured(80)=3`, `groupHealTimers[1]=0` | `castWhat(spell, Me.ID(), 'GroupHeal')` called |
| 5.4.12 | Timer not expired — no cast | `groupHealTimers[1] = os.clock() + 9999` | Spell skipped |
| 5.4.13 | Successful cast sets HoT timer | Cast returns `CAST_SUCCESS`, `MyDuration=30s` | `groupHealTimers[1] = os.clock() + 30` |
| 5.4.14 | Successful cast sets healAgain | Cast returns `CAST_SUCCESS` | `state.heal.healAgain = true` |
| 5.4.15 | Successful cast returns immediately | Two group spells in array | Only first matching spell cast; loop exits after success |
| 5.4.16 | Zero-threshold entry stops iteration | `groupHealArray[2] = 'Spell\|0\|'` | Loop breaks on zero-threshold; no further spells checked |

#### 5.4.3 — doGroupHealStuff call site in checkHealth

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.4.17 | Non-group-heal class — doGroupHealStuff skipped | `Me.Class.ShortName()='WAR'` | `doGroupHealStuff` not called |
| 5.4.18 | Group avg HP = 100 — skipped | `Group.AvgHPs()=100` | `doGroupHealStuff` not called |
| 5.4.19 | No group members — skipped | `Group.Members()=0` | `doGroupHealStuff` not called |
| 5.4.20 | Group-heal class, avg < 100, 2+ injured | `CLR`, `AvgHPs=85`, `Group.Injured(90)=3` | `doGroupHealStuff` called |

#### 5.4.4 — Heal.doWeMed

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.4.21 | `medOn=false` — no action | `state.heal.medOn = false` | Returns immediately; no sit/stand |
| 5.4.22 | In combat, `medCombat=false` — no action | `aggroTargetID='1234'`, `medCombat=false` | Returns immediately |
| 5.4.23 | In combat, `medCombat=true` — allowed | `aggroTargetID='1234'`, `medCombat=true` | Proceeds to medding check |
| 5.4.24 | Moving — no action | `Me.Moving()=true` | Returns immediately |
| 5.4.25 | Mana below medStart — sits | `PctMana=15`, `medStart=20` | `state.heal.medding=true`; `/sit` issued |
| 5.4.26 | Endurance below medStart — sits | `medStat='Endurance'`, `PctEndurance=10`, `medStart=20` | `state.heal.medding=true`; `/sit` issued |
| 5.4.27 | Medding, mana reaches medStop — stands | `medding=true`, `PctMana=100`, `medStop=100` | `state.heal.medding=false`; `/stand` issued |
| 5.4.28 | Medding but stood up externally — re-sits | `medding=true`, `Me.Sitting()=false`, `PctMana=50` | `/sit` re-issued |
| 5.4.29 | Mana above medStart, not medding — no action | `PctMana=80`, `medStart=20`, `medding=false` | No sit/stand; no state change |

---

## Section 5.5 — Heal.writeDebuffs + Heal.checkCures (Step 5.4)

#### 5.5.1 — curesOn integer loading

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.5.1 | CuresOn=0 loads as 0 | INI `CuresOn=0` | `state.heal.curesOn == 0` |
| 5.5.2 | CuresOn=1 loads as 1 | INI `CuresOn=1` | `state.heal.curesOn == 1` |
| 5.5.3 | CuresOn=2 loads as 2 | INI `CuresOn=2` | `state.heal.curesOn == 2` |
| 5.5.4 | CuresOn=3 loads as 3 | INI `CuresOn=3` | `state.heal.curesOn == 3` |

#### 5.5.2 — Heal.writeDebuffs

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.5.5 | Not debuffed, `needCuring=false` — no-op | All `Me.*ID()=0` | No ini write; `needCuring` stays false |
| 5.5.6 | Newly poisoned, `needCuring=false` — writes ini | `Me.Poisoned.ID()=1234`, others 0 | `needCuring=true`; `/ini` called with `"1\|1234\|0\|0\|0\|0"` |
| 5.5.7 | Poisoned + diseased — writes combined | `Poisoned.ID()=100`, `Diseased.ID()=200` | `needCuring=true`; count field is `300` |
| 5.5.8 | Curse + Restless Curse — combined into curse field | `Cursed.ID()=50`, `Song('Restless Curse').ID()=60` | Curse field = `110` |
| 5.5.9 | Already debuffed + `needCuring=true` — no re-write | `Me.Poisoned.ID()=1234`, `needCuring=true` | No second ini write (state gate prevents duplicate) |
| 5.5.10 | Was debuffed, cured, `needCuring=true` — clears | All debuffs gone, `needCuring=true` | `needCuring=false`; `/ini` called with empty Debuffs value |
| 5.5.11 | Was clean, still clean, `needCuring=false` — no-op | All 0, `needCuring=false` | No ini write; `needCuring` stays false |

#### 5.5.3 — Heal.checkCures guards

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.5.12 | `curesOn=0` — returns immediately | `state.heal.curesOn=0` | Returns; no cure logic runs |
| 5.5.13 | Invisible, no aggro — returns | `Me.Invis()=true`, `aggroTargetID=''` | Returns immediately |
| 5.5.14 | Invisible with aggro — proceeds | `Me.Invis()=true`, `aggroTargetID='1234'` | Does not return early on invis guard |
| 5.5.15 | Medding + medCombat — returns | `medding=true`, `medCombat=true` | Returns immediately (mac:12599) |
| 5.5.16 | Medding, medCombat=false — proceeds | `medding=true`, `medCombat=false` | Does not return early |

#### 5.5.4 — Target list building

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.5.17 | CuresOn=2 (self-only) — only Me.ID in list | `curesOn=2` | Only `Me.ID()` iterated; no ini section read |
| 5.5.18 | CuresOn=1 — reads section names from ini | `curesOn=1`, ini has sections `12345` and `67890` | Both IDs iterated |
| 5.5.19 | Empty ini sections, CuresOn=1 — falls back to self | `curesOn=1`, ini returns `''` | Falls back to `[Me.ID()]` |
| 5.5.20 | CuresOn=3, target not in group — skipped | `curesOn=3`, target `12345` not in `Group.Member(0..5)` | Target skipped; no cure attempt |
| 5.5.21 | Target is Corpse — skipped | `Spawn.Type()='Corpse'` | Target skipped |
| 5.5.22 | Target > 100 distance — skipped | `Spawn.Distance()=150` | Target skipped |

#### 5.5.5 — Cure entry parsing and dispatch

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.5.23 | Blank entry skipped | `curesArray[1]=''` | No cast attempt |
| 5.5.24 | Scope `me`, target is self — cures | `entry='CurePoison\|poison\|me'`, `targetID=Me.ID()` | Cure attempted on self |
| 5.5.25 | Scope `me`, target is other — skipped | `entry='CurePoison\|poison\|me'`, `targetID=99999` | Skip; no cast |
| 5.5.26 | No type filter (`arg2=''`) — cures regardless | `entry='Cleanse'`, target has any debuff | Cure attempted unconditionally |
| 5.5.27 | Type `poison`, target poisoned — cures | `debuffType='poison'`, `poison>0` | `castWhat('Cleanse', targetID, 'Cure')` called |
| 5.5.28 | Type `poison`, target not poisoned — skipped | `debuffType='poison'`, `poison=0` | No cast |
| 5.5.29 | Type `disease` — matches disease field | `debuffType='disease'`, `disease>0` | Cast fires |
| 5.5.30 | Type `curse` — matches combined curse field | `debuffType='curse'`, `curse>0` | Cast fires |
| 5.5.31 | Type `corruption` — matches corrupt field | `debuffType='corruption'`, `corrupt>0` | Cast fires |
| 5.5.32 | Type `mezzed` — matches mez field | `debuffType='mezzed'`, `mezzed>0` | Cast fires |
| 5.5.33 | Spell not ready — skipped | `Me.SpellReady=false`, no AA/disc/item ready either | No cast |
| 5.5.34 | Group-spell, target out-of-group — skipped | `TargetType='Group v1'`, target not in group | Skip with no cast |
| 5.5.35 | Self-target: live TLO read; no debuffs — breaks cure loop | `targetID=Me.ID()`, all debuffs 0 | Inner cure loop breaks; moves to next target |
| 5.5.36 | Other target: ini count=0 — breaks cure loop | `Ini[targetID][Debuffs]='0\|...'` first field = 0 | Inner loop breaks |

#### 5.5.6 — Post-cast behavior

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.5.37 | Successful cure — broadcasts | `castReturn='CAST_SUCCESS'` | `/bc o "CURING: >> <name> << with <spell>"` issued |
| 5.5.38 | Successful cure + healsOn>0 — re-checks health | `castReturn='CAST_SUCCESS'`, `healsOn=1` | `Heal.checkHealth('CheckCures')` called |
| 5.5.39 | Successful self-cure — refreshes writeDebuffs | `targetID=Me.ID()`, `castReturn='CAST_SUCCESS'` | `Heal.writeDebuffs()` called after cure loop |
| 5.5.40 | Failed cure — no broadcast or health re-check | `castReturn='CAST_FIZZLE'` | No broadcast; no checkHealth call |

#### 5.5.7 — MezBroke reset

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 5.5.41 | checkCures resets mez.broke | `state.mez.broke=true` before call | `state.mez.broke=false` after checkCures returns |

---

## Section 5.6 — Heal.rezCheck + rezWithCheck (Step 5.5)

#### 5.6.1 — autoRezOn integer loading

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.1 | AutoRezOn=0 loads as 0 | INI `AutoRezOn=0` | `state.heal.autoRezOn == 0` |
| 5.6.2 | AutoRezOn=1 loads as 1 | INI `AutoRezOn=1` | `state.heal.autoRezOn == 1` |
| 5.6.3 | AutoRezOn=2 loads as 2 | INI `AutoRezOn=2` | `state.heal.autoRezOn == 2` |

#### 5.6.2 — AutoRez array loading

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.4 | AutoRez entries load into array | INI `AutoRez1=Resurrection\|0\|rez` | `state.heal.autoRezArray[1] == 'Resurrection\|0\|rez'` |
| 5.6.5 | Multiple entries load in order | INI `AutoRez1=…`, `AutoRez2=…` | Array has both entries in order |
| 5.6.6 | NULL entries skipped | INI `AutoRez1=NULL` | Array is empty |

#### 5.6.3 — rezCheck guards

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.7 | `autoRezOn=0` — returns immediately | `state.heal.autoRezOn=0` | Returns; no rez logic runs |
| 5.6.8 | DMZ zone, not in instance — returns | `state.misc.dmz=true`, `Zone.IsInstance()=false` | Returns immediately |
| 5.6.9 | DMZ zone, in instance — proceeds | `state.misc.dmz=true`, `Zone.IsInstance()=true` | Does not return early on DMZ guard |
| 5.6.10 | Hovering — returns | `Me.Hovering()=true` | Returns immediately |
| 5.6.11 | Invisible, no aggro — returns | `Me.Invis()=true`, `aggroTargetID=''` | Returns immediately |
| 5.6.12 | `autoRezOn=2`, aggro present — returns | `autoRezOn=2`, `aggroTargetID='1234'` | Returns (OOC-only mode) |
| 5.6.13 | `autoRezOn=1`, aggro present — proceeds | `autoRezOn=1`, `aggroTargetID='1234'` | Does not return early on combat guard |
| 5.6.14 | No rez spell ready — returns early | `autoRezArray` empty or no spell ready | Returns after probe; no targeting attempted |

#### 5.6.4 — rezWithCheck spell selection

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.15 | `rez` type — valid OOC and in combat | `rezType='rez'`, `Me.SpellReady()=true` | Returns spell name |
| 5.6.16 | `rezooc` type — valid OOC, skipped in combat | `rezType='rezooc'`, in combat | Returns nil; spell skipped |
| 5.6.17 | `rezooc` type — valid when OOC | `rezType='rezooc'`, not in combat | Returns spell name |
| 5.6.18 | `rezcombat` type — valid in combat, skipped OOC | `rezType='rezcombat'`, not in combat | Returns nil; spell skipped |
| 5.6.19 | `rezcombat` type — valid when in combat | `rezType='rezcombat'`, in combat | Returns spell name |
| 5.6.20 | Unknown rez type — stops iteration | `rezType='invalid'`, second entry is valid | Returns nil; loop stops at bad entry |
| 5.6.21 | Spell not ready — skipped | `SpellReady()=false`, `AltAbilityReady()=false`, `ItemReady()=false` | Returns nil |
| 5.6.22 | First ready spell returned | Two entries, first not ready, second ready | Returns second spell name |

#### 5.6.5 — MA corpse rez

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.23 | MA corpse in range — rezzes | MA has corpse within 150, rez ready, no OOC timer | Target set to corpse; `castWhat` called; broadcast sent |
| 5.6.24 | MA corpse — OOC timer not expired — skips | `oocRezTimers[maCorpseID]` in future | No cast attempted |
| 5.6.25 | No MA set — skips MA phase | `state.session.mainAssist=''` | MA phase skipped cleanly |

#### 5.6.6 — Self rez

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.26 | Self corpse exists, timer clear — rezzes | Own pccorpse in range, `oocRezTimers` clear | `castWhat` called with corpse ID; broadcast sent |
| 5.6.27 | Self corpse, OOC timer active — skips | `oocRezTimers[myCopseID]` in future | No cast |
| 5.6.28 | No self corpse — skips | No pccorpse for own name | Self rez phase no-ops |
| 5.6.29 | `rezMeLast=false` — self rezzes before group | `rezMeLast=false`, both self and group member have corpse | Self rezzed first |
| 5.6.30 | `rezMeLast=true` — group rezzes before self | `rezMeLast=true`, both self and group member have corpse | Group member rezzed first |

#### 5.6.7 — Group member rez

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.31 | Group member corpse in range — rezzes | Member corpse < 100 dist, battleRezTimers[i]=0 | `castWhat` called; broadcast "REZZED" |
| 5.6.32 | battleRezTimer not expired — skips slot | `battleRezTimers[i]` in future | No cast for that slot |
| 5.6.33 | MA member — skipped | Member's name == mainAssist | Slot skipped |
| 5.6.34 | Corpse > 100 dist — skipped | Corpse distance = 150 | No cast |
| 5.6.35 | OOC rez success — timer set to 60s | Non-combat, rez success | `battleRezTimers[i] = os.clock() + 60` |
| 5.6.36 | Combat rez success — timer set to 180s | `combatStart=true`, rez success | `battleRezTimers[i] = os.clock() + 180` |
| 5.6.37 | Call of Wild rez success — timer set to 360s | Spell name contains 'Call of', rez success | `battleRezTimers[i] = os.clock() + 360` |
| 5.6.38 | Rez fails — throttle timer set to 60s | `castReturn != CAST_SUCCESS` | `battleRezTimers[i] = os.clock() + 60` |
| 5.6.39 | Member in other zone + Call of Wild — skipped | `OtherZone()=true`, spell contains 'Call of' | Slot skipped |

#### 5.6.8 — autoRezAll OOC pass

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.6.40 | `autoRezAll=false` — OOC pass skipped | `autoRezAll=false`, corpses present | autoRezAll block not entered |
| 5.6.41 | `combatStart=true` — OOC pass skipped | `combatStart=true`, `autoRezAll=true` | autoRezAll block not entered |
| 5.6.42 | New corpse, tries=0 — casts and records | `autoRezAll=true`, OOC, corpse nearby, timer clear | Cast attempted; `corpseRezCheck` updated to `id:1|…` |
| 5.6.43 | tries=3 — skipped | `corpseRezCheck` has `id:3|` | No cast for that corpse |
| 5.6.44 | OOC timer active — skipped | `oocRezTimers[id]` in future | No cast |
| 5.6.45 | No corpses remain — prunes timers + resets corpseRezCheck | `SpawnCount=0` | `corpseRezCheck='null'`; stale timer entries removed |

---

## Section 5.7 — Loop wiring (Step 5.6)

#### 5.7.1 — Combat.init heal wiring

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.7.1 | `_heal` stored when Heal passed as 4th arg | `Combat.init(state, utils, cast, Heal)` | Internal `_heal` reference holds the Heal module |
| 5.7.2 | No error when Heal not passed | `Combat.init(state, utils, cast)` — no 4th arg | All `if _heal then` guards handle nil cleanly; no runtime error |

#### 5.7.2 — fight() inner loop: CheckCures/CheckHealth after AggroCheck

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.7.3 | `checkCures()` called after AggroCheck each iteration | `_heal` present; combat loop iterates | `checkCures` invoked before NamedWatch check each pass |
| 5.7.4 | `checkHealth('Combat')` called after AggroCheck | `_heal` present | `checkHealth` called with `sentFrom='Combat'` |
| 5.7.5 | No error when `_heal` nil | Heal not passed to `Combat.init` | `if _heal then` guard prevents nil call; loop continues normally |

#### 5.7.3 — fight() inner loop: WriteDebuffs + second cure/heal after DPS casts

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.7.6 | `writeDebuffs()` called after DPS casts | `_heal` present; DPS cast block executes | `writeDebuffs` invoked post-DPS each inner-loop iteration |
| 5.7.7 | Second `checkCures()` + `checkHealth('Combat2')` called | `_heal` present | Both called in order after `writeDebuffs` |

#### 5.7.4 — checkForCombat() non-MA assist loop: CheckHealth

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.7.8 | `checkHealth('CheckForCombat')` called after assist | Non-MA, `_heal` present | `checkHealth` called each pass of the assist wait loop |
| 5.7.9 | Fires even when assist yields no target | `assist()` returns with `myTargetID=0` | `checkHealth` still called before break-condition check |

#### 5.7.5 — checkForCombat() skipCombat==1 healer path

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.7.10 | `skipCombat==1`: checkCures + checkHealth called | `skipCombat=1`, `_heal` present | `checkCures()` then `checkHealth('SkipCombat')` called; full combat block skipped |
| 5.7.11 | `skipCombat==0`: healer-only block not entered | `skipCombat=0`, `_heal` present | `skipCombat == 1` guard prevents entry; block not executed |
| 5.7.12 | `_heal` nil with `skipCombat==1` — no error | `_heal=nil`, `skipCombat=1` | `if _heal then` guard prevents nil call |

#### 5.7.6 — init.lua main loop: heal calls every tick

| # | Test | Setup | Expected |
|---|------|-------|----------|
| 5.7.13 | `Heal.writeDebuffs()` called every tick | Main loop running, any state | Called once per tick regardless of combat state |
| 5.7.14 | `Heal.checkHealth('MainLoop')` called every tick | Main loop running | Called once per tick; `healsOn==0` guard causes immediate return when inactive |
| 5.7.15 | `Heal.checkCures()` called every tick | Main loop running | Called once per tick; `curesOn==0` guard causes immediate return when inactive |
| 5.7.16 | `Heal.doWeMed()` called every tick | Main loop running | Called once per tick; `medOn=false` guard causes immediate return when inactive |
| 5.7.17 | Out-of-combat heals fire from main loop | `healsOn=1`, group member HP < threshold, `aggroTargetID=''` | `checkHealth('MainLoop')` fires a heal from main loop without a combat pass |
| 5.7.18 | Combat heals fire from fight() inner loop, not only from main loop | `healsOn=1`, mob engaged in fight() | `checkHealth('Combat')` fires mid-combat loop independently of main-loop call |

---

## Section 6 — Buff System (Milestone 6)

---

### Section 6.1 — Buffs.init (Step 6.1)

#### 6.1.1 INI loading — buffsOn / rebuffOn / checkBuffsTimer

| # | Input | Expected |
|---|-------|----------|
| 6.1.1 | INI `[Buffs] BuffsOn=1` | `state.buffs.buffsOn == true` |
| 6.1.2 | INI `[Buffs] BuffsOn=0` (or absent) | `state.buffs.buffsOn == false` |
| 6.1.3 | INI `[Buffs] RebuffOn=1` | `state.buffs.rebuffOn == true` |
| 6.1.4 | INI `[Buffs] RebuffOn=0` | `state.buffs.rebuffOn == false` |
| 6.1.5 | INI `[Buffs] CheckBuffsTimer=30` | `state.buffs.checkBuffsTimer == 30` |
| 6.1.6 | INI `CheckBuffsTimer` absent | `state.buffs.checkBuffsTimer == 15` (default) |
| 6.1.7 | INI `[Buffs] PowerSource=Eldritch Rune` | `state.buffs.powerSource == 'Eldritch Rune'` |
| 6.1.8 | INI `PowerSource` absent | `state.buffs.powerSource == ''` |

#### 6.1.2 INI loading — buffsArray

| # | Input | Expected |
|---|-------|----------|
| 6.1.9  | INI `Buffs1=Haste\|group`, `Buffs2=Clarity\|self` | `state.buffs.buffsArray[1] == 'Haste\|group'`; `[2] == 'Clarity\|self'` |
| 6.1.10 | INI `Buffs1` absent | `state.buffs.buffsArray` is empty table `{}` |
| 6.1.11 | INI `Buffs1=''` (blank entry) | Blank entries skipped; array remains empty |

#### 6.1.3 INI loading — pet buffs

| # | Input | Expected |
|---|-------|----------|
| 6.1.12 | INI `[Pet] PetBuffsOn=1` | `state.buffs.petBuffsOn == true` |
| 6.1.13 | INI `[Pet] PetBuffsOn=0` (or absent) | `state.buffs.petBuffsOn == false` |
| 6.1.14 | INI `PetBuffs1=Burnout\|self`, `PetBuffs2=Ferocity\|self` | `state.buffs.petBuffsArray[1] == 'Burnout\|self'`; `[2] == 'Ferocity\|self'` |
| 6.1.15 | INI `PetBuffs1` absent | `state.buffs.petBuffsArray` is empty |

#### 6.1.4 INI loading — mount fields

| # | Input | Expected |
|---|-------|----------|
| 6.1.16 | INI `[General] MountOn=1` | `state.misc.mountOn == true` |
| 6.1.17 | INI `[General] MountOn=0` | `state.misc.mountOn == false` |
| 6.1.18 | INI `[General] MountOn` absent | `state.misc.mountOn` retains state.lua default (`true`) |
| 6.1.19 | INI `[General] MountSpell=Black Stallion` | `state.buffs.mountSpell == 'Black Stallion'` |
| 6.1.20 | INI `MountSpell` absent | `state.buffs.mountSpell == ''` |

#### 6.1.5 State defaults — blockedBuffsCount + slotTimers

| # | Input | Expected |
|---|-------|----------|
| 6.1.21 | No INI override | `state.buffs.blockedBuffsCount == 30` |
| 6.1.22 | After `require('modules.state')` | `state.buffs.slotTimers[1][0] == 0`; `slotTimers[20][5] == 0` |
| 6.1.23 | After `require('modules.state')` | `state.buffs.slotTimers[1]` is a table with keys 0–5 |

#### 6.1.6 Module load

| # | Scenario | Expected |
|---|----------|----------|
| 6.1.24 | `/lua run kissassist-lua` with `[Buffs] BuffsOn=1`, 3 buff entries | No Lua errors; debug line printed: `Buffs.init: buffsOn=true buffs#=3 ...` |
| 6.1.25 | `/lua run kissassist-lua` with no `[Buffs]` section | Module loads cleanly; all defaults intact; no error |

---

### Section 6.2 — WriteBuffs / WriteBuffsPet / WriteBuffsMerc (Step 6.2)

#### 6.2.1 Buffs.writeBuffs — guards

| # | Condition | Expected |
|---|-----------|----------|
| 6.2.1 | `timers.writeBuffs` not expired | Returns immediately; no INI write |
| 6.2.2 | `state.misc.redguides = false` | Returns immediately |
| 6.2.3 | `aggroTargetID ~= ''` (in combat) | Returns immediately |
| 6.2.4 | `state.session.danNetOn = true` | Returns immediately |
| 6.2.5 | All guards pass, OOC | Proceeds to write |

#### 6.2.2 Buffs.writeBuffs — INI output

| # | Scenario | Expected |
|---|----------|----------|
| 6.2.6  | First write, no existing entry | `[Me.ID]` section created with Day/Hour/Zone/Buffs/Blockedbuffs keys |
| 6.2.7  | `[Me.ID].Day` already exists | Day key NOT overwritten (only-if-absent guard) |
| 6.2.8  | Character has 3 active buffs | `Buffs` key = `SpellA\|SpellB\|SpellC\|` |
| 6.2.9  | Buff name contains `:Permanent` | `:Permanent` suffix stripped before writing |
| 6.2.10 | No active buffs | `Buffs` key = `""` |
| 6.2.11 | 2 blocked buffs present | `Blockedbuffs` key written with `SpellX\|SpellY\|` |
| 6.2.12 | No blocked buffs | `Blockedbuffs` key not updated (empty list skipped) |
| 6.2.13 | After successful write | `state.timers.writeBuffs = os.clock() + 30` |
| 6.2.14 | `MyRole` key | Written with `state.session.role` value |

#### 6.2.3 Buffs.writeBuffsPet — guards and output

| # | Condition | Expected |
|---|-----------|----------|
| 6.2.15 | `Me.Pet.ID() == 0` (no pet) | Returns immediately |
| 6.2.16 | Role is `assist` (not pettank) | Returns immediately |
| 6.2.17 | Role is `pettank`, pet exists, OOC | Proceeds; writes `[Me.Pet.ID]` section |
| 6.2.18 | Pet has 2 buffs | `Buffs` key = `PetSpellA\|PetSpellB\|` |
| 6.2.19 | Blocked pet buffs present | `Blockedbuffs` key written (slots 0–39) |
| 6.2.20 | After write | `state.timers.writeBuffsPet = os.clock() + 30` |

#### 6.2.4 Buffs.writeBuffsMerc — guards and output

| # | Condition | Expected |
|---|-----------|----------|
| 6.2.21 | `Mercenary.State() ~= 'Active'` | Returns immediately |
| 6.2.22 | Merc active, OOC, all guards pass | Proceeds; writes `[Mercenary.ID]` section |
| 6.2.23 | Merc has 2 buffs | `Buffs` key populated (slots 1–15) |
| 6.2.24 | After write | `state.timers.writeBuffsMerc = os.clock() + 30` |

#### 6.2.5 cleanBuffsFile — stale entry removal

| # | Scenario | Expected |
|---|----------|----------|
| 6.2.25 | `timers.cleanBuffs` not expired | Returns immediately; no deletions |
| 6.2.26 | Entry Day != today | Section deleted from KissAssist_Buffs.ini |
| 6.2.27 | Entry Day == today, Hour != current hour | Section deleted |
| 6.2.28 | Entry Day == today, Hour == current hour | Section retained |
| 6.2.29 | After clean pass | `timers.cleanBuffs = os.clock() + 600` |

---

### Step 6.3 — `Buffs.checkBuffs`: entry parsing + self / group-v dispatch

#### 6.3.1 — Entry-function guards

| # | Condition | Expected |
|---|-----------|----------|
| 6.3.1 | `buffsOn = false` | Returns immediately; no loop |
| 6.3.2 | `misc.iAmDead = true` | Returns immediately |
| 6.3.3 | `Me.Hovering() = true` | Returns immediately |
| 6.3.4 | `Me.Invis() = true`, class = Rogue | Does NOT return (Rogues may buff while invis) |
| 6.3.5 | `Me.Invis() = true`, class = Wizard | Returns immediately |
| 6.3.6 | `chaseAssist = true`, `Me.Moving() = true` | Returns immediately |
| 6.3.7 | `Me.Moving() = true`, `whoToChase == Me.Name()` | Returns immediately |
| 6.3.8 | All guards pass | Proceeds to PowerSource / mount checks |

#### 6.3.2 — PowerSource refuel

| # | Scenario | Expected |
|---|----------|----------|
| 6.3.9  | `powerSource = ''` | refuelPowerSource skipped entirely |
| 6.3.10 | PowerSource slot exists and has charges | No click; continues normally |
| 6.3.11 | PowerSource slot exists, `Power() == 0` | Clicks item to cursor; destroys if name matches; waits for cursor clear |

#### 6.3.3 — Mount cast

| # | Condition | Expected |
|---|-----------|----------|
| 6.3.12 | `mountOn = false` | Mount cast skipped |
| 6.3.13 | `mountOn = true`, `Me.Mount.ID()` non-zero (already mounted) | Mount cast skipped |
| 6.3.14 | `mountOn = true`, not mounted, indoor zone (not Outdoor, not Type 1/2/5) | Mount cast skipped |
| 6.3.15 | `mountOn = true`, not mounted, outdoor zone, OOC | `castMount()` called with `mountSpell` |
| 6.3.16 | `mountOn = true`, not mounted, zone Type 1, OOC | `castMount()` called |
| 6.3.17 | `mountOn = true`, not mounted, `CombatState() == 'COMBAT'` | Mount cast skipped |

#### 6.3.4 — Per-entry loop: event drain and bail conditions

| # | Scenario | Expected |
|---|----------|----------|
| 6.3.18 | `Me.Invis()` becomes true at top of iteration | `return` immediately |
| 6.3.19 | `aggroTargetID` non-empty; aggro spawn Distance < 200 | `return` immediately |
| 6.3.20 | `aggroTargetID` non-empty; aggro spawn Distance >= 200 | Loop continues |
| 6.3.21 | Entry contains `\|0` | `goto continue` (skips this entry) |
| 6.3.22 | Entry == `'NULL'` | `goto continue` |
| 6.3.23 | `curesOn > 0` | `Heal.checkCures('Combat')` called each iteration |
| 6.3.24 | `healsOn > 0`, `lastHealCheck` expired | `Heal.checkHealth('CheckBuffs')` called; `lastHealCheck` reset |
| 6.3.25 | `healsOn > 0`, `lastHealCheck` not expired | `checkHealth` NOT called |
| 6.3.26 | `autoRezOn > 0`, `healsOn == 0`, `curesOn == 0` | `Heal.rezCheck('group')` called |

#### 6.3.5 — Entry parsing

| # | Entry string | Expected `spellToCast` / `p2` / `p3` |
|---|--------------|--------------------------------------|
| 6.3.27 | `'Rune of Zebuxoruk'` (no pipe) | `spellToCast='Rune of Zebuxoruk'`, `p2=''` |
| 6.3.28 | `'Adrenaline Surge\|Dual\|Adrenaline Surge'` (4thPart absent) | `p2='Dual'` (no sub-tag match; stays Dual) |
| 6.3.29 | `'Spell\|Dual\|Spell\|MA'` | `p2='DualMA'` |
| 6.3.30 | `'Spell\|Dual\|Spell\|melee'` | `p2='DualMelee'` |
| 6.3.31 | `'Spell\|Dual\|Spell\|caster'` | `p2='DualCaster'` |
| 6.3.32 | `'Spell\|Dual\|Spell\|class\|CLR,DRU'` | `p2='DualClass'` |
| 6.3.33 | `'Spell\|class\|CLR,DRU'` | `p2='class'`, `p5='CLR,DRU'` (shifted from p3) |
| 6.3.34 | `'Spell\|alias\|something'` | `goto continue` — entry skipped |
| 6.3.35 | `'Spell\|condGT50MAN\|...'` (2ndPart starts with `cond`) | `p2` cleared to `''` |

#### 6.3.6 — `buffToCheck` resolution

| # | Scenario | Expected `buffToCheck` |
|---|----------|------------------------|
| 6.3.36 | `redguides=true` (gold), non-Dual, `spellToCast='Rune of Zebuxoruk Rk. II'` | `'Rune of Zebuxoruk Rk. II'` (no strip) |
| 6.3.37 | `redguides=false` (non-gold), non-Dual, `spellToCast='Rune of Zebuxoruk Rk. II'` | `'Rune of Zebuxoruk'` (stripped) |
| 6.3.38 | `redguides=false`, Dual tag, `p3='Focus Rk. II'` | `'Focus'` (stripped from p3) |
| 6.3.39 | `redguides=true`, Dual tag, `p3='Focus Rk. II'` | `'Focus Rk. II'` (no strip) |

#### 6.3.7 — `bookSpellTT` and `spellRange`

| # | Scenario | Expected |
|---|----------|----------|
| 6.3.40 | Spell not in spellbook | `bookSpellTT = '0'`; uses `Spell.TargetType()` directly |
| 6.3.41 | Spell in spellbook | `bookSpellTT` set from `Spell[BookID].TargetType` |
| 6.3.42 | `Spell.Range() > Spell.AERange()` | `spellRange = Spell.Range()` |
| 6.3.43 | `Spell.AERange() > Spell.Range()` | `spellRange = Spell.AERange()` |
| 6.3.44 | Both range values are 0 | `spellRange = 100` (default) |

#### 6.3.8 — Mid-loop combat / timer bail

| # | Condition | Expected |
|---|-----------|----------|
| 6.3.45 | `combatStart = true` | `return` immediately after parsing |
| 6.3.46 | `aggroTargetID` non-empty (any distance) | `return` immediately after parsing |
| 6.3.47 | `iAmDead = true` (became true mid-loop) | `return` |
| 6.3.48 | `Me.Invis()` true mid-loop | `return` |
| 6.3.49 | `timers.readBuffs > os.clock()` | `return` |

#### 6.3.9 — `group v` target-type branch

| # | Scenario | Expected |
|---|----------|----------|
| 6.3.50 | Spell TargetType contains `'group v'`, `slotTimers[i][0]` not expired | Cast attempted |
| 6.3.51 | `slotTimers[i][0] > os.clock()` (timer active) | `goto continue`; no cast |
| 6.3.52 | Cast returns `CAST_SUCCESS` | `timers.writeBuffs` reset to 0; `writeBuffs()` called; echo printed |
| 6.3.53 | Cast returns `CAST_TAKEHOLD` | `slotTimers[i][0] = os.clock() + Spell.MyDuration.TotalSeconds()` |
| 6.3.54 | Cast returns `CAST_COMPONENTS` | `buffsArray[i]` set to `'NULL'`; echo printed; `goto continue` |
| 6.3.55 | `forceGroup = true` after cast | Waits for `Me.SpellInCooldown()` to clear before next entry |

#### 6.3.10 — `self` target-type branch

| # | Scenario | Expected |
|---|----------|----------|
| 6.3.56 | Spell TargetType contains `'self'`; `Me.Buff(buffToCheck).ID() ~= 0` | `goto continue`; no cast |
| 6.3.57 | `Me.Song(buffToCheck).ID() ~= 0` | `goto continue`; no cast |
| 6.3.58 | `Spell(buffToCheck).WillLand() == false` | `goto continue`; no cast |
| 6.3.59 | Buff absent, WillLand true | `castWhat(spellToCast, Me.ID, 'buffs-nomem')` called |
| 6.3.60 | Cast returns `CAST_COMPONENTS` | `buffsArray[i]` set to `'NULL'`; echo printed |
| 6.3.61 | Cast returns `CAST_SUCCESS` | `goto continue`; no extra timer set (self spells re-check buff presence each loop) |

#### 6.4 — `CheckBuffs`: single-target group iteration + class filters

##### 6.4.1 — `isSingle` detection

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.1 | `bookSpellTT == '0'` and `Spell.TargetType` contains `'single'` | `isSingle = true`; group loop entered |
| 6.4.2 | `bookSpellTT` contains `'single'` (book lookup succeeded) | `isSingle = true` |
| 6.4.3 | Neither TT contains `'single'` | `isSingle = false`; special action tag chain checked next |

##### 6.4.2 — Group member skip conditions

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.4 | `Group.Member(j).ID() == 0` (slot empty) | `goto jcontinue`; member skipped |
| 6.4.5 | `Spawn(memberID).Distance() >= spellRange` | `goto jcontinue` |
| 6.4.6 | `slotTimers[i][j] > os.clock()` (timer active) | `goto jcontinue` |
| 6.4.7 | All members skipped due to distance | Loop completes without casting |

##### 6.4.3 — `|me` / `|Dualme` filter

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.8 | `p2 == 'me'`, `j == 0` (self) | Member not skipped; cast attempted |
| 6.4.9 | `p2 == 'me'`, `j > 0` (group member) | `goto jcontinue`; member skipped |
| 6.4.10 | `p2 == 'Dualme'`, `j > 0` | `goto jcontinue` |

##### 6.4.4 — Per-cast mana check

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.11 | `Me.CurrentMana() >= Spell.Mana()` | Cast proceeds |
| 6.4.12 | `Me.CurrentMana() < Spell.Mana()` | `break` entire j loop; no more members buffed |

##### 6.4.5 — Class filter tags

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.13 | `p2 == 'caster'`; member class is `WIZ` (in CASTER_CLASSES) | Not skipped; cast attempted |
| 6.4.14 | `p2 == 'caster'`; member class is `WAR` (not in CASTER_CLASSES) | `goto jcontinue` |
| 6.4.15 | `p2 == 'DualCaster'`; member class is `CLR` | Not skipped |
| 6.4.16 | `p2 == 'Melee'`; member class is `WAR` (in MELEE_CLASSES) | Not skipped |
| 6.4.17 | `p2 == 'Melee'`; member class is `WIZ` (not in MELEE_CLASSES) | `goto jcontinue` |
| 6.4.18 | `p2 == 'DualMelee'`; member class is `MNK` | Not skipped |
| 6.4.19 | `p2 == 'class'`; member class in `p5` list (`CLR,DRU`) | Not skipped |
| 6.4.20 | `p2 == 'class'`; member class not in `p5` list | `goto jcontinue` |
| 6.4.21 | `p2 == 'DualClass'`; member class in `p5` | Not skipped |
| 6.4.22 | `p2 == '!class'`; member class IS in `p5` list | `goto jcontinue` |
| 6.4.23 | `p2 == '!class'`; member class not in `p5` | Not skipped |
| 6.4.24 | `p2 == 'Dual!Class'`; member class IS in `p5` | `goto jcontinue` |

##### 6.4.6 — `|MA` / `|!MA` filter

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.25 | `p2 == 'MA'`; member ID matches `Spawn('PC mainAssist').ID()` | Not skipped |
| 6.4.26 | `p2 == 'MA'`; member ID does not match MA | `goto jcontinue` |
| 6.4.27 | `p2 == 'DualMA'`; member matches MA | Not skipped |
| 6.4.28 | `p2 == '!MA'`; member IS the MA | `goto jcontinue` |
| 6.4.29 | `p2 == '!MA'`; member is not the MA | Not skipped |

##### 6.4.7 — Mid-loop aggro bail + gem timer wait

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.30 | `aggroTargetID` set and aggro spawn distance < 200 | `return` from `checkBuffs` |
| 6.4.31 | `aggroTargetID` set but distance ≥ 200 | Loop continues |
| 6.4.32 | Spell memed; `GemTimer > 6s` | `goto jcontinue`; member skipped |
| 6.4.33 | Spell memed; `GemTimer ≤ 6s`; spell becomes ready | Cast proceeds after wait |
| 6.4.34 | Aggro fires during gem timer wait | `return` |

##### 6.4.8 — Cast results (per member)

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.35 | `CAST_SUCCESS`; `j > 0` | `slotTimers[i][j] = os.clock() + Spell.MyDuration.TotalSeconds()`; no writeBuffs |
| 6.4.36 | `CAST_SUCCESS`; `j == 0` (self) | `timers.writeBuffs = 0`; `writeBuffs()` called |
| 6.4.37 | `CAST_HASBUFF` | `slotTimers[i][j]` set from spell duration |
| 6.4.38 | `CAST_TAKEHOLD` | `slotTimers[i][j]` set from spell duration |
| 6.4.39 | `CAST_COMPONENTS` | `buffsArray[i] = 'NULL'`; echo printed; `goto jcontinue` |

##### 6.4.9 — Invis during j loop

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.40 | `Me.Invis()` becomes true at top of j loop | `break`; remaining members not buffed |

##### 6.4.10 — No-group fallback

| # | Scenario | Expected |
|---|----------|----------|
| 6.4.41 | `Group.Members() == 0`; `p2` not in CLASS_FILTER_TAGS | Cast on `Me.ID`; `CAST_SUCCESS` sets `slotTimers[i][0]` + `writeBuffs()` |
| 6.4.42 | `Group.Members() == 0`; `p2 == 'MA'` (CLASS_FILTER_TAGS) | No cast; `goto continue` |
| 6.4.43 | `Group.Members() == 0`; `p2 == 'caster'` | No cast |
| 6.4.44 | No-group fallback; `CAST_HASBUFF` | `slotTimers[i][0]` set |
| 6.4.45 | No-group fallback; `CAST_COMPONENTS` | `buffsArray[i] = 'NULL'`; echo printed |

---

### Section 6.5 — `CheckBuffs`: special action tags + `CheckBegforBuffs`

#### 6.5.1 — Structural ordering: special tags checked before target-type dispatch

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.1 | Entry `SpellName\|Aura`; spell has single-target TT | `checkAura()` fires; group loop NOT entered |
| 6.5.2 | Entry `SpellName\|Once`; spell has single-target TT | `buffOnce()` fires; group loop NOT entered |
| 6.5.3 | Entry `SpellName\|mana\|80\|50` | `|mana` branch fires; group loop NOT entered |

##### 6.5.2 — `|Endgroup` / `|Managroup`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.4 | `p2 == 'Endgroup'`; group member BER at 30% endurance (below p3=50) | `regenOther()` casts on BER; `slotTimers[i][0]` set to `os.clock() + dur*10` |
| 6.5.5 | `p2 == 'Managroup'`; group member CLR at 20% mana (below p3=40) | `regenOther()` casts on CLR |
| 6.5.6 | `p2 == 'Endgroup'`; all members above threshold | `regenOther()` returns false; no cast; `goto continue` |
| 6.5.7 | `p2 == 'Endgroup'`; no group members | Outer `if groupCount > 0` fails; `goto continue` with no cast |
| 6.5.8 | `p2 == 'Endgroup'`; MA in group; spell name contains `'Rallying Call'` | MA skipped; next qualifying member targeted |
| 6.5.9 | `p2 == 'Managroup'`; BRD member; spell `'Dichotomic Psalm'` | BRD skipped; next qualifying member targeted |

##### 6.5.3 — `|mana`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.10 | `PctMana == 60`, `p3 == 80` (mana below thresh); `PctHPs == 100`, `p4 == 50` | Cast attempted |
| 6.5.11 | `PctMana == 90`, `p3 == 80` (mana already high) | Skip cast; `goto continue` |
| 6.5.12 | `PctMana == 50`, `p3 == 80`; `PctHPs == 30`, `p4 == 50` (HP low) | Skip cast (HP below p4 threshold) |
| 6.5.13 | Cast returns `CAST_COMPONENTS` | `buffsArray[i] = 'NULL'`; echo printed; `goto continue` |
| 6.5.14 | `p4` empty string | `hpThresh = 0`; HP condition always passes; only mana threshold checked |

##### 6.5.4 — `|End`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.15 | `PctEndurance == 40`, `p3 == 50`; `CombatAbilityReady == true` | `checkEndurance()` called; cast attempted |
| 6.5.16 | `PctEndurance == 40`, `p3 == 50`; neither CA nor AA ready | `checkEndurance()` not called; `goto continue` |
| 6.5.17 | `PctEndurance == 80`, `p3 == 50` (above threshold) | `checkEndurance()` not called; `goto continue` |
| 6.5.18 | `checkEndurance()` fires; `Me.Sitting() == true` | `/stand` issued before cast |

##### 6.5.5 — `|Remove`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.19 | `Me.Buff(spellToCast).ID() != 0` (buff active) | `/echo Removing Buff: ...` + `/removebuff` issued; `goto continue` |
| 6.5.20 | `Me.Song(spellToCast).ID() != 0` (song active) | `/removebuff` issued; `goto continue` |
| 6.5.21 | Neither buff nor song active | No remove issued; still `goto continue` (doesn't fall to group loop) |

##### 6.5.6 — Global mana bail (inside elseif chain)

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.22 | `p2 == ''`; `Spell.Mana() > Me.CurrentMana()` | `goto continue`; no cast |
| 6.5.23 | `p2 == 'begfor'`; `Spell.Mana() > Me.CurrentMana()` | Mana bail skipped; `begfor` branch fires instead |
| 6.5.24 | `Spell.Mana() == 0` (non-mana spell) | Mana bail not triggered; falls through to Aura/Once/etc. |

##### 6.5.7 — `|Aura`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.25 | Aura slot 1 already matches aura name | `checkAura()` returns early; no cast |
| 6.5.26 | Aura not present; class is WAR (DISC_AURA class); endurance > 500 | `/disc "spellName"` issued; delay+wait for cast |
| 6.5.27 | Aura not present; class is CLR (non-disc); aura slots 1+2 checked | `castWhat('CheckAura')` issued |
| 6.5.28 | ENC with two active auras; second slot matches | `checkAura()` returns early |
| 6.5.29 | MAG; pet buff scan finds `TempAura` match | `checkAura()` returns early; no cast |

##### 6.5.8 — `|Once`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.30 | `buffOnce()` returns `CAST_SUCCESS` | `buffsArray[i]` set to `spellName\|0`; echo `'Buffing Once with ...'`; `goto continue` |
| 6.5.31 | `buffOnce()` returns non-SUCCESS (resist, etc.) | `buffsArray[i]` unchanged; `goto continue` |
| 6.5.32 | `Me.Invis()` when `buffOnce()` called | `buffOnce()` returns false immediately |

##### 6.5.9 — `|summon` stub

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.33 | `p2:lower() == 'summon'` | Printf stub printed; `goto continue`; no cast |

##### 6.5.10 — `|mgb` / `|DualMgb` stub

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.34 | `p2 == 'mgb'`; `Buff(buffToCheck).ID() == 0` | `castWhat` called on `Me.ID` with `'buffs-nomem'`; `goto continue` |
| 6.5.35 | `p2 == 'DualMgb'`; buff already active | No cast; `goto continue` |
| 6.5.36 | `p2:lower() == 'dualmgb'` (raw lowercase) | Handled same as `'DualMgb'` |

##### 6.5.11 — `|begfor`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.37 | `timers_i[0] > os.clock()` (timer active) | Skip beg logic; `goto continue` |
| 6.5.38 | `p5 == 'BEGFORITEMS'`; `FindItemCount < p3` | `/bc KABeg for <name> BEGFORITEMS 0`; `timers_i[0] = os.clock() + 900` |
| 6.5.39 | `p5 == 'BEGFORITEMS'`; item count already sufficient | No broadcast; `goto continue` |
| 6.5.40 | `p5 == 'BEGFORBUFFS'`; `Buff(spellToCast).ID() == 0` | `/bc KABeg for <name> BEGFORBUFFS 0`; timer set |
| 6.5.41 | `p5 == 'BEGFORBUFFS'`; buff already present | No broadcast |
| 6.5.42 | `p5` is invalid (not BEGFORITEMS or BEGFORBUFFS) | Echo invalid option; `buffsArray[i] = 'NULL'` |

##### 6.5.12 — `|command:`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.43 | `spellToCast` contains `'command:'`; target exists | `castWhat` called with `Target.ID`; `goto continue` |
| 6.5.44 | `spellToCast` contains `'command:'`; no target | `castWhat` called with `Me.ID` fallback |

##### 6.5.13 — `Buffs.checkBegforBuffs()`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.45 | `Me.Invis()` at entry | Returns immediately |
| 6.5.46 | `kaBegForList == ''` | Returns immediately |
| 6.5.47 | Single entry `'BEGFORBUFFS:PlayerA:2'`; buffToCast is single-target spell | `castWhat(buffToCast, Spawn('PC PlayerA').ID(), 'Buffs')` called |
| 6.5.48 | Cast returns `CAST_SUCCESS` | `removeFromBegList()` called; entry removed from list |
| 6.5.49 | Cast returns `CAST_RECOVER` | Same as SUCCESS — entry removed |
| 6.5.50 | Cast returns `CAST_CANCELLED` | Loop breaks immediately |
| 6.5.51 | Cast returns other result | `idx` incremented; next entry tried |
| 6.5.52 | Entry spell type resolves to `'self'` | `removeFromBegList(entry, 'self')` without casting |
| 6.5.53 | List becomes empty after removal | `kaBegActive = false` |

##### 6.5.14 — `removeFromBegList()`

| # | Scenario | Expected |
|---|----------|----------|
| 6.5.54 | Single entry removed; `spellType == 'single'` | No dedup loop; list becomes empty |
| 6.5.55 | `part1 == 'BEGFORAEITEMS'`; two entries share part1+part3 | Both entries removed (AE dedup) |
| 6.5.56 | `spellType == 'self'`; duplicate entries with same part1+part3 | All matching entries removed |
| 6.5.57 | `spellType == 'single'`; duplicate of same entry string | All duplicate entries removed |

---

### Section 6.6 — `CheckPetBuffs` + `CheckBegforPetBuffs`

#### 6.6.1 — `checkPetBuffs` guards

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.1 | No pet summoned | `Me.Pet.ID() == 0` | Returns immediately; no iteration |
| 6.6.2 | `pet.on == false` | Pet exists; `state.pet.on = false` | Returns immediately |
| 6.6.3 | `petBuffsOn == false` | Pet exists; `state.buffs.petBuffsOn = false` | Returns immediately |
| 6.6.4 | `combatStart == true` | `state.session.combatStart = true` | Returns immediately |
| 6.6.5 | `pulling == true` | `state.combat.pulling = true` | Returns immediately |
| 6.6.6 | Timer not expired | `state.timers.petBuffCheck = os.clock() + 30` | Returns immediately; no cast |
| 6.6.7 | Invis active | `Me.Invis() == true` | Returns immediately |
| 6.6.8 | All guards pass | Pet present; all flags clear; timer expired | Enters loop; sets `petBuffCheck = os.clock() + 60` |

#### 6.6.2 — NULL entry skipping

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.9 | Entry is `NULL` | `petBuffsArray[1] = 'NULL'` | Entry skipped via `goto petcontinue`; no cast |
| 6.6.10 | Entry is `null` (lowercase) | `petBuffsArray[1] = 'null'` | Same skip behavior via `.upper()` check |

#### 6.6.3 — Aggro bail

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.11 | Aggro detected mid-loop | `aggroTargetID` becomes non-zero after first iteration | Returns from function immediately |

#### 6.6.4 — Spell/AA path (book or AltAbility)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.12 | Spell in book; buff already on pet | `Me.PetBuff(j).Name` partial-matches `pTempBuff` | `foundPetBuff = true`; cast skipped |
| 6.6.13 | Spell in book; buff not on pet | No PetBuff slot matches | `castWhat(part1, Pet.ID, 'Pet-nomem')` called |
| 6.6.14 | CAST_SUCCESS | `castWhat` returns `'CAST_SUCCESS'` | `/echo Buffing <petName>, my pet, with <spell>` |
| 6.6.15 | CAST_COMPONENTS | `castWhat` returns `'CAST_COMPONENTS'` | `/echo` missing-components message; `petBuffsArray[i] = 'NULL'` |
| 6.6.16 | AltAbility entry | `Me.AltAbility(part1).ID()` non-zero | Same 50-slot scan and cast path as book spell |
| 6.6.17 | Spell with ` Rk. II` suffix | `part1 = 'Example Rk. II'` | `pTempBuff` stripped to `'Example'`; slot scan uses stripped name |

#### 6.6.5 — Item path (FindItem)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.18 | Item found; buff already on pet | Slot scan matches `pTempBuff` | Cast skipped |
| 6.6.19 | Item found; buff not on pet | No slot match | `castWhat(part1, Pet.ID, 'Pet')` called |
| 6.6.20 | CAST_SUCCESS (item) | `castWhat` returns `'CAST_SUCCESS'` | `/echo Buffing <petName>, my pet, with (<part3>)` |
| 6.6.21 | CAST_COMPONENTS (item) | `castWhat` returns `'CAST_COMPONENTS'` | Entry nulled; echo emitted |

#### 6.6.6 — `|dual` tag

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.22 | Entry has `dual` as part2 | `entry = 'CastSpell\|dual\|CheckBuff'` | `pTempBuff` derived from `part3` (`CheckBuff`); `part1` used to cast |
| 6.6.23 | No dual tag | `entry = 'MySpell\|something\|foo'` | `part3 = part1`; buff check and cast name are identical |

#### 6.6.7 — `pettoys|begfor` path

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.24 | Timer expired; pet present | `entry = 'pettoys\|begfor'`; `_petBegTimers[i] <= os.clock()` | `/bc PetToysPlease <petName>` sent; `_petBegTimers[i] = os.clock() + 90`; `kaPetBegActive = true` |
| 6.6.25 | Timer not yet expired | `_petBegTimers[i] > os.clock()` | Broadcast suppressed |

#### 6.6.8 — Post-loop: shrink + target clear

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.26 | Pet too tall; shrink enabled | `Pet.Height() > 1.35`; `shrinkOn = true`; `shrinkSpell` set | `castWhat(shrinkSpell, Pet.ID, 'Pet')` called |
| 6.6.27 | Pet height OK | `Pet.Height() <= 1.35` | No shrink cast |
| 6.6.28 | `shrinkOn = false` | Height > 1.35 but flag off | No shrink cast |
| 6.6.29 | Target is pet after loop | `Target.ID() == Me.Pet.ID()` | `/squelch /target clear` sent |
| 6.6.30 | Target is not pet | `Target.ID()` differs | Target not cleared |

#### 6.6.9 — `checkBegforPetBuffs` guards

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.31 | `toysOn == false` | `state.pet.toysOn = false` | Returns immediately |
| 6.6.32 | Me.Invis | `Me.Invis() == true` | Returns immediately |
| 6.6.33 | `kaBegForPetList == ''` | Empty list | Returns immediately |

#### 6.6.10 — `checkBegforPetBuffs` list processing

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.34 | Entry `'group'` | `kaBegForPetList = 'group'` | Iterates members 1–5; casts toy on each pet-class member with active pet |
| 6.6.35 | Group entry: member not pet class | `cls = 'war'` | Member skipped |
| 6.6.36 | Group entry: member has no pet | `Pet.ID() == 0` | Member skipped |
| 6.6.37 | Individual entry; pet found | `entry = 'Fluffy'`; `Spawn('pet Fluffy').ID() ~= 0` | `/echo Giving pet toys to (Fluffy).`; `castWhat` called |
| 6.6.38 | Individual entry; pet not found | `Spawn('pet Fluffy').ID() == 0` | No cast; advances index |
| 6.6.39 | CAST_SUCCESS | `castWhat` returns `'CAST_SUCCESS'` | Entry removed from `kaBegForPetList` |
| 6.6.40 | List empty after removal | Only one entry; CAST_SUCCESS | `kaPetBegActive = false`; loop breaks |
| 6.6.41 | CAST_CANCELLED | `castWhat` returns `'CAST_CANCELLED'` | Loop breaks immediately |
| 6.6.42 | Other cast result | `castWhat` returns `'CAST_FIZZLE'` | Index advanced; next entry processed |
| 6.6.43 | Invis becomes true mid-loop | `Me.Invis()` mid-iteration during group pass | Inner loop breaks; outer loop breaks |

#### 6.6.11 — Main loop wiring

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.6.44 | `pet.on == false` | `state.pet.on = false` | `checkPetBuffs` not called from main loop |
| 6.6.45 | `pet.toysOn == false` | `state.pet.toysOn = false` | `checkBegforPetBuffs` not called |
| 6.6.46 | `kaPetBegActive == false` | `toysOn = true`; `kaPetBegActive = false` | `checkBegforPetBuffs` not called |

---

## Section 6.7 — Wire into main loop + `/buffgroup` + `/tbmanager` + `castBuffsSpellCheck`

### 6.7.1 — init.lua main loop: writeBuffs OOC guard

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.1 | OOC + no DanNet → writeBuffs called | `combatStart=false`; `danNetOn=false` | `writeBuffs`, `writeBuffsPet`, `writeBuffsMerc` all execute |
| 6.7.2 | In combat → writeBuffs skipped | `combatStart=true`; `danNetOn=false` | None of the three write calls execute |
| 6.7.3 | DanNet active → writeBuffs skipped | `combatStart=false`; `danNetOn=true` | None of the three write calls execute |
| 6.7.4 | Both combat + DanNet → writeBuffs skipped | `combatStart=true`; `danNetOn=true` | None of the three write calls execute |

### 6.7.2 — init.lua main loop: checkBuffs buffsOn guard

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.5 | `buffsOn=true` → checkBuffs called | `buffsOn=true`; `forceBuffs=false` | `Buffs.checkBuffs(false)` called; `forceBuffs` set to `false` after |
| 6.7.6 | `buffsOn=false` → checkBuffs skipped | `buffsOn=false` | `checkBuffs` never called |
| 6.7.7 | `forceBuffs=true` passed through | `buffsOn=true`; `forceBuffs=true` | `checkBuffs(true)` called; `forceBuffs` reset to `false` |
| 6.7.8 | forceBuffs reset after one cycle | `forceBuffs=true`; loop runs twice | Second iteration calls `checkBuffs(false)` |

### 6.7.3 — init.lua main loop: checkBegforBuffs guard

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.9 | `kaBegActive=true` → checkBegforBuffs called | `buffs.kaBegActive=true` | `Buffs.checkBegforBuffs()` called |
| 6.7.10 | `kaBegActive=false` → not called | `buffs.kaBegActive=false` | `checkBegforBuffs` not called |
| 6.7.11 | Call order: checkBegforBuffs after checkBuffs | Verify execution order | checkBuffs executes before checkBegforBuffs in same loop tick |

### 6.7.4 — `/buffgroup` bind

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.12 | `/buffgroup` sets forceBuffs | Fire `/buffgroup` | `state.buffs.forceBuffs == true` |
| 6.7.13 | `/buffgroup` resets iniNext | Fire `/buffgroup` | `state.timers.iniNext == 0` |
| 6.7.14 | `/buffgroup` calls checkBuffs(true) directly | Fire `/buffgroup` | `Buffs.checkBuffs(true)` called immediately (not deferred to main loop) |
| 6.7.15 | `/buffgroup` works with no active target | No target selected | No crash; buff cycle runs normally |

### 6.7.5 — `/tbmanager` bind — add

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.16 | Add to empty list | `extendedList=''`; `/tbmanager add Shield of Fate` | `extendedList == 'Shield of Fate'` |
| 6.7.17 | Add to existing list | `extendedList='SpellA'`; `/tbmanager add SpellB` | `extendedList == 'SpellA,SpellB'` |
| 6.7.18 | Add duplicate | `extendedList='SpellA'`; `/tbmanager add SpellA` | List unchanged; "already in" message printed |
| 6.7.19 | Add persists to INI | `/tbmanager add SpellA` | INI `[Buffs] ExtendedList` updated via `/ini` command |
| 6.7.20 | Add prints confirmation | `/tbmanager add SpellA` | Console prints "Added SpellA to Too-Buff list" |

### 6.7.6 — `/tbmanager` bind — remove

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.21 | Remove only entry | `extendedList='SpellA'`; `/tbmanager remove SpellA` | `extendedList == ''` |
| 6.7.22 | Remove from middle of list | `extendedList='A,B,C'`; `/tbmanager remove B` | `extendedList == 'A,C'` |
| 6.7.23 | Remove non-existent entry | `extendedList='SpellA'`; `/tbmanager remove SpellX` | List unchanged |
| 6.7.24 | Remove persists to INI | `/tbmanager remove SpellA` | INI `[Buffs] ExtendedList` updated |
| 6.7.25 | Remove prints confirmation | `/tbmanager remove SpellA` | Console prints "Removed SpellA from Too-Buff list" |

### 6.7.7 — `/tbmanager` bind — invalid usage

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.26 | No arguments | `/tbmanager` | Usage message printed; no crash |
| 6.7.27 | One argument only | `/tbmanager add` | Usage message printed |
| 6.7.28 | Unknown action | `/tbmanager set SpellA` | Usage message printed |

### 6.7.8 — `castBuffsSpellCheck` function

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.29 | Buff already on self → returns true | `Me.Buff('Shield of Fate').ID() ~= 0` | `castBuffsSpellCheck` returns `true` |
| 6.7.30 | Song already on self → returns true | `Me.Song('Aria of Asceticism').ID() ~= 0` | Returns `true` |
| 6.7.31 | Buff not active → returns false | Both `Me.Buff` and `Me.Song` return 0 | Returns `false` |
| 6.7.32 | Unknown spell name → returns false | `Me.Buff('Nonexistent').ID()` returns 0 | Returns `false` |

### 6.7.9 — `castWhat` buff stacking gate

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.33 | sentFrom='Buffs' + buff active → CAST_HASBUFF | `sentFrom='Buffs'`; buff already on self | `castWhat` returns `'CAST_HASBUFF'` without casting |
| 6.7.34 | sentFrom='buffs-nomem' + buff active → CAST_HASBUFF | `sentFrom='buffs-nomem'`; buff on self | Returns `'CAST_HASBUFF'` |
| 6.7.35 | sentFrom='Buffs' + buff not active → proceeds | Buff not active | `castWhat` continues to cast normally |
| 6.7.36 | sentFrom='dps' + buff active → not gated | `sentFrom='dps'` | Buff stacking check NOT applied; cast proceeds |
| 6.7.37 | sentFrom='SingleHeal' → not gated | `sentFrom='SingleHeal'` | Buff stacking check NOT applied |

### 6.7.10 — Invis guard bypass for buff sentFrom values

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.38 | `castSpell` + invis + sentFrom='Buffs' → proceeds | `Me.Invis()=true`; `sentFrom='Buffs'` | Cast NOT cancelled by invis guard |
| 6.7.39 | `castSpell` + invis + sentFrom='buffs-nomem' → proceeds | `Me.Invis()=true`; `sentFrom='buffs-nomem'` | Cast NOT cancelled |
| 6.7.40 | `castAA` + invis + sentFrom='Buffs' → proceeds | `Me.Invis()=true`; `sentFrom='Buffs'` | `castAA` NOT cancelled |
| 6.7.41 | `castDisc` + invis + sentFrom='Buffs' → proceeds | `Me.Invis()=true`; `sentFrom='Buffs'` | `castDisc` NOT cancelled |
| 6.7.42 | `castItem` + invis + sentFrom='Buffs' → proceeds | `Me.Invis()=true`; `sentFrom='Buffs'` | `castItem` NOT cancelled |
| 6.7.43 | `castMem` + invis + sentFrom='Buffs' → proceeds | `Me.Invis()=true`; `sentFrom='Buffs'` | `castMem` NOT cancelled |
| 6.7.44 | `castSpell` + invis + sentFrom='dps' → cancelled | `Me.Invis()=true`; `sentFrom='dps'` | Returns `CAST_CANCELLED` |

### 6.7.11 — Binds.register Buffs wiring

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 6.7.45 | Buffs passed to Binds.register | `Binds.register(State, Utils, Buffs)` in init.lua | `/buffgroup` can call `Buffs.checkBuffs` without nil error |
| 6.7.46 | onBuffGroup with buffsOn=false | `buffsOn=false`; fire `/buffgroup` | `checkBuffs(true)` still called directly; no crash |

---

## Section 7 — Movement & Pull (Milestone 7)

### Section 7.1 — Movement.init + INI wiring (Step 7.1)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.1.1 | Module loads cleanly | `/lua run kissassist-lua` | No errors; `Movement.init` called without crash |
| 7.1.2 | campRadius from INI | `[General] CampRadius=75` | `state.movement.campRadius == 75` |
| 7.1.3 | returnToCamp from INI | `[General] ReturnToCamp=1` | `state.movement.returnToCamp == true` |
| 7.1.4 | chaseAssist from INI | `[General] ChaseAssist=1` | `state.session.chaseAssist == true` |
| 7.1.5 | stickDist defaults | No INI key | `state.movement.stickDist == 13` |
| 7.1.6 | pullMoveUse from INI | `[Pull] PullMoveUse=nav` | `state.pull.moveUse == 'nav'` |
| 7.1.7 | faceMobOn / scatterOn | Both set to `1` in INI | `state.movement.faceMobOn == true`; `state.movement.scatterOn == true` |
| 7.1.8 | Combat.init accepts Movement | Start with any role | No error on Combat.init; `_movement` wired in combat.lua |

---

### Section 7.2 — Movement.doWeMove (Step 7.2)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.2.1 | Guard: dontMoveMe | `state.movement.dontMoveMe = true` | Returns immediately; no movement commands |
| 7.2.2 | Guard: chaseAssist | `state.session.chaseAssist = true` | Returns immediately |
| 7.2.3 | Guard: zone mismatch | `state.movement.campZone ~= Zone.ID()` | Returns immediately |
| 7.2.4 | Guard: combat + aggro | In combat; `aggroTargetID ~= ''` | Returns immediately (non-forced call) |
| 7.2.5 | Already in camp radius | Char within campRadius | Returns without moving; `checkOnReturn` logic runs if set |
| 7.2.6 | campRadiusExceed leash | `campRadiusExceed = 200`; char at 150u from camp | Does not trigger return (within leash) |
| 7.2.7 | los mode — moves to camp | `pullMoveUse = 'los'`; char outside campRadius | `/moveto loc campY campX` issued; char arrives at camp |
| 7.2.8 | nav mode — uses MQ2Nav | `pullMoveUse = 'nav'` | `/nav locyxz campY campX campZ` issued; `Navigation.Active` polled |
| 7.2.9 | checkOnReturn set on arrival | Puller role; arrives at camp | `state.movement.checkOnReturn = true` |
| 7.2.10 | Walk/run toggle | Char within `stickDist+5` of camp | `/squelch /walk` issued; `/squelch /run` on departure |

---

### Section 7.3 — Movement.doWeChase + stuck + zAxisCheck (Step 7.3)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.3.1 | Guard: chaseAssist off | `chaseAssist = false` | Returns immediately |
| 7.3.2 | Guard: whoToChase not in zone | Target not found | Returns immediately |
| 7.3.3 | Guard: iAmDead | `Me.Hovering == true` | Returns immediately |
| 7.3.4 | Chase: within stop distance | Char within `chaseOnValue * meleeDistance` of target | `/squelch /moveto loc stop` issued |
| 7.3.5 | Chase: moves toward target | Char far from whoToChase | `/moveto loc Y X` toward target |
| 7.3.6 | scatterOn displacement | `scatterOn = true` | Aim point offset by `scatterDistance`; chars spread out |
| 7.3.7 | stuck — frees from geometry | `Me.X/Y` unchanged for stuck threshold | `/keypress back hold` → strafe issued |
| 7.3.8 | zAxisCheck — levi correction | `Me.Z - campZ >= 3.1`; not FeetWet | `CMD_MOVE_DOWN` held until Z gap ≤ 3.1 |
| 7.3.9 | zAxisCheck — returns true | Z gap > `campRadius + 10` | Returns `true`; `doWeMove` skips move |

---

### Section 7.4 — Movement.checkStick + event completions + loop wiring (Step 7.4)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.4.1 | No target — no stick | `state.combat.myTargetID = 0` | Returns immediately |
| 7.4.2 | Mob within range — stick issued | Mob within `meleeDistance` | `/stick id <mobID>` issued |
| 7.4.3 | stickHow = 'd' | `state.movement.dStickHow = 'd'` | `/stick id X behind` issued |
| 7.4.4 | stickHow = 'mp' | `state.movement.dStickHow = 'mp'` | `/stick id X moveback` issued |
| 7.4.5 | Nav close-gap | `pullMoveUse = 'nav'`; mob beyond MaxRangeTo | `/nav id X dist=N` until in range |
| 7.4.6 | useAttack=1 — attack on | Not in combat; `useAttack = 1` | `/attack on` issued |
| 7.4.7 | CantHit event | Game text "You cannot see your target" fires | `state.movement.cantHit = true`; `/attack off` |
| 7.4.8 | TooClose event | Game text "You are too close" fires | `state.movement.toClose = true`; back keypress |
| 7.4.9 | TooFar event | Game text fires | `state.pull.tooFar = true`; `doWeMove(1, 'tooFar')` called |
| 7.4.10 | Main loop: doWeMove wired | `returnToCamp = true`; char outside camp | `doWeMove(0, 'mainloop')` called each tick |
| 7.4.11 | Main loop: doWeChase wired | `chaseAssist = true` | `doWeChase()` called each tick |

---

### Section 7.5 — Pull.init + INI wiring (Step 7.5)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.5.1 | Module loads cleanly | `/lua run kissassist-lua` puller role | No errors; `Pull.init` called |
| 7.5.2 | pullOn from INI | `[Pull] PullOn=1` | `state.pull.on == true` |
| 7.5.3 | pullWith from INI | `[Pull] PullWith=Ranged` | `state.pull.withAlt == 'Ranged'` |
| 7.5.4 | maxRadius from INI | `[Pull] MaxRadius=300` | `state.pull.maxRadius == 300` |
| 7.5.5 | Arc width derivation | `PullArcWidth=90`; no LSide/RSide | `lSide = -45`; `rSide = 45` |
| 7.5.6 | chainPull integer | `[Pull] ChainPull=1` | `state.pull.chainPull == 1` (integer, not bool) |
| 7.5.7 | PullAdvanced waypoints | `PullWpCount=3`; three PullLocX/Y/Z entries | `state.pull.pullLocX[1..3]` populated |
| 7.5.8 | waypointZRange mirrors MaxZRange | `MaxZRange=50` | `state.pull.waypointZRange == 50` |

---

### Section 7.6 — Pull.pullValidate (Step 7.6)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.6.1 | Non-NPC spawn | Target is a PC or object | Returns `false` |
| 7.6.2 | Non-targetable | `Spawn.Targetable == false` | Returns `false` |
| 7.6.3 | Name in ignore list | Mob name in `mobsToIgnore` | Returns `false` |
| 7.6.4 | Name not in allowed list | `mobsToPullFirst ~= 'all'`; name not in list | Returns `false` |
| 7.6.5 | Level below pullMin | `pullMin=50`; mob level 40 | Returns `false` |
| 7.6.6 | Level above pullMax | `pullMax=60`; mob level 65 | Returns `false` |
| 7.6.7 | LOS mode — no LOS | `moveUse='los'`; mob behind wall | Returns `false` |
| 7.6.8 | Nav mode — no path | `moveUse='nav'`; `Navigation.PathLength <= 0` | Returns `false` |
| 7.6.9 | Pull arc — outside | `pullArcWidth=90`; mob heading outside arc | Returns `false` |
| 7.6.10 | HP% already in combat | `Spawn.PctHPs <= 99`; mob within melee range | Returns `false` |
| 7.6.11 | HP% recheck — server lag | `flag > 0`; mob dist ≤ 360; HP% still > 99 after target+wait | Returns `true` |
| 7.6.12 | Eye of Zomm | Name contains "Eye of"; PC with matching name nearby | Returns `false` |
| 7.6.13 | Named mob — no flag | Named mob; `flag = 0` | Returns `false` |
| 7.6.14 | Valid mob — all checks pass | NPC, targetable, in range, LOS, level OK, HP 100% | Returns `true` |

---

### Section 7.7 — Pull.findMobToPull (Step 7.7)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.7.1 | Guard: pulling flag | `state.pull.pulling = true` | Returns `0` immediately |
| 7.7.2 | Guard: combatStart | `state.combat.combatStart = true` | Returns `0` immediately |
| 7.7.3 | Guard: zone mismatch | `campZone ~= Zone.ID()` | Returns `0` immediately |
| 7.7.4 | Guard: rez sickness | Rez Sickness buff active | Returns `0` immediately |
| 7.7.5 | Guard: aggroTargetID set | `aggroTargetID ~= ''` | Returns `0` immediately |
| 7.7.6 | advpath deferred | `moveUse = 'advpath'` | Prints deferred message; returns `0` |
| 7.7.7 | No mobs in range | `SpawnCount = 0` for search filter | Returns `0`; `state.pull.mob = 0` |
| 7.7.8 | Valid mob found — LOS mode | NPC in range; passes `pullValidate` | `state.pull.mob = <spawnID>`; returns `1` |
| 7.7.9 | Valid mob found — NAV mode | `moveUse='nav'`; mob has nav path | Picks mob with shortest `Navigation.PathLength` |
| 7.7.10 | Priority list respected | `mobsToPullFirst = 'Goblin'`; Goblin and Orc in range | `state.pull.mob` = Goblin ID |
| 7.7.11 | Progressive radius — 3 attempts | Radius subdivided until SpawnCount fits `modCheck` | Outer loop runs up to 3 passes |
| 7.7.12 | chainPull guard | `chainPull=1`; last pulled mob still outside melee | Returns `0` (wait for mob to arrive) |
| 7.7.13 | lastMobPullID set | Valid mob found | `state.pull.lastMobPullID = mob ID` |

---

## Section 7.8 — Pull.pullCheck + executePull + bind completions (Step 7.8)

### 7.8.1 — Pull.pullCheck guards

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.1.1 | `pull.hold = true` | Set `state.pull.hold = true`; call `pullCheck()` | Returns immediately; no targeting or movement |
| 7.8.1.2 | `dps.paused = true` | Set `state.dps.paused = true` | Returns immediately |
| 7.8.1.3 | Rez sickness — Resurrection | `Me.Buff('Resurrection Sickness').ID() > 0` | Returns immediately |
| 7.8.1.4 | Rez sickness — Revival | `Me.Buff('Revival Sickness').ID() > 0` | Returns immediately |
| 7.8.1.5 | Zone mismatch | `state.movement.campZone` ≠ `Zone.ID()` | Returns immediately |
| 7.8.1.6 | Me.Invis | `Me.Invis() == true` | Returns immediately |
| 7.8.1.7 | chainPull==2 reset | Set `state.pull.chainPull = 2`; call `pullCheck()` | `chainPull` reset to `1` before guards run |
| 7.8.1.8 | pullOnReturn + checkOnReturn | Both flags true; call `pullCheck()` | `checkOnReturn` set to `false` |

### 7.8.2 — No-mob path (failCounter + hunter return)

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.2.1 | failCounter increments | `state.pull.mob = 0`; call `pullCheck()` | `state.cast.failCounter` incremented by 1 |
| 7.8.2.2 | failCounter below failMax | `failCounter = 1`, `failMax = 3` | No hunter-return or pullWait triggered |
| 7.8.2.3 | failCounter reaches failMax | `failCounter = failMax - 1`; call `pullCheck()` | `failCounter` reset to 0 |
| 7.8.2.4 | Hunter role + far from camp | `role = 'hunter'`; `failMax` reached; camp dist > 15 | `doWeMove(1, 'pullcheck')` called; "Returning to camp" printed |
| 7.8.2.5 | Hunter role + stayPut | `role = 'hunter'`; `stayPut = true` | "Waiting here for respawn" printed; `doWeMove` not called |
| 7.8.2.6 | Hunter near camp | `role = 'hunter'`; camp dist ≤ 15 | `doWeMove` not called |
| 7.8.2.7 | Non-hunter role | `role = 'puller'`; `failMax` reached | No `doWeMove`; only failCounter reset |
| 7.8.2.8 | pullWait > 0, no aggro | `state.pull.pullWait = 5` | Prints "Waiting 5 seconds…"; `mq.delay(5000)` called |
| 7.8.2.9 | pullWait ignored with aggro | `pullWait = 5`; `aggroTargetID ~= ''` | pullWait delay skipped |

### 7.8.3 — Target acquisition + advpath guard

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.3.1 | los mode — mob in range | `moveUse = 'los'`; mob dist ≤ 360 | `/target id <mob>` issued; delay until `Target.ID == pullMob` |
| 7.8.3.2 | nav mode — mob has LOS | `moveUse = 'nav'`; mob has LOS | `/target id <mob>` issued |
| 7.8.3.3 | los mode — mob out of range, no LOS | Mob dist > 360, no LOS | `/target` not issued |
| 7.8.3.4 | advpath guard | `moveUse = 'advpath'` | Prints deferred message; `pulling` not set; returns |

### 7.8.4 — validateTarget + camp-distance gate

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.4.1 | validateTarget fails | Mob is a corpse or badType | `target clear`; `pulling = false`; returns |
| 7.8.4.2 | PC near mob while pulling | Non-group PC within 30 units of mob | `validateTarget` returns false; pull aborted |
| 7.8.4.3 | Mob level below pullMin | `state.pull.min = 50`; mob level = 40 | `validateTarget` returns false |
| 7.8.4.4 | Mob level above pullMax | `state.pull.max = 60`; mob level = 65 | `validateTarget` returns false |
| 7.8.4.5 | Mob too far from camp | Mob camp dist > `maxRadius`; los/nav mode | `target clear`; `pulling = false`; returns |
| 7.8.4.6 | Mob at camp edge — valid | Mob camp dist == `maxRadius - 1` | Pull proceeds to announce + executePull |

### 7.8.5 — Pull announce + executePull entry

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.5.1 | Announce printed | Valid mob; all gates pass | `PULLING-> <name> <- ID:<n> at <n> feet.` printed |
| 7.8.5.2 | myTargetID/Name set | Valid mob | `state.combat.myTargetID = pullMob`; `myTargetName = mobName` |
| 7.8.5.3 | pulling flag set | Valid mob enters executePull | `state.pull.pulling = true` while executing |
| 7.8.5.4 | pulling flag cleared on exit | executePull returns | `state.pull.pulling = false` |

### 7.8.6 — executePull — movement and abort conditions

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.6.1 | Early aggro break | `aggroTargetID` set by event during loop | `pulled = true`; stopMoving called; loop exits |
| 7.8.6.2 | Mobs-in-camp abort | `aggroTargetID ~= ''` + `chainPull==0` + inside campRadius | "mobs in camp" printed; pullReset called |
| 7.8.6.3 | Mob timeout | `os.clock() > pullTimer` | `returnStat = 'btcr'`; loop exits |
| 7.8.6.4 | Mob too far from camp | Mob camp dist3D > maxRadius + range | `pullStatusFlag = 4`; loop exits |
| 7.8.6.5 | Stuck detection | Me.X/Y unchanged for 2+ iterations | `_movement.stuck('pull')` called |
| 7.8.6.6 | Stuck abort | Stuck for 7+ iterations, no aggro | "I am stuck" printed; stopMoving; returnStat='btcr' |
| 7.8.6.7 | PullDist creep — no LOS | 7+ attempts; dist ≤ pullDist, no LOS | `pullDist *= 0.6` |
| 7.8.6.8 | PullDist creep — moving mob | ≥3 attempts; mob speed > 25; wasInRange | `pullDist *= 0.6`; `wasInRange = false` |
| 7.8.6.9 | BTC + no LOS | `returnStat = 'btcr'`; mob has no LOS | Loop exits without dispatching |
| 7.8.6.10 | Return to camp after pull | `returnToCamp = true`; `pulled = true` | `doWeMove(1, 'pull')` called |
| 7.8.6.11 | BTC return to camp | `returnStat = 'btcr'`; `pullOnReturn = false` | `doWeMove(1, 'pullcheck')` called |

### 7.8.7 — Pull method dispatch

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.7.1 | Melee dispatch | `withAlt = 'Melee'`; mob in range | `/moveto id <mob> mdist 15`; `/attack on`; then `/attack off` + clear target |
| 7.8.7.2 | Ranged dispatch | `withAlt = 'Ranged'`; mob dist ≥ 30, LOS | `/range` issued; wait for aggroTargetID |
| 7.8.7.3 | Pet dispatch | `withAlt = 'Pet'` | `/pet follow`; `/pet attack`; `/pet back off` on exit |
| 7.8.7.4 | Cast dispatch (spell/AA/item) | `withAlt = 'Bolt of Fire'` | `castWhat('Bolt of Fire', mobID, 'Pull', 0, 0)` called |
| 7.8.7.5 | pulled = true after melee aggro | Melee pull; `aggroTargetID` set during attack | `state.pull.pulled = true` |
| 7.8.7.6 | Final validateTarget before dispatch | Mob dies between approach and dispatch | Abort; returnStat='btcr' |

### 7.8.8 — Bind completions

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.8.1 | `/trackmedown TankName` | Issue command | `movement.whoToChase = 'TankName'`; `session.chaseAssist = true`; confirmation printed |
| 7.8.8.2 | `/trackmedown` (no arg) | Issue command | `chaseAssist = false`; `whoToChase = ''`; "Chase assist disabled" printed |
| 7.8.8.3 | `/SetPullArc 90` | Issue command | `pullArcWidth = 90`; `lSide = -45`; `rSide = 45`; INI updated |
| 7.8.8.4 | `/SetPullArc 0` | Issue command | `pullArcWidth = 0`; `lSide = 0`; `rSide = 0`; INI updated |
| 7.8.8.5 | `/setpullranking 3` | Issue command | `state.pull.ranking = 3`; INI updated; confirmation printed |
| 7.8.8.6 | `/addpull Goblin` | Issue command (mobsToPullFirst = 'all') | `mobsToPullFirst = 'Goblin'`; INI updated |
| 7.8.8.7 | `/addpull Orc` | Issue command (existing list) | `mobsToPullFirst` gets `\|Orc` appended; INI updated |
| 7.8.8.8 | `/addignore SpectralKnight` | Issue command | `mobsToIgnore` gets name appended; INI updated |
| 7.8.8.9 | `/addpull` (no arg) | Issue command with no argument | Usage hint printed; state unchanged |

### 7.8.9 — Main loop wiring

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 7.8.9.1 | Non-puller role skips pull block | `role = 'assist'` | `findMobToPull` and `pullCheck` never called |
| 7.8.9.2 | Puller role + hold | `role = 'puller'`; `pull.hold = true` | Loop block enters but `pullCheck` not called |
| 7.8.9.3 | Puller role + no mob | `role = 'puller'`; `pull.mob = 0` | `findMobToPull(1,1,0)` called first |
| 7.8.9.4 | mob reset each tick | After `pullCheck()` returns | `State.pull.mob = 0` |

---

## Section 7 — Integration Smoke Test

Run after all individual tests pass to verify modules interact correctly.

| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| 7.1 | Full startup to casting | Start → `/memmyspells` → `/kisscast <MemedSpell>` | Spell cast; returns `CAST_SUCCESS` |
| 7.2 | Cast event round-trip | Start with `/debug cast on` → cast a spell that gets interrupted → observe | `castReturn` set to `CAST_INTERRUPTED`; castSpell returns that value |
| 7.3 | Bind + cast interaction | `/burn on doburn` (NPC targeted) → observe `burnID` set | `state.combat.burnCalled = true`; `state.combat.burnID = <mobID>` |
| 7.4 | Camp set + zone | `/makecamphere` → zone away → zone back to same zone | Camp location restored; `returnToCamp = true` |
| 7.5 | Debug round-trip | `/debug all on` → cast a failing spell → observe debug output | All cast debug lines printed in chat |
| 7.6 | Clean shutdown | Any active test → `/lua stop kissassist-lua` | Prints stopped message; all binds and events unregistered; no further event callbacks fire |

---

## Known Deferred / Out of Scope for M1–M6 (Steps 4.1–4.8, 5.1–5.6, 6.1)

The following are **stubs** — they respond but don't have full logic yet. Do not test for full behavior:

| Area | Deferred to |
|------|-------------|
| `Combat.mobRadar` — `'pull'` mode | M5 Step 5.x (pull.lua wires it) |
| `namedWatchList` population from INI | M5 (needs KissAssist_Info.ini loader; M4 complete without it) |
| `autoBurnTimer` auto-burn trigger | N/A — not present in kissassist.mac source; auto-burn uses `/kaburn` bind only |
| `validateTarget` pull-specific checks (PullValid, PCNear, BadLevel) | ✅ Step 7.8 |
| BroadCast burn/add/tank-announce | M9 (cross-char comms) |
| `CombatTargetCheckRaid` | M9 (raid/cross-char comms; M4 complete without it) |
| CheckForCombat SkipCombat==1 healer loop | ✅ Step 5.6 |
| CheckForCombat MezCheck call | M4 Step 4.x (mez module) |
| CheckForCombat DoWeChase / DoWeMove / LOSBeforeCombat | ✅ Step 7.4 |
| CheckForCombat tank EnduranceCheck | M6 (buffs module) |
| SwitchMA on offtank / MA-dead path | M9 (DanNet/EQBC) |
| fight: CheckCures / CheckHealth during combat | ✅ Step 5.6 |
| fight: CheckStick / ZAxisCheck (melee positioning) | ✅ Step 7.4 |
| fight: CastMana / mana-sit logic | ✅ Step 5.3 (`Heal.doWeMed` implemented; wired into main loop at Step 5.6) |
| fight: MercsDoWhat | M6 (merc module) |
| fight: MezCheck / AECheck | M5 Step 5.x (mez sub-step) |
| fight: AggroCheck in inner loop | ✅ Step 4.8 |
| fight: WriteDebuffs / DebuffStuff | ✅ Step 4.8 (`doDebuffStuff`) |
| fight: DoBardStuff | M8 (bard module) |
| fight: ChainPullNextMob puller path | ✅ Step 7.7 (findMobToPull chainPull guard) |
| fight: AutoFireOn branches | M7 or later |
| fight: FaceMobOn | ✅ Step 7.4 (movement.checkStick + doWeChase) |
| fight: BreakMez for pettank | M6 (pet module) |
| fight: `beforeAttack` ConOn condition evaluation | M10 (conditions module) |
| fight: `combatPet` Summon Companion AA cast | M6 (pet/cast module) |
| combatReset: DPS meter output | M9 (MQ2DPSAdv) |
| combatReset: loot after kill | M8 (loot module) |
| combatReset: bard twist restart | M8 (bard module) |
| combatReset: MQ2Melee re-enable / stick release | ✅ Step 7.4 |
| combatReset: PetHold re-enable | M6 (pet module) |
| doBurn: condNo / abortFlag per-entry | M10 (conditions module) |
| combatCast: per-slot timers (ABTimer/DPSTimer/FDTimer) | M5 stretch |
| combatCast: DPSSkip lower HP bound | M5 stretch |
| combatCast: DPSOn==2 wait-for-cooldown mode | M5 stretch |
| combatCast: DAMod duration modifiers | M5 stretch |
| combatCast: Feign-death sequence (FDTimer) | M5 stretch |
| combatCast: DPSInterval for untiered spells | M5 stretch |
| combatCast: WeaveArray / CastWeave during cooldown | M8 (bard module) |
| combatCast: WriteDebuffs at entry | ✅ Step 4.8 (`doDebuffStuff` before combatCast) |
| combatCast: TargetSwitchingOn+IAmMA mid-rotation retarget | M5 stretch |
| mashButtons: ConOn/`\|cond` condition evaluation | M10 (conditions module) |
| mashButtons: TargetSwitchingOn+IAmMA full CombatTargetCheck path | M5 stretch |
| DPS/Buffs stacking checks in castWhat | M4 Step 4.6 done (DPS) / M6 (Buffs) |
| `state.session.heals` wire (castMem guard) | ✅ Step 5.2 |
| `/addimmune` bind | ✅ Step 5.1 |
| Heal.init — INI loading + state wiring | ✅ Step 5.1 |
| Healing/cures triggered by events | ✅ Steps 5.2–5.6 |
| Mez timer reset (MezBroke) | ✅ Step 5.4 (`checkCures` resets `state.mez.broke` at end) |
| CheckHealth | ✅ Step 5.2 |
| DoGroupHealStuff | ✅ Step 5.3 |
| doWeMed (medding sit/stand) | ✅ Step 5.3 (main loop wiring deferred to Step 5.6) |
| CheckCures / WriteDebuffs (healer) | ✅ Step 5.4 |
| RezCheck / RezWithCheck | ✅ Step 5.5 |
| Buffs.init — INI loading + state wiring | ✅ Step 6.1 |
| CheckBuffs guards + group-v + self dispatch | ✅ Step 6.3 |
| CheckBuffs single-target group iteration + class filters | ✅ Step 6.4 |
| CheckBuffs special action tags + CheckBegforBuffs | ✅ Step 6.5 |
| WriteBuffs / WriteBuffsPet / WriteBuffsMerc | ✅ Step 6.2 |
| CheckPetBuffs + CheckBegforPetBuffs | ✅ Step 6.6 |
| CastBuffsSpellCheck + /buffgroup + /tbmanager | ✅ Step 6.7 |
| Stuck-gem detection in castWhat | M6 |
| Condition evaluation (condNumber) | M10 |
| Stop-moving before cast | M7 |
| Bard: twist pause/resume in all cast functions | M8 |
| Cross-char comms (EQBC/DanNet stubs) | M9 |
| KT task events (KTTarget, KTHail, etc.) | M7 |
| GoM cast loop | M8 |

---

*Last updated: 2026-05-16. Reflects Milestones 1–7 complete. Sections 7.1–7.8 added (103 test cases total): 7.1 Movement.init INI wiring (8), 7.2 doWeMove guards + nav modes (10), 7.3 doWeChase + stuck + zAxisCheck (9), 7.4 checkStick + event completions + loop wiring (11), 7.5 Pull.init INI wiring (8), 7.6 Pull.pullValidate all 13 reject conditions (14), 7.7 Pull.findMobToPull guards + discovery (13), 7.8 Pull.pullCheck + executePull + bind completions (32). Known Deferred updated: DoWeMove/CheckStick/FaceMobOn/ChainPull/validateTarget pull checks all marked ✅.*
