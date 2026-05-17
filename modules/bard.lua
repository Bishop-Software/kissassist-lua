-- bard.lua — Bard module: MQ2Medley context switching.
-- Step 8.5: scaffold + INI wiring.
-- Step 8.6: Bard.doBardStuff (MQ2Medley translation of DoBardStuff mac:6229-6331).

local Config = require('modules.config')

local Bard = {}
local _state, _utils, _cast

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
-- Bard.doBardStuff — Step 8.6 stub
-- ---------------------------------------------------------------------------

function Bard.doBardStuff()
    -- TODO Step 8.6: port DoBardStuff (mac:6229-6331) translated to MQ2Medley API
end

return Bard
