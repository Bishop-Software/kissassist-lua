# Milestone 17 — Named Watch List

**Branch:** `milestone-17`
**PR:** #17
**Goal:** Complete the `NamedWatch` / `namedWatchList` system — named-mob detection, burn triggering, zone-scoped `MobsToBurn` list, and `/addburn` bind.

---

## Mac Source Reference

| Mac location | Purpose |
|---|---|
| `Sub IsSpawnNamed` (mac:12872) | Returns true if a spawn ID is a named mob — via `Spawn.Named` TLO or Alert[5] (SpawnMaster mode) |
| `Sub NamedWatch` (mac:12886) | Two-path logic: IgnoreTarget=0 checks current target; IgnoreTarget=1 scans xtarhater for a nearby named when char is non-melee |
| `CombatReset` (mac:2234) | Resets `NamedCheck = 0` at end of each fight |
| `KissAssist_Info.ini [ZoneName] MobsToBurn` | Zone-scoped comma-delimited list of specific mob names to force-burn (used when BurnAllNamed==2) |
| Combat loop call (mac:576, 1177) | `NamedWatch ${SkipCombat}` — IgnoreTarget arg is 1 for healer/caster roles that skip melee |

### BurnAllNamed modes

| Value | Behavior |
|---|---|
| `0` | Off — NamedWatch never runs |
| `1` | Burn ANY mob where `Spawn.Named` is true (or Alert[5] in SpawnMaster mode) |
| `2` | Burn ONLY mobs whose name appears in the `MobsToBurn` list in `KissAssist_Info.ini` |

---

## What Is Already Done

- `state.combat.namedCheck` (bool) — declared in state.lua, reset in `combatReset()`
- `state.combat.burnOnNamed` (bool) — declared in state.lua, loaded from `Config.get('Burn','BurnAllNamed','0') == '1'`
- `state.combat.namedWatchList` (table) — declared in state.lua, always empty (TODO comment in combat.lua:356)
- Inline NamedWatch block in `Combat.fight()` (combat.lua:1103–1128) — IgnoreTarget=false path only, reads `Spawn.Named()` and iterates namedWatchList

## What Is Missing

- `burnAllNamed` as an integer (0/1/2) — current bool `burnOnNamed` can't model mode 2
- Loading `namedWatchList` from `KissAssist_Info.ini` under the current zone (the TODO)
- IgnoreTarget=true path — SkipCombat healer/caster scan of xtarhater for a named mob
- `/addburn` bind — add current target to `MobsToBurn` in `KissAssist_Info.ini`
- `/zoneinfo` MobsToBurn display (already prints MobsToPull, MezImmune; MobsToBurn is missing)
- UseSpawnMaster (`Alert[5]`) path in named detection (optional — needs a config key)

---

## Steps

### Step 17.1 — Promote `burnAllNamed` to integer in state.lua and combat.lua

**state.lua**

- Replace `burnOnNamed = false` with `burnAllNamed = 0` in `state.combat`
- Remove `namedWatchList = {}` — it will be populated in Pull (scratch that — it lives in combat, keep it)

**combat.lua — `Combat.init()`**

- Replace:

  ```lua
  _state.combat.burnOnNamed = Config.get('Burn', 'BurnAllNamed', '0') == '1'
  ```

  With:

  ```lua
  _state.combat.burnAllNamed = tonumber(Config.get('Burn', 'BurnAllNamed', '0')) or 0
  ```

- Load `namedWatchList` from `KissAssist_Info.ini` under the current zone name (same pattern as MobsToPull in pull.lua):

  ```lua
  local _infoFile = _state.session.infoFileName or ''
  local _zone     = _state.session.zoneName     or ''
  local rawBurn   = (_infoFile ~= '' and _zone ~= '')
      and (mq.TLO.Ini(_infoFile, _zone, 'MobsToBurn')() or '') or ''
  _state.combat.namedWatchList = {}
  for entry in (rawBurn .. ','):gmatch('([^,]+),') do
      local e = entry:match('^%s*(.-)%s*$')
      if e ~= '' and e ~= 'null' then
          _state.combat.namedWatchList[#_state.combat.namedWatchList + 1] = e:lower()
      end
  end
  ```

- Remove the TODO comment at combat.lua:356

**All downstream references to `burnOnNamed`** — update to `burnAllNamed ~= 0`

---

### Step 17.2 — Extract `isSpawnNamed()` local helper

Extract a local function in combat.lua replacing the inline `sp.Named()` check:

