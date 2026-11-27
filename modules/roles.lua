-- modules/roles.lua
-- Port of Sub CheckRoles (mac:8642-8853): per-role setup that runs once every
-- module has loaded its INI settings (startup, mac:345) and again when /switchma
-- changes the role (mac:10990-11005).
--
-- Puller and hunter roles keep their setup in modules/pull/roles.lua
-- (Pull.setupPullerRole / setupHunterRole); this module calls it and covers the
-- other roles, the /stick mod and MQ2Melee aggro commands, and the checks that
-- run for every role.
--
-- Not ported, on purpose:
--  - PetTanking: set by the mac but never read.
--  - DoPetStuff / PetStateCheck at startup: the main-loop pet phase does both.
--  - Pet taunt per role: pet.lua's main-loop taunt check (honours PetTauntOverride).
--  - TargetSwitchingOn off for non-MA: combatReset already does it (mac:2311).
--  - PullPause 0 / ChainPull 0 for non-pullers: the pull phase never runs for
--    them, and pull/settings.lua already clears ChainPull.
local mq     = require('mq')
local Config = require('modules.config')

local Roles = {}

local _state, _utils, _pull, _movement, _combat, _comms

function Roles.init(state, utils, pull, movement, combat, comms)
    _state    = state
    _utils    = utils
    _pull     = pull
    _movement = movement
    _combat   = combat
    _comms    = comms
end

-- StickHow 'auto' as Movement.resolveStickHow reads it: '', '0' or 'auto'.
local function stickIsAuto()
    local v = tostring(_state.movement.dStickHow or '0'):match('^%s*(.-)%s*$'):lower()
    return v == '' or v == '0' or v == 'auto'
end

-- True if spell is an AA, an item or a book spell this character has (mac:8846).
-- A module function so tests can replace it.
function Roles.spellAvailable(spell)
    if mq.TLO.Me.AltAbility(spell)() then return true end
    if (mq.TLO.FindItem('=' .. spell).ID() or 0) > 0 then return true end
    return mq.TLO.Me.Book(spell)() ~= nil
end

-- Pet guard when it's within CampRadius of camp, else follow (mac:8786-8787).
-- Before a camp is set (campX/Y still 0) the distance to me is used.
local function petGuardOrFollow(run)
    if (mq.TLO.Me.Pet.ID() or 0) == 0 then return end
    local mv = _state.movement
    local dist
    if (mv.campX or 0) == 0 and (mv.campY or 0) == 0 then
        dist = mq.TLO.Me.Pet.Distance() or 999
    else
        local dx = (mq.TLO.Me.Pet.X() or 0) - mv.campX
        local dy = (mq.TLO.Me.Pet.Y() or 0) - mv.campY
        dist = math.sqrt(dx * dx + dy * dy)
    end
    run(dist <= (mv.campRadius or 30) and '/pet guard' or '/pet follow')
end

-- Settings checkRoles (and pull/roles.lua) override, as { sub-table, field }.
-- saveBaseline() keeps their INI values so /switchma can put them back before
-- re-running checkRoles for a new role. Without it, an assist made tank by
-- /switchma would keep AssistAt 100 after switching back (the mac does this).
-- Session state the player changes live (ReturnToCamp, ChaseAssist, StayPut)
-- is left alone.
local BASELINE_FIELDS = {
    { 'combat', 'assistAt' }, { 'combat', 'meleeOn' }, { 'combat', 'dpsOn' },
    { 'combat', 'dpsOnOoc' }, { 'buffs', 'buffsOn' },  { 'heal', 'healsOn' },
    { 'mez', 'on' },          { 'mez', 'mezDebuffOnResist' }, { 'debuff', 'on' },
    { 'pet', 'assistAt' },    { 'misc', 'mountOn' },   { 'movement', 'campRadiusExceed' },
}
local _baseline = nil

-- Records the original role (mac MyOriginalRole, mac:347) and the INI values of
-- BASELINE_FIELDS. Call once at startup, after every module has loaded its
-- settings and before checkRoles(1).
function Roles.saveBaseline()
    _state.session.myOriginalRole = _state.session.role
    _baseline = {}
    for i, f in ipairs(BASELINE_FIELDS) do
        _baseline[i] = _state[f[1]][f[2]]
    end
