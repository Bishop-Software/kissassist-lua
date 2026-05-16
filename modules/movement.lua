local Config = require('modules.config')

local Movement = {}

local _state, _utils

function Movement.init(state, utils)
    _state = state
    _utils = utils

    -- [General] camp and movement settings
    _state.movement.returnToCamp     = Config.get('General', 'ReturnToCamp',     '0') == '1'
    _state.movement.campRadius       = tonumber(Config.get('General', 'CampRadius',       '50')) or 50
    _state.movement.campRadiusExceed = Config.get('General', 'CampRadiusExceed', '0') == '1'
    _state.session.chaseAssist       = Config.get('General', 'ChaseAssist',      '0') == '1'
    _state.movement.whoToChase       = Config.get('General', 'WhoToChase',       '') or ''
    _state.movement.dontMoveMe       = Config.get('General', 'DontMoveMe',       '0') == '1'
    _state.movement.stayPut          = Config.get('General', 'StayPut',          '0') == '1'
    _state.movement.stickDist        = tonumber(Config.get('General', 'StickDist',        '13')) or 13
    _state.movement.stickDistUW      = tonumber(Config.get('General', 'StickDistUW',      '10')) or 10
    _state.movement.dStickHow        = Config.get('General', 'StickHow',         '0') or '0'
    _state.movement.navPathHelper    = Config.get('General', 'NavPathHelper',    '1') ~= '0'
    _state.movement.locDelayCheckUW  = Config.get('General', 'LocDelayCheckUW',  '0') == '1'
    _state.movement.faceMobOn        = Config.get('General', 'FaceMobOn',        '0') == '1'
    _state.movement.scatterOn        = Config.get('General', 'ScatterOn',        '0') == '1'
    _state.movement.scatterDistance  = tonumber(Config.get('General', 'ScatterDistance',  '20')) or 20

    -- [Pull] movement-related pull settings
    _state.pull.moveUse        = Config.get('Pull', 'PullMoveUse', 'los') or 'los'
    _state.pull.max            = tonumber(Config.get('Pull', 'MaxRadius', '0')) or 0
    _state.pull.waypointZRange = tonumber(Config.get('Pull', 'MaxZRange', '0')) or 0
end

-- Step 7.2: return character to camp when outside campRadius (mac DoWeMove, mac:3342)
function Movement.doWeMove()
    -- TODO: implement in Step 7.2
end

-- Step 7.3: chase WhoToChase target (mac DoWeChase, mac:3664)
function Movement.doWeChase()
    -- TODO: implement in Step 7.3
end

-- Step 7.4: detect and recover from stuck state (mac Stuck, mac:3750)
function Movement.stuck()
    -- TODO: implement in Step 7.4
end

-- Step 7.4: check Z-axis distance to camp; return true if too far on Z
function Movement.zAxisCheck()
    -- TODO: implement in Step 7.4
    return false
end

-- Check/break MQ2MoveUtils stick; breakStick=true sends /stick off (mac checkstick)
function Movement.checkStick(breakStick)
    -- TODO: implement in Step 7.4
end

return Movement