```lua
-- Mirrors Sub IsSpawnNamed (mac:12872).
-- Returns true if the spawn is a named mob.
-- SpawnMaster mode (state.session.useSpawnMaster) checks Alert[5] instead of Spawn.Named.
local function isSpawnNamed(spawnID)
    if not spawnID or spawnID == 0 then return false end
    local sp = mq.TLO.Spawn('id ' .. spawnID)
    if not sp or not sp() then return false end
    if _state.session.useSpawnMaster then
        return (mq.TLO.SpawnCount('id ' .. spawnID .. ' alert 5')() or 0) > 0
    end
    return sp.Named() or false
end
```

Add `useSpawnMaster = false` to `state.session` in state.lua and wire it from:

```lua
_state.session.useSpawnMaster = Config.get('General', 'UseSpawnMaster', '0') == '1'
```

in `Combat.init()` (or `Config.load()` — whichever is appropriate).

---

### Step 17.3 — Refactor inline NamedWatch block into `namedWatch(ignoreTarget)`

Replace the current inline block at combat.lua:1103–1128 with a local function call.

**IgnoreTarget = false (current target path):**

- Call `isSpawnNamed(myID)` → if true AND `burnAllNamed >= 1`: trigger burn, announce, set `namedCheck`
- If not named AND `burnAllNamed >= 1` AND `namedWatchList` is non-empty: check if current target's
  clean name (lowercase) is in `namedWatchList`; if so, trigger burn

```lua
local function namedWatch(ignoreTarget)
    if _state.combat.burnAllNamed == 0 then return end
    local myID = _state.combat.myTargetID or 0
    if myID == 0 then return end

    if not ignoreTarget then
        -- IgnoreTarget=false: evaluate current target (mac:12889–12913)
        local sp     = mq.TLO.Spawn('id ' .. myID)
        if not sp or not sp() then return end
        local tName  = (sp.CleanName() or ''):lower()
        local named  = isSpawnNamed(myID)
        if not named and #_state.combat.namedWatchList > 0 then
            for _, wn in ipairs(_state.combat.namedWatchList) do
                if wn == tName then named = true; break end
            end
        end
        if named then
            mq.cmd('\\popup *** Mob:(' .. sp.CleanName() .. ') is a NAMED!')
            mq.cmd('\\echo *** Mob:('  .. sp.CleanName() .. ') is a NAMED!')
            if _cast.doBurn then _cast.doBurn() end
            _state.combat.namedCheck = true
        end
    else
        -- IgnoreTarget=true: healer/caster path — scan xtarhater for nearby named (mac:12915–12966)
        local dist  = _state.combat.meleeDistance
        local named = false
        local foundID = 0
        if _state.session.useSpawnMaster then
            local cnt = mq.TLO.SpawnCount('xtarhater radius ' .. dist .. ' alert 5')() or 0
            if cnt > 0 then
                local ns = mq.TLO.Spawn('xtarhater radius ' .. dist .. ' alert 5')
                if ns and ns.ID() then named = true; foundID = ns.ID() end
            end
        else
            local cnt = mq.TLO.SpawnCount('xtarhater named radius ' .. dist)() or 0
            if cnt > 0 then
                local ns = mq.TLO.Spawn('xtarhater named radius ' .. dist)
                if ns and ns.ID() then named = true; foundID = ns.ID() end
            end
        end
        -- BurnAllNamed==2: further filter against namedWatchList
        if named and _state.combat.burnAllNamed == 2 then
            local ns    = mq.TLO.Spawn('id ' .. foundID)
            local tName = ns and (ns.CleanName() or ''):lower() or ''
            named = false
            for _, wn in ipairs(_state.combat.namedWatchList) do
                if wn == tName then named = true; break end
            end
        end
        if named and foundID ~= 0 then
            local ns    = mq.TLO.Spawn('id ' .. foundID)
            local tName = ns and ns.CleanName() or ''
            _state.combat.myTargetID   = foundID
            _state.combat.myTargetName = tName
            mq.cmd('\\popup *** Mob:(' .. tName .. ') is a NAMED!')
            mq.cmd('\\echo *** Mob:('  .. tName .. ') is a NAMED!')
            if _cast.doBurn then _cast.doBurn() end
            _state.combat.namedCheck = true
            _state.combat.myTargetID = 0   -- reset after burn (mac:12945)
        end
    end
end
```

---

### Step 17.4 — Wire SkipCombat healer call

In `Combat.fight()`, find the SkipCombat healer block (around combat.lua:1797). The mac calls `NamedWatch 1` (IgnoreTarget=true) for non-melee chars. Add the call:

