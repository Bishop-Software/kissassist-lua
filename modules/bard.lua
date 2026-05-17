-- bard.lua — Bard module: MQ2Medley context switching.
-- Step 8.5: scaffold + INI wiring.
-- Step 8.6: Bard.doBardStuff (MQ2Medley translation of DoBardStuff mac:6229-6331).

local mq     = require('mq')
local Config = require('modules.config')

-- MQ2Medley is a plugin TLO not in the type definitions; alias to suppress warnings.
---@diagnostic disable-next-line: undefined-field
local Medley = mq.TLO.Medley

local Bard = {}
local _state, _utils, _cast

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

-- Stop the active medley and wait for any song to cease.
-- Replaces Sub CastBardCheck (mac:6050-6060) and inline /stopsong patterns.
local function stopMedley()
    if Medley.Active() then
        mq.cmd('/medley stop')
        mq.delay(500, function() return not (mq.TLO.Me.BardSongPlaying() or false) end)
    end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function Bard.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    if not _state.session.iAmABard then return end

    -- [General] — medley on/off toggles
    _state.bard.twistOn      = Config.get('General', 'TwistOn',      '0') == '1'
    _state.bard.meleeTwistOn = tonumber(Config.get('General', 'MeleeTwistOn', '0')) or 0
    _state.bard.twistHold    = Config.get('General', 'TwistHold',    '0') == '1'
    _state.bard.pullTwistOn  = Config.get('General', 'PullTwistOn',  '0') == '1'

    -- MQ2Medley set names (Lua port addition; not in original .mac which used MQ2Twist)
    _state.bard.oorMedley    = Config.get('General', 'OORMedley',    'oor')
    _state.bard.meleeMedley  = Config.get('General', 'MeleeMedley',  'melee')
    _state.bard.burnMedley   = Config.get('General', 'BurnMedley',   'burn')
    _state.bard.gomMedley    = Config.get('General', 'GoMMedley',    'gomSong')

    _utils.debug('bard', 'Bard.init: twistOn=%s meleeTwistOn=%d meleeMedley=%s',
        tostring(_state.bard.twistOn), _state.bard.meleeTwistOn, _state.bard.meleeMedley)
end

-- ---------------------------------------------------------------------------
-- Bard.doBardStuff — MQ2Medley context switching.
-- Semantic translation of DoBardStuff (mac:6229-6331).
-- MQ2Twist TLOs (Twist, TwistWhat, MeleeTwistWhat) are replaced with
-- MQ2Medley equivalents: Medley.Active(), Medley.ActiveSet(), /medley <set>.
-- The Continuous/non-Continuous MeleeTwistWhat distinction collapses into a
-- single /medley <meleeMedley> call since MQ2Medley manages the songs itself.
-- ---------------------------------------------------------------------------

function Bard.doBardStuff()
    local s = _state

    -- Class guard (mac:6230)
    if not s.session.iAmABard then return end

    -- Both medley modes disabled (mac:6231): stop any lingering medley and exit
    if not s.bard.twistOn and s.bard.meleeTwistOn == 0 then
        stopMedley()
        return
    end

    -- Medley not running: reset runtime tracking state (mac:6232-6236)
    if not Medley.Active() then
        s.bard.twisting    = false
        s.bard.dpsTwisting = false
        if mq.TLO.Me.BardSongPlaying() and (mq.TLO.Me.Casting.ID() or 0) > 0
           and not mq.TLO.Window('CastingWindow').Open() then
            mq.cmd('/stopsong')
        end
    end

    -- Invis/hold path (mac:6248-6253): leave active medley alone; queue GoM if pending
    if mq.TLO.Me.Invis() or s.bard.twistHold then
        if s.bard.gomActive then
            mq.cmdf('/medley queue %s', s.bard.gomMedley)
            s.bard.gomActive = false
        end
        return
    end

    _utils.debug('bard', 'doBardStuff: active=%s meleeTwistOn=%d dpsTwisting=%s combatStart=%s twisting=%s',
        tostring(Medley.Active()), s.bard.meleeTwistOn,
        tostring(s.bard.dpsTwisting), tostring(s.combat.combatStart), tostring(s.bard.twisting))

    local aggroID = tonumber(s.combat.aggroTargetID) or 0

    -- Combat path (mac:6256-6302): switch to melee medley set when in combat or
    -- when meleeTwistOn==2 with an aggro target (pre-combat aggro mode).
    if s.combat.combatStart or (s.bard.meleeTwistOn == 2 and aggroID > 0) then
        if s.bard.meleeTwistOn ~= 0 and not s.bard.dpsTwisting then
            local activeSet = Medley.ActiveSet() or ''
            if activeSet ~= s.bard.meleeMedley then
                stopMedley()
                mq.cmdf('/medley %s', s.bard.meleeMedley)
            end
            s.bard.dpsTwisting = true
            s.bard.twisting    = false
        end

    -- OOC path (mac:6303-6329): switch to OOR medley set when out of combat.
    elseif not s.combat.combatStart then
        if s.bard.twistOn and not s.bard.twisting then
            local activeSet = Medley.ActiveSet() or ''
            if activeSet ~= s.bard.oorMedley then
                stopMedley()
                mq.cmdf('/medley %s', s.bard.oorMedley)
            end
            s.bard.dpsTwisting = false
            s.bard.twisting    = true
        elseif not s.bard.twistOn then
            stopMedley()
        end
        -- GoM one-shot: queue after starting/resuming OOR medley (migration plan)
        if s.bard.gomActive then
            mq.cmdf('/medley queue %s', s.bard.gomMedley)
            s.bard.gomActive = false
        end
    end

    _utils.debug('bard', 'doBardStuff: done dpsTwisting=%s twisting=%s',
        tostring(s.bard.dpsTwisting), tostring(s.bard.twisting))
end

-- ---------------------------------------------------------------------------
-- Public helpers used by cast.lua and pull.lua (Step 8.7)
-- ---------------------------------------------------------------------------

-- Expose stopMedley so pull.lua can call Bard.stopMedley() directly.
Bard.stopMedley = stopMedley

-- Pause the active medley before an AA cast; uses /medley pause.
function Bard.pauseMedley()
    if Medley.Active() then
        mq.cmd('/medley pause')
        mq.delay(300, function() return not (mq.TLO.Me.BardSongPlaying() or false) end)
    end
end

-- Resume a paused medley after an AA cast.
function Bard.resumeMedley()
    mq.cmd('/medley resume')
end

return Bard