end

-- Puts BASELINE_FIELDS back to their saved values. No-op before saveBaseline.
function Roles.restoreBaseline()
    if not _baseline then return end
    for i, f in ipairs(BASELINE_FIELDS) do
        _state[f[1]][f[2]] = _baseline[i]
    end
end

-- Per-role setup. cmd is injectable for tests (default mq.cmd). specialK is the
-- mac's flag for startup (1) vs /switchma (0); it only gated PetStateCheck.
function Roles.checkRoles(_specialK, cmd)
    local run  = cmd or mq.cmd
    local s    = _state
    local role = s.session.role or ''
    local mq2melee = s.combat.useMQ2Melee

    if role == 'assist' or role == 'offtank' then
        -- mac:8653-8669
        if mq2melee then
            run('/squelch /melee aggro=0')
            run('/stick mod 0')
        elseif s.combat.meleeOn or s.combat.dpsOn then
            run('/stick mod 0')
        end

    elseif role == 'tank' then
        -- mac:8670-8684. MainAssist / IAmMA are set in init.lua (TANK_ROLES).
        s.combat.assistAt = 100
        if mq2melee then
            run('/squelch /melee aggro=1')
        else
            run('/stick mod -2')
        end

    elseif role == 'puller' or role == 'pullertank' or role == 'pullerpettank' then
        -- mac:8685-8734, 8803-8826 (state and MQ2Melee aggro in pull/roles.lua)
        _pull.setupPullerRole()
        if role == 'puller' and not mq2melee then
            run('/stick mod 0')
        elseif role == 'pullertank' and stickIsAuto() then
            run('/stick mod -2')
        end

    elseif role == 'hunter' or role == 'hunterpettank' then
        -- mac:8735-8798 (state and MQ2Melee aggro in pull/roles.lua)
        _pull.setupHunterRole()
        if role == 'hunter' and stickIsAuto() then run('/stick mod -2') end

    elseif role == 'petassist' then
        -- mac:8771-8776
        if mq2melee then run('/squelch /melee aggro=0') end
        s.combat.meleeOn = false

    elseif role == 'pettank' then
        -- mac:8777-8802. MainAssist / IAmMA are set in init.lua (TANK_ROLES).
        if mq2melee then run('/squelch /melee aggro=0') end
        s.combat.assistAt           = 100
        s.pet.assistAt              = 100
        s.misc.mountOn              = false
        s.movement.campRadiusExceed = (s.pull.maxRadius or 0) + 200
        petGuardOrFollow(run)

    elseif role == 'manual' then
        -- mac:8827-8836: everything automatic off
        if mq2melee then run('/squelch /melee aggro=0') end
        s.combat.meleeOn        = false
        s.combat.dpsOn          = false
        s.combat.dpsOnOoc       = false
        s.movement.returnToCamp = false
        s.session.chaseAssist   = false
        s.buffs.buffsOn         = false
        s.debuff.on             = 0
        s.heal.healsOn          = 0
        s.mez.on                = 0
    end

    -- StickHow per role, and 'auto'/'null' left over → plain stick (mac:8840)
    _movement.resolveStickHow()

    -- MezDebuffOnResist needs a MezDebuffSpell this character has (mac:8844-8851)
    local mz = s.mez
    if (mz.on or 0) ~= 0 and mz.mezDebuffOnResist then
        local spell = mz.mezDebuffSpell or ''
        if spell == '' or not Roles.spellAvailable(spell) then
            mz.mezDebuffOnResist = false
            printf('\aySetting MezDebuffOnResist off. Could not Find MezDebuffSpell: %s.', spell)
        end
    end

    _utils.debug('general', 'checkRoles: role=%s assistAt=%s meleeOn=%s',
        role, tostring(s.combat.assistAt), tostring(s.combat.meleeOn))
end