```lua
-- SkipCombat==1 healer loop (mac:563-580)
if skipCombat == 1 and _heal then
    _heal.checkCures()
    _heal.checkHealth('SkipCombat')
    -- NamedWatch IgnoreTarget=true: scan xtarhater for named (mac:576)
    if not _state.combat.namedCheck and _state.combat.burnAllNamed ~= 0 then
        namedWatch(true)
    end
end
```

Also update the existing call in the melee path to use `namedWatch(false)`.

---

### Step 17.5 — `/addburn` bind in binds.lua

Add `onAddBurn` following the same pattern as `onAddPull`:

```lua
-- Add current target (or named arg) to zone-scoped MobsToBurn list in KissAssist_Info.ini.
local function onAddBurn(name)
    if not name or name == '' then
        name = mq.TLO.Target.CleanName() or ''
        if name == '' then
            printf('\ay/addburn [mobname] — no argument and no target')
            return
        end
    end
    local iniFile = state.session.infoFileName
    local zone    = state.session.zoneName
    if not iniFile or iniFile == '' or not zone or zone == '' then
        printf('\ay/addburn: zone not available yet')
        return
    end
    local existing = mq.TLO.Ini(iniFile, zone, 'MobsToBurn')() or ''
    local lname = name:lower()
    for entry in (existing .. ','):gmatch('([^,]+),') do
        if entry:match('^%s*(.-)%s*$'):lower() == lname then
            printf('\ay%s is already on the burn list.', name)
            return
        end
    end
    local updated = (existing == '' or existing == 'null')
        and name or (existing .. ',' .. name)
    -- Update runtime watch list
    state.combat.namedWatchList[#state.combat.namedWatchList + 1] = lname
    mq.cmdf('/ini "%s" "%s" "MobsToBurn" "%s"', iniFile, zone, updated)
    printf('\ayAdded \at%s\ay to burn list.', name)
end
```

Register: `bind('/addburn', onAddBurn)` in `Binds.init()`.

Check for `.mac` alias collision: the mac doesn't have an `/addburn` `#bind`, but check for a persistent alias with `mq.TLO.Alias('/addburn')()` and delete if found (consistent with the existing alias-guard pattern).

---

### Step 17.6 — `/zoneinfo` MobsToBurn display

In `onZoneInfo()` in binds.lua, add the MobsToBurn line alongside the existing pull-list output:

```lua
-- After MobsToPullFirst line:
local infoFile = state.session.infoFileName or ''
local zone     = state.session.zoneName     or ''
printf('MobsToBurn:      %s', (infoFile ~= '' and zone ~= '')
    and (mq.TLO.Ini(infoFile, zone, 'MobsToBurn')() or 'null') or 'null')
```

---

### Step 17.7 — Test plan + docs

Add Section 17 to `design/kissassist_lua_test_plan.md`:

| # | Scenario | Steps | Expected |
|---|---|---|---|
| 17.1.1 | BurnAllNamed=0 — no burn triggered | Set burnAllNamed=0, engage named mob | NamedWatch never fires |
| 17.1.2 | BurnAllNamed=1 — any named mob | Set burnAllNamed=1, engage Spawn.Named mob | Burn triggered, namedCheck set |
| 17.1.3 | BurnAllNamed=2 — only listed mob | Set burnAllNamed=2, mob not on list | No burn |
| 17.1.4 | BurnAllNamed=2 — only listed mob | Set burnAllNamed=2, mob name on list | Burn triggered |
| 17.2.1 | IgnoreTarget=true healer path | SkipCombat=1, named in xtarhater range | namedWatch(true) triggers burn, redirects myTargetID |
| 17.3.1 | namedCheck resets after fight | Kill named, CombatReset fires | namedCheck returns to false |
| 17.4.1 | /addburn target fallback | /addburn with no arg, target a mob | Mob name added to list, INI written |
| 17.4.2 | /addburn duplicate check | /addburn same mob twice | Second call prints "already on burn list" |
| 17.5.1 | /zoneinfo shows MobsToBurn | /addburn a mob, /zoneinfo | MobsToBurn line shows the mob name |

Update `design/kissassist_lua_migration_plan.md` — add M17 row to completed table after merge.

---

## Done When

- `BurnAllNamed` 0/1/2 modes all behave correctly
- `namedWatchList` loads from `KissAssist_Info.ini` at startup and updates on `/addburn`
- Named mobs trigger burn in both melee and healer/caster (IgnoreTarget) paths
- `/addburn` persists to zone-scoped INI with duplicate check and target fallback
- `/zoneinfo` shows MobsToBurn
- Test plan section added
