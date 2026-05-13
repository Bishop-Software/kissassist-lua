# KissAssist Lua — In-Game Test Plan (Milestones 1–4)

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
| 2.5.11 | `/addimmune` | `>> AddMezImmune — M5` |
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

## Section 4 — Combat Core (Milestone 4 — Steps 4.1–4.7)

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

## Section 5 — Integration Smoke Test

Run after all individual tests pass to verify modules interact correctly.

| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| 5.1 | Full startup to casting | Start → `/memmyspells` → `/kisscast <MemedSpell>` | Spell cast; returns `CAST_SUCCESS` |
| 5.2 | Cast event round-trip | Start with `/debug cast on` → cast a spell that gets interrupted → observe | `castReturn` set to `CAST_INTERRUPTED`; castSpell returns that value |
| 5.3 | Bind + cast interaction | `/burn on doburn` (NPC targeted) → observe `burnID` set | `state.combat.burnCalled = true`; `state.combat.burnID = <mobID>` |
| 5.4 | Camp set + zone | `/makecamphere` → zone away → zone back to same zone | Camp location restored; `returnToCamp = true` |
| 5.5 | Debug round-trip | `/debug all on` → cast a failing spell → observe debug output | All cast debug lines printed in chat |
| 5.6 | Clean shutdown | Any active test → `/lua stop kissassist-lua` | Prints stopped message; all binds and events unregistered; no further event callbacks fire |

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

---

## Known Deferred / Out of Scope for M1–M4 (Steps 4.1–4.7)

The following are **stubs** — they respond but don't have full logic yet. Do not test for full behavior:

| Area | Deferred to |
|------|-------------|
| `Combat.mobRadar` — `'pull'` mode | M5 Step 5.x (pull.lua wires it) |
| `namedWatchList` population from INI | M4 (needs KissAssist_Info.ini loader) |
| `autoBurnTimer` auto-burn trigger | M4 Step 4.8 |
| `validateTarget` pull-specific checks (PullValid, PCNear, BadLevel) | M5 Step 5.x |
| BroadCast burn/add/tank-announce | M9 (cross-char comms) |
| `CombatTargetCheckRaid` | M4 Step 4.8 (raid context) |
| CheckForCombat SkipCombat==1 healer loop | M5 Step 5.x |
| CheckForCombat MezCheck call | M4 Step 4.x (mez module) |
| CheckForCombat DoWeChase / DoWeMove / LOSBeforeCombat | M7 (movement module) |
| CheckForCombat tank EnduranceCheck | M6 (buffs module) |
| SwitchMA on offtank / MA-dead path | M9 (DanNet/EQBC) |
| fight: CheckCures / CheckHealth during combat | M5 (healing module) |
| fight: CheckStick / ZAxisCheck (melee positioning) | M7 (movement module) |
| fight: CastMana / mana-sit logic | M5 |
| fight: MercsDoWhat | M6 (merc module) |
| fight: MezCheck / AECheck / AggroCheck in inner loop | M4.x / later |
| fight: WriteDebuffs / DebuffStuff | M4 Step 4.8 |
| fight: DoBardStuff | M8 (bard module) |
| fight: ChainPullNextMob puller path | M5 Step 5.x |
| fight: AutoFireOn branches | M7 or later |
| fight: FaceMobOn | M7 (movement module) |
| fight: BreakMez for pettank | M6 (pet module) |
| fight: `beforeAttack` ConOn condition evaluation | M10 (conditions module) |
| fight: `combatPet` Summon Companion AA cast | M6 (pet/cast module) |
| combatReset: DPS meter output | M9 (MQ2DPSAdv) |
| combatReset: loot after kill | M8 (loot module) |
| combatReset: bard twist restart | M8 (bard module) |
| combatReset: MQ2Melee re-enable / stick release | M7 (movement module) |
| combatReset: PetHold re-enable | M6 (pet module) |
| doBurn: condNo / abortFlag per-entry | M4 Step 4.8 |
| combatCast: per-slot timers (ABTimer/DPSTimer/FDTimer) | M4 Step 4.8 |
| combatCast: DPSSkip lower HP bound | M4 Step 4.8 |
| combatCast: DPSOn==2 wait-for-cooldown mode | M4 Step 4.8 |
| combatCast: DAMod duration modifiers | M4 Step 4.8 |
| combatCast: Feign-death sequence (FDTimer) | M4 Step 4.8 |
| combatCast: DPSInterval for untiered spells | M4 Step 4.8 |
| combatCast: WeaveArray / CastWeave during cooldown | M8 (bard module) |
| combatCast: WriteDebuffs at entry | M4 Step 4.8 |
| combatCast: TargetSwitchingOn+IAmMA mid-rotation retarget | M4 Step 4.8 |
| mashButtons: ConOn/`\|cond` condition evaluation | M10 (conditions module) |
| mashButtons: TargetSwitchingOn+IAmMA full CombatTargetCheck path | M4 Step 4.8 |
| DPS/Buffs stacking checks in castWhat | M4 Step 4.6 done (DPS) / M6 (Buffs) |
| `state.session.heals` wire (castMem guard) | M5 |
| Healing/cures triggered by events | M5 |
| Mez timer reset (MezBroke) | M5 |
| CheckBuffs / WriteBuffs | M6 |
| Stuck-gem detection in castWhat | M6 |
| Condition evaluation (condNumber) | M10 |
| Stop-moving before cast | M7 |
| Bard: twist pause/resume in all cast functions | M8 |
| Cross-char comms (EQBC/DanNet stubs) | M9 |
| KT task events (KTTarget, KTHail, etc.) | M7 |
| GoM cast loop | M8 |

---

*Last updated: 2026-05-13. Reflects Milestones 1–3 complete + M4 Steps 4.1–4.7 complete.*