-- Port of Bind_SwitchMA (mac:10969). newRole defaults to tank. broadcast: also
-- send it to the group (the mac's DoWhatFlag 0). Then, as the mac does:
--   newMA is me     → I'm the MA, role = newRole
--   newMA is my pet → I'm the MA, role = pettank
--   anyone else     → not the MA, back to the role I started with
-- A changed role restores the INI baseline first (see BASELINE_FIELDS), then
-- checkRoles runs. Unlike the mac, the next main-loop pass picks up the target
-- instead of an immediate Assist / attack. cmd is passed to checkRoles (tests).
-- Must not be called from an actor callback: combatReset waits with mq.delay.
-- Returns true if the switch was applied.
function Roles.switchMA(newMA, newRole, broadcast, cmd)
    local s = _state.session
    newMA = tostring(newMA or '')
    if newMA == '' or newMA:lower() == 'null' then return false end
    newRole = tostring(newRole or ''):lower()
    if newRole == '' or newRole == 'null' then newRole = 'tank' end
    if not Config.ROLES[newRole] then
        printf('\ay/switchma: unknown role \at%s', newRole)
        return false
    end

    if broadcast and _comms then
        _comms.broadcast('SWITCHMA', { newMA = newMA, newRole = newRole })
    end

    local me    = mq.TLO.Me.CleanName() or ''
    local petID = mq.TLO.Me.Pet.ID() or 0
    local pet   = petID > 0 and (mq.TLO.Me.Pet.CleanName() or '') or ''
    local lname = newMA:lower()
    local role, runCheck
    if lname == me:lower() then
        s.mainAssist, s.iAmMA = me, true
        role, runCheck = newRole, true
    elseif pet ~= '' and lname == pet:lower() then
        s.mainAssist, s.iAmMA = me, true
        role, runCheck = 'pettank', true
    else
        s.mainAssist, s.iAmMA = newMA, false
        role = s.myOriginalRole or s.role
        runCheck = role ~= s.role
    end

    if role ~= s.role then
        s.role = role
        Roles.restoreBaseline()
    end
    if runCheck then Roles.checkRoles(0, cmd) end

    _state.combat.calledTargetID = 0
    if _combat then _combat.combatReset('switchma', 'switchma') end
    printf('\awMain Assist changed to \at%s\aw (IAmMA=%s, role %s)', s.mainAssist, tostring(s.iAmMA), s.role)
    return true
end

-- ── Switch MA from the UI (Combat tab > Melee) ──────────────────────────────
-- Roles offered for the new MA, in the order the UI lists them. /switchma
-- defaults to tank (the mac's default), so tank comes first.
Roles.MA_ROLE_CHOICES = {
    'tank', 'pettank', 'offtank', 'assist', 'pullertank', 'pullerpettank',
    'puller', 'hunter', 'hunterpettank', 'petassist', 'manual',
}

-- Pure. snap = { me, members = {names}, pet, currentMA }. Returns the names the
-- UI offers (me, then the other group members incl. mercs, then my pet; no
-- duplicates, case-insensitive) and the index of the current MA in it. A current
-- MA outside the group is listed first so the combo can show it.
function Roles.maChoices(snap)
    local list, seen = {}, {}
    local function add(n)
        n = tostring(n or '')
        if n == '' or n:lower() == 'null' or seen[n:lower()] then return end
        seen[n:lower()] = true
        list[#list + 1] = n
    end
    add(snap.me)
    for _, n in ipairs(snap.members or {}) do add(n) end
    add(snap.pet)
    local cur = tostring(snap.currentMA or '')
    if cur ~= '' and cur:lower() ~= 'null' and not seen[cur:lower()] then
        table.insert(list, 1, cur)
        seen[cur:lower()] = true
    end
    local idx = 1
    for i, n in ipairs(list) do
        if n:lower() == cur:lower() then idx = i end
    end
    return list, idx
end

-- Reads the group for maChoices().
function Roles.maSnapshot()
    local members = {}
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local n = mq.TLO.Group.Member(i).CleanName()
        if n and n ~= '' then members[#members + 1] = n end
    end
    local petID = mq.TLO.Me.Pet.ID() or 0
    return {
        me        = mq.TLO.Me.CleanName() or '',
        members   = members,
        pet       = petID > 0 and (mq.TLO.Me.Pet.CleanName() or '') or '',
        currentMA = _state.session.mainAssist or '',
    }
end

-- Pure. The /kactl ma words the UI queues with Control.defer (#363; 'group'
-- tells the group too). Deferred, so the switch runs outside the ImGui frame.
function Roles.switchMAWords(name, role, broadcast)
    local words = { name, role or 'tank' }
    if broadcast then words[3] = 'group' end
    return words
end

return Roles
