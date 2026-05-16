local mq = require('mq')

local Binds = {}

local BOUND = {}

local function bind(cmd, fn)
    mq.bind(cmd, fn)
    BOUND[cmd] = true
end

local state, utils

-- Maps /debug subcommand names to state.debug field names
local DEBUG_FIELDS = {
    buffs  = 'buffs',
    combat = 'combat',
    cast   = 'cast',
    chainp = 'chainpull',
    heals  = 'heals',
    mez    = 'mez',
    move   = 'move',
    pet    = 'pet',
    pull   = 'pull',
    rk     = 'rk',
}

-- ─── Debug ────────────────────────────────────────────────────────────────────

local function onDebug(cmd1, cmd2, cmd3)
    local c1 = (cmd1 or ''):lower()
    local c2 = (cmd2 or ''):lower()
    local c3 = (cmd3 or ''):lower()

    local function asOnOff(s)
        if s == 'on' or s == '1' then return true end
        if s == 'off' or s == '0' then return false end
        return nil
    end

    local field, onoff

    if c1 == 'all' then
        field = 'all'
        onoff = asOnOff(c2)
    elseif DEBUG_FIELDS[c1] then
        field = DEBUG_FIELDS[c1]
        onoff = asOnOff(c2)
    elseif asOnOff(c1) ~= nil then
        field = 'general'
        onoff = asOnOff(c1)
        if not onoff and state.debug.all then field = 'all' end
    elseif c1 == 'help' then
        printf('\ay/debug [all|buffs|combat|cast|chainp|heals|mez|move|pet|pull|rk] [on|off] [log]')
        return
    else
        field = state.debug.all and 'all' or 'general'
        onoff = nil  -- toggle
    end

    if field == 'all' then
        local val = onoff ~= nil and onoff or not state.debug.all
        for k in pairs(state.debug) do
            if k ~= 'logging' then state.debug[k] = val end
        end
        printf('\ay>> Debug All %s', val and 'On' or 'Off')
    elseif field then
        local val = onoff ~= nil and onoff or not state.debug[field]
        state.debug[field] = val
        printf('\ay>> Debug %s %s', field, val and 'On' or 'Off')
    end

    -- log/logc as cmd2 (when cmd1 is field name) or cmd3
    local logcmd = (c3 ~= '' and c3 or (c2 == 'log' or c2 == 'logc') and c2 or '')
    if logcmd == 'log' or logcmd == 'logc' then
        state.debug.logging = not state.debug.logging
        if state.debug.logging then mq.cmd('/mlog on') else mq.cmd('/mlog off') end
        printf('\ay>> Debug logging %s', state.debug.logging and 'On' or 'Off')
    end
end

-- ─── Combat ───────────────────────────────────────────────────────────────────

local function onBurn(what, st)
    local w = (what or ''):lower()
    local s = (st   or ''):lower()
    if w == 'on' or s == 'on' then
        state.combat.burnOn     = true
        state.movement.campZone = mq.TLO.Zone.ID()
        printf('\awTurning Burn On.')
    elseif w == 'off' or s == 'off' then
        state.combat.burnOn     = false
        state.combat.burnActive = false
        state.combat.burnCalled = false
        state.combat.burnID     = 0
        printf('\awTurning Burn Off.')
    end
    if not state.combat.burnOn then return end
    if w == 'on' and s ~= 'doburn' then return end
    state.combat.burnCalled = true
    local burnWhat = tonumber(what) or 0
    if burnWhat > 0 then
        state.combat.burnID = burnWhat
    elseif state.combat.myTargetID > 0 then
        state.combat.burnID = state.combat.myTargetID
    else
        local tid   = mq.TLO.Target.ID() or 0
        local ttype = (mq.TLO.Target.Type() or ''):lower()
        if tid > 0 and ttype ~= 'pc' and ttype ~= 'pet' and ttype ~= 'mercenary' and ttype ~= 'corpse' then
            state.combat.burnID = tid
        end
    end
    -- Burn rotation in M4 (combat.lua)
end

local function onBackOff(onOffFlag, _waitFlag)
    local flag = (onOffFlag or ''):lower()
    local pausing
    if flag == 'on' or flag == '1' then
        pausing = false
    elseif flag == 'off' or flag == '0' then
        pausing = true
    else
        pausing = not state.dps.paused
    end
    state.dps.paused = pausing
    if pausing then
        state.combat.combatStart = false
        printf('\awBacking off — DPS paused.')
    else
        printf('\awResuming — DPS active.')
    end
    -- CombatReset + /stick off in M4 (combat.lua)
