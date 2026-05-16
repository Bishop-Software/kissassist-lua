-- pull.lua — Pull module: mob discovery, validation, and pull execution.
-- Ported from kissassist.mac FindMobToPull (8945), PullValidate (9443), PullCheck (9308).
-- Steps 7.5 (scaffold+INI), 7.6 (pullValidate), 7.7 (findMobToPull), 7.8 (pullCheck).

local mq     = require('mq')
local Config = require('modules.config')

local Pull = {}
local _state, _utils, _cast, _movement

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function Pull.init(state, utils, cast, movement)
    _state    = state
    _utils    = utils
    _cast     = cast
    _movement = movement

    -- [Pull] section
    _state.pull.on           = Config.get('Pull', 'PullOn',        '0') == '1'
    _state.pull.withAlt      = Config.get('Pull', 'PullWith',      'Melee')
    _state.pull.range        = tonumber(Config.get('Pull', 'PullRange',    '0'))  or 0
    _state.pull.maxRadius    = tonumber(Config.get('Pull', 'MaxRadius',    '0'))  or 0
    _state.pull.maxZRange    = tonumber(Config.get('Pull', 'MaxZRange',    '0'))  or 0
    _state.pull.min          = tonumber(Config.get('Pull', 'PullMin',      '0'))  or 0
    _state.pull.max          = tonumber(Config.get('Pull', 'PullMax',      '0'))  or 0
    _state.pull.hold         = Config.get('Pull', 'PullHold',      '0') == '1'
    _state.pull.pullArcWidth = tonumber(Config.get('Pull', 'PullArcWidth', '0'))  or 0
    _state.pull.lSide        = tonumber(Config.get('Pull', 'PullLSide',    '0'))  or 0.0
    _state.pull.rSide        = tonumber(Config.get('Pull', 'PullRSide',    '0'))  or 0.0
    _state.pull.pullWait     = tonumber(Config.get('Pull', 'PullWait',     '0'))  or 0
    _state.pull.chainPull    = tonumber(Config.get('Pull', 'ChainPull',    '0'))  or 0
    _state.pull.pullOnReturn = Config.get('Pull', 'PullOnReturn',  '0') == '1'
    _state.pull.ranking      = tonumber(Config.get('Pull', 'PullRanking',  '0'))  or 0
    _state.pull.mobsToPullFirst = Config.get('Pull', 'MobsToPull',     'all')
    _state.pull.mobsToIgnore    = Config.get('Pull', 'MobsToIgnore',   'null')
    _state.pull.mobsNotAllowed  = Config.get('Pull', 'MobsNotAllowed', 'null')
    _state.pull.moveUse         = Config.get('Pull', 'PullMoveUse',    'los')
    _state.pull.searchType      = Config.get('Pull', 'SearchType',     '')
    -- waypointZRange mirrors MaxZRange (used by movement nav Z-range guard)
    _state.pull.waypointZRange  = _state.pull.maxZRange

    -- Derive arc half-widths from PullArcWidth when individual sides not set
    if _state.pull.pullArcWidth > 0 and _state.pull.lSide == 0 and _state.pull.rSide == 0 then
        local half = _state.pull.pullArcWidth / 2.0
        _state.pull.lSide = -half
        _state.pull.rSide =  half
    end

    -- [PullAdvanced] section
    _state.pull.pullLocsOn  = Config.get('PullAdvanced', 'PullLocsOn', '0') == '1'
    _state.pull.pathWpCount = tonumber(Config.get('PullAdvanced', 'PullWpCount', '0')) or 0
    _state.pull.maxWpRange  = tonumber(Config.get('PullAdvanced', 'MaxWpRange',  '0')) or 0

    for i = 1, _state.pull.pathWpCount do
        _state.pull.pullLocY[i] = tonumber(Config.get('PullAdvanced', 'PullLocY'..i, '0')) or 0.0
        _state.pull.pullLocX[i] = tonumber(Config.get('PullAdvanced', 'PullLocX'..i, '0')) or 0.0
        _state.pull.pullLocZ[i] = tonumber(Config.get('PullAdvanced', 'PullLocZ'..i, '0')) or 0.0
    end

    _utils.debug('pull', 'Pull.init complete — on=%s with=%s range=%d maxRadius=%d',
        tostring(_state.pull.on), _state.pull.withAlt,
        _state.pull.range, _state.pull.maxRadius)
end

-- ---------------------------------------------------------------------------
-- Stubs — implemented in Steps 7.6 / 7.7 / 7.8
-- ---------------------------------------------------------------------------

-- Step 7.6: validate a single spawn as a pull candidate.
-- Returns true (valid) or false (skip).
function Pull.pullValidate(mobID, flag) -- luacheck: ignore flag
    _utils.debug('pull', 'pullValidate stub — Step 7.6')
    return false
end

-- Step 7.7: scan zone for best pull candidate; sets state.pull.mob on success.
-- Returns 1 (found) or 0 (none).
function Pull.findMobToPull(readyFlag, a, b) -- luacheck: ignore a b
    _utils.debug('pull', 'findMobToPull stub — Step 7.7')
    return 0
end

-- Step 7.8: execute the pull against state.pull.mob.
function Pull.pullCheck()
    _utils.debug('pull', 'pullCheck stub — Step 7.8')
end

return Pull
