local mq     = require('mq')
local actors = require('actors')

local Comms = {}

local MAILBOX = 'kissassist'
local _state, _utils
local _actor = nil

-- Build an outbound message table; mutates data in place, returns it.
local function payload(msgType, data)
    data.msgType = msgType
    data.from    = mq.TLO.Me.CleanName() or ''
    return data
end

local function onMessage(message)
    local data = message.content
    if type(data) ~= 'table' then return end

    local msgType = data.msgType
    if not msgType then return end

    -- Ignore echoes of our own broadcasts
    local myName   = (mq.TLO.Me.CleanName() or ''):lower()
    local fromName = (data.from or ''):lower()
    if fromName == myName then return end

    if msgType == 'CAMP' then
        _state.movement.campX        = data.x    or _state.movement.campX
        _state.movement.campY        = data.y    or _state.movement.campY
        _state.movement.campZ        = data.z    or _state.movement.campZ
        _state.movement.campZone     = data.zone     or _state.movement.campZone
        _state.movement.campZoneName = data.zoneName or _state.movement.campZoneName
        _state.movement.returnToCamp = true
        _state.session.chaseAssist   = false
        _utils.debug('comms', 'CAMP from %s: %.1f %.1f', data.from, data.y or 0, data.x or 0)

    elseif msgType == 'STAY' then
        _state.movement.returnToCamp = true
        _state.session.chaseAssist   = false
        _utils.debug('comms', 'STAY from %s', data.from)

    elseif msgType == 'CHASE' then
        local who = data.who or ''
        if who ~= '' then
            _state.movement.whoToChase = who
            _state.session.chaseAssist = true
            _utils.debug('comms', 'CHASE from %s: chasing %s', data.from, who)
        end

    elseif msgType == 'BUFFS' then
        local charName = data.charName or data.from or ''
        if charName ~= '' then
            _state.buffs.remote[charName] = data
            _utils.debug('comms', 'BUFFS from %s', charName)
        end

    elseif msgType == 'SWITCHMA' then
        local newMA = data.newMA or ''
        if newMA ~= '' then
            _state.session.mainAssist = newMA
            _state.session.iAmMA = (newMA:lower() == (mq.TLO.Me.CleanName() or ''):lower())
            _utils.debug('comms', 'SWITCHMA from %s: new MA=%s iAmMA=%s', data.from, newMA, tostring(_state.session.iAmMA))
            printf('\awMain Assist changed to \at%s\aw via group broadcast (IAmMA=%s)', newMA, tostring(_state.session.iAmMA))
        end

    elseif msgType == 'PULL' then
        local mob  = data.mob  or '?'
        local dist = data.dist or 0
        printf('\awPULLING-> \at%s\aw <- at %d feet.', mob, dist)
    end
end

function Comms.init(s, u)
    _state = s
    _utils = u

    _actor = actors.register(MAILBOX, onMessage)
    _utils.debug('comms', 'Comms.init: mailbox [%s] registered', MAILBOX)

    -- Activate DanNet shim when MQ2DanNet is loaded (mixed Lua/.mac group)
    if mq.TLO.Plugin('MQ2DanNet')() then
        _state.session.danNetOn = true
        printf('\ayKissAssist: \awMQ2DanNet detected — shim active for mixed Lua/.mac group.')
        _utils.debug('comms', 'Comms.init: DanNet shim active')
    end
end

-- Unicast to a specific character by name on the same server.
function Comms.send(targetChar, msgType, data)
    local msg    = payload(msgType, data)
    local server = mq.TLO.EverQuest.Server() or ''
    actors.send({ mailbox = MAILBOX, character = targetChar, server = server }, msg)
end

-- Broadcast to all KissAssist instances; DanNet shim relays movement commands to .mac chars.
function Comms.broadcast(msgType, data)
    local msg = payload(msgType, data)
    if _actor then _actor:send(msg) end

    -- DanNet shim: relay movement commands to .mac chars via /dgge
    if _state.session.danNetOn then
        if msgType == 'STAY' then
            mq.cmd('/dgge /stayhere')
        elseif msgType == 'CHASE' then
            mq.cmdf('/dgge /chaseme %s', msg.from)
        end
    end

    _utils.debug('comms', 'broadcast %s from %s', msgType, msg.from)
end

-- Group-visible announcement: /dgtell all if DanNet+peers, else /echo (mac:Sub BroadCast)
function Comms.announce(msg)
    local peerCount = _state.session.danNetOn
                      and mq.TLO.Plugin('MQ2DanNet')()
                      and (mq.TLO.DanNet.PeerCount() or 0)
                      or 0
    if peerCount > 0 then
        mq.cmdf('/dgtell all %s', msg)
    else
        mq.cmd('/echo ' .. msg)
    end
end

-- Called each main loop iteration. Actors are event-driven via mq.doevents(),
-- so no polling is needed; this is a placeholder for future DanNet-specific polling.
function Comms.tick()
end

return Comms