end

local function onSwitch(_lockOnFlag, newTargetID)
    if state.session.iAmMA then return end
    state.combat.calledTargetID = tonumber(newTargetID) or 0
    printf('\aw>> Switch target called.')
    -- CombatReset + Assist in M4 (combat.lua)
end

local function onSwitchMA(newMA, _newRole, _doWhat)
    if not newMA or newMA == '' then return end
    printf('\aw>> SwitchMA: %s — full logic in M4 (combat.lua)', newMA)
    -- MA reassign + CombatReset in M4
end

local function onKissCast(castWhat, _whatID, _forceInterrupt)
    if not castWhat or castWhat == '' then return end
    printf('\aw>> KissCast: %s — M3 (cast.lua)', castWhat)
    -- CastWhat dispatch in M3
end

local function onToggleVariable(cmd, val, _extra)
    printf('\aw>> ToggleVariable %s=%s — domain module for this var', tostring(cmd), tostring(val))
    -- Generic var toggle implemented per-module as each milestone adds the var
end

local function onChangeVarInt(_section, _name, _var, _val)
    printf('\aw>> ChangeVarInt — M10 (config.lua)')
end

-- ─── Movement / camp ──────────────────────────────────────────────────────────

local function onMakeCampHere()
    state.movement.campX        = mq.TLO.Me.X()
    state.movement.campY        = mq.TLO.Me.Y()
    state.movement.campZ        = mq.TLO.Me.FloorZ()
    state.movement.campZone     = mq.TLO.Zone.ID()
    state.movement.returnToCamp = true
    state.session.chaseAssist   = false
    printf('\ay>> Camp set at %.1f, %.1f', state.movement.campY, state.movement.campX)
    -- Cross-char broadcast in M9 (comms.lua)
end

local function onStayHere()
    printf('\ay>> StayHere — cross-char broadcast in M9 (comms.lua)')
    -- /dgge /waithere
end

local function onChaseMe()
    printf('\ay>> ChaseMe %s — cross-char broadcast in M9 (comms.lua)', mq.TLO.Me.CleanName())
    -- /dgge /chase on Me.CleanName
end

local function onTrackMeDown(_stickOff, _useNavOnly, _ignoreDist)
    printf('\ay>> TrackMeDown — M7 (movement.lua)')
end

local function onSetPullArc(_width, _fdir)
    printf('\ay>> SetPullArc — M7 (pull.lua)')
end

local function onSetPullRanking(_flag, _arg)
    printf('\ay>> SetPullRanking — M7 (pull.lua)')
end

-- ─── Buffs / group ────────────────────────────────────────────────────────────

local function onBuffGroup(_flag)
    state.timers.readBuffs = 0
    state.timers.iniNext   = 0
    printf('\ay>> BuffGroup — full run in M6 (buffs.lua)')
    -- CheckBuffs in M6
end

local function onCampfire()
    if not state.misc.campfireOn then
        printf('\ay>> Campfire disabled (campfireOn=false).')
        return
    end
    printf('\ay>> Campfire placement — M6/misc')
    -- Fellowship window UI interaction in M6
end

local function onTbManager(_action, _actionID)
    printf('\ay>> TooBuffList manager — M6 (buffs.lua)')
end

-- ─── Pull management ──────────────────────────────────────────────────────────

local function onAddPull(_mtp)
    printf('\ay>> AddToPull — M7 (pull.lua)')
    -- Spawn lookup + state.pull.mobsToPullRaw update + INI write in M7/M10
end

local function onAddIgnore(_mti, _byID)
    printf('\ay>> AddToIgnore — M7 (pull.lua)')
end

local function onAddMezImmune(_mti)
    printf('\ay>> AddMezImmune — M5 (mez handling in healing.lua)')
end

-- ─── Info display ─────────────────────────────────────────────────────────────

local function onZoneInfo()
    printf('-------------------------------------------------------------------------')
    printf('%s - (%s)', mq.TLO.Zone.Name() or '', mq.TLO.Zone.ShortName() or '')
    printf('-------------------------------------------------------------------------')
    printf('MobsToPullRaw:   %s', state.pull.mobsToPullRaw)
    printf('MobsToPullFirst: %s', state.pull.mobsToPullFirst)
    printf('MobsToPull:      %s', state.pull.mob)
    printf('-------------------------------------------------------------------------')
    -- INI-sourced MezImmune/MobsToIgnore/etc. displayed in M7 (pull.lua)
end

local function onAggroInfo()
    printf('-------------------------------------------------------------------------')
    printf('XTarget Entry Information:')
    printf('    Index(s): %d : %d', state.combat.xTSlot, state.combat.xTSlot2)
    local xt = mq.TLO.Me.XTarget(state.combat.xTSlot)
    if xt and xt.ID() and xt.ID() > 0 then
        printf('    Target Info: %d - %s', xt.ID(), xt.Name())
    else
        printf('    No Target Info. XTarget entry %d is empty.', state.combat.xTSlot)
    end
    printf('-------------------------------------------------------------------------')
    printf('Main Assist and Group Information:')
    printf('    I am MA: %s  MA: %s  My ID: %d',
        tostring(state.session.iAmMA), state.session.mainAssist, mq.TLO.Me.ID())
    printf('    Group MA ID: %s  My Target ID: %d',
        tostring(mq.TLO.Group.MainAssist.ID()), state.combat.myTargetID)
    printf('-------------------------------------------------------------------------')
end

-- ─── Misc / admin ─────────────────────────────────────────────────────────────

local function onAddFriend()
    local tID   = mq.TLO.Target.ID() or 0
    local tType = (mq.TLO.Target.Type() or ''):lower()
    if tID == 0 or tType ~= 'pc' or tID == mq.TLO.Me.ID() then
        printf('--ADDFRIEND: Target a PC to add to your Posse list.')
        return
    end
    local name = mq.TLO.Target.CleanName()
    mq.cmd('/posse add ' .. name)
    mq.cmd('/posse save')
    mq.cmd('/posse load')
    printf('>> Added %s to Posse list.', name)
end

local function onKissEdit()
    if not mq.TLO.Plugin('MQ2Notepad')() then
        printf('KissEdit requires MQ2Notepad to be loaded.')
        return
    end
    mq.cmd('/notepad ' .. state.session.iniFileName)
end

local function onKissCheck()
    printf('>> KissCheck (INI scan) — M10 (config.lua)')
end

local function onKaSettings(_cmd1, _cmd2, _skipIni)
    printf('>> KaSettings — M11 (ImGui UI)')
end

local function onWriteSpells(_quiet)
    printf('>> WriteMySpells — M10 (config.lua)')
end

local function onMemMySpells(_charName, _spellSet)
    printf('>> MemMySpells — M3 (cast.lua)')
end

local function onIniWrite(_section, _e1, _e2, _e3, _e4, _e5, _e6, _e7, _e8)
    printf('>> IniWrite — M10 (config.lua)')
end

local function onParse(_timeToParse)
    printf('>> Parse — M10 (dps parsing)')
end

local function onMyCmds(_cmd, _p1, _p2, _p3)
    printf('>> MyCmds — M4+ (custom command pass-through)')
end

-- ─── Registration ─────────────────────────────────────────────────────────────

function Binds.register(s, u)
    state = s
    utils = u

    -- Debug / utility
    bind('/debug',          onDebug)
    bind('/parse',          onParse)
    bind('/zoneinfo',       onZoneInfo)
    bind('/aggroinfo',      onAggroInfo)
    bind('/iniwrite',       onIniWrite)
    bind('/writespells',    onWriteSpells)
    bind('/memmyspells',    onMemMySpells)
    bind('/mycmd',          onMyCmds)
    bind('/kissedit',       onKissEdit)
    bind('/kisscheck',      onKissCheck)
    bind('/kasettings',     onKaSettings)
    bind('/togglevariable', onToggleVariable)
    bind('/changevarint',   onChangeVarInt)

    -- Combat
    bind('/burn',           onBurn)
    bind('/backoff',        onBackOff)
    bind('/switchnow',      onSwitch)
    bind('/switchma',       onSwitchMA)
    bind('/kisscast',       onKissCast)

    -- Movement / camp
    bind('/makecamphere',   onMakeCampHere)
    bind('/stayhere',       onStayHere)
    bind('/chaseme',        onChaseMe)
    bind('/trackmedown',    onTrackMeDown)
    bind('/SetPullArc',     onSetPullArc)
    bind('/setpullranking', onSetPullRanking)

    -- Buffs / group / misc
    bind('/buffgroup',      onBuffGroup)
    bind('/campfire',       onCampfire)
    bind('/tbmanager',      onTbManager)
    bind('/addfriend',      onAddFriend)

    -- Pull management
    bind('/addpull',        onAddPull)
    bind('/addignore',      onAddIgnore)
    bind('/addimmune',      onAddMezImmune)
end

function Binds.unregister()
    for cmd in pairs(BOUND) do
        mq.unbind(cmd)
    end
    BOUND = {}
end

return Binds
