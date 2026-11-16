local mq     = require('mq')
local actors = require('actors')

local Comms = {}

local MAILBOX = 'kissassist'
local _state, _utils
local _actor = nil

-- Guild/fellowship chat relay (Event_GUEQBC / Event_FSEQBC, mac:11589-11607).
-- The mac relayed over EQBC; the port uses the actor mailbox, switched by its
-- own [General] ChatRelay: 0 off, 1 guild, 2 fellowship, 3 both.
local RELAY_LABEL  = { guild = 'Guild', fellowship = 'Fellowship' }
local RELAY_DEDUPE = 3      -- seconds: several boxes relaying the same line print it once
local _relaySeen   = {}     -- [channel|speaker|text] = os.clock() first printed

local function relayOn(channel)
    local v = _state.session.chatRelay or 0
    if channel == 'guild' then return v == 1 or v == 3 end
    if channel == 'fellowship' then return v == 2 or v == 3 end
    return false
end

-- Print a relayed line unless we already see it ourselves or just printed it.
local function onChatRelay(data)
    local channel = data.channel
    if not RELAY_LABEL[channel] then return end
    if channel == 'guild' then
        local myGuild = mq.TLO.Me.Guild() or ''
        if myGuild ~= '' and myGuild == (data.guild or '') then return end
    else
        local myFs = mq.TLO.Me.Fellowship.ID() or 0
        if myFs ~= 0 and myFs == (data.fellowship or 0) then return end
    end
    local now = os.clock()
    for k, t in pairs(_relaySeen) do
        if now - t > RELAY_DEDUPE then _relaySeen[k] = nil end
    end
    local key = channel .. '|' .. tostring(data.speaker) .. '|' .. tostring(data.text)
    if _relaySeen[key] then return end
    _relaySeen[key] = now
    printf('\ap%s tells %s: %s', tostring(data.speaker), RELAY_LABEL[channel], tostring(data.text))
end

-- Build an outbound message table; mutates data in place, returns it.
local function payload(msgType, data)
    data.msgType = msgType
    data.from    = mq.TLO.Me.CleanName() or ''
    return data
end

-- Messages that change our camp, chase target or main assist. Only a member of
-- our own group/raid may send these; the mac sends them group-only (/dgge).
local GROUP_ONLY = { CAMP = true, STAY = true, CHASE = true, SWITCHMA = true }

local function inMyGroupOrRaid(name)
    if name == '' then return false end
    if (mq.TLO.Group.Member(name).Index() or 0) > 0 then return true end
    if (mq.TLO.Raid.Members() or 0) > 0 and mq.TLO.Raid.Member(name)() then return true end
    return false
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

    -- Another group boxed on this machine must not move our camp or change our MA
    if GROUP_ONLY[msgType] and not inMyGroupOrRaid(data.from or '') then
        _utils.debug('comms', 'ignored %s from %s (not in group/raid)', msgType, tostring(data.from))
        return
    end

    if msgType == 'CAMP' then
        _state.movement.campX        = data.x    or _state.movement.campX
        _state.movement.campY        = data.y    or _state.movement.campY
        _state.movement.campZ        = data.z    or _state.movement.campZ
        _state.movement.campZone     = data.zone     or _state.movement.campZone
        _state.movement.campZoneName = data.zoneName or _state.movement.campZoneName
        _state.movement.lookForward  = mq.TLO.Me.Heading.DegreesCCW() or 0
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

    elseif msgType == 'DEBUFFS' then
        local spawnID = tostring(data.spawnID or 0)
        if spawnID ~= '0' then
            if (data.total or 0) > 0 then
                _state.heal.groupDebuffs[spawnID] = {
                    poison  = data.poison  or 0,
                    disease = data.disease or 0,
                    curse   = data.curse   or 0,
                    corrupt = data.corrupt or 0,
                    mezzed  = data.mezzed  or 0,
                }
            else
                _state.heal.groupDebuffs[spawnID] = nil
            end
            _utils.debug('comms', 'DEBUFFS from %s: id=%s total=%d', data.from, spawnID, data.total or 0)
        end

    elseif msgType == 'BUFFSTATE' then
        local spawnID = data.spawnID
        if spawnID and spawnID ~= 0 then
            local buffs = data.buffs or {}
            local now   = os.clock()
            _state.buffs.memberBuffs[spawnID]       = {}
            _state.buffs.memberBuffsExpiry[spawnID] = now + 90
            local count = 0
            for spellName, dur in pairs(buffs) do
                _state.buffs.memberBuffs[spawnID][spellName] = now + (tonumber(dur) or 0)
                count = count + 1
            end
            _utils.debug('comms', 'BUFFSTATE from id=%s buffs=%d', tostring(spawnID), count)
        end

    elseif msgType == 'CHATRELAY' then
        onChatRelay(data)

    elseif msgType == 'PULL' then
        local mob  = data.mob  or '?'
        local dist = data.dist or 0
        printf('\awPULLING-> \at%s\aw <- at %d feet.', mob, dist)
    end
end

function Comms.init(s, u)
    _state = s
    _utils = u

    _state.session.chatRelay = tonumber(require('modules.config').get('General', 'ChatRelay', '0')) or 0

    _actor = actors.register(MAILBOX, onMessage)
    _utils.debug('comms', 'Comms.init: mailbox [%s] registered', MAILBOX)
    -- session.danNetOn (the DanNet relay for .mac characters) is set in Buffs.init
    -- from [General] DanNetOn, and only when MQ2DanNet is loaded.
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

-- Broadcast active buff list with per-buff remaining durations to all Lua group members.
-- Receiver populates State.buffs.memberBuffs[spawnID] for pre-cast buff checks.
function Comms.broadcastBuffState()
    if not _actor then return end
    local buffs = {}
    local function collectBuff(name, dur)
        if name ~= '' and name ~= 'null' then
            local perm = name:find(':Permanent', 1, true)
            if perm and perm > 1 then name = name:sub(1, perm - 1) end
            buffs[name] = tonumber(dur) or 0
        end
    end
    for i = 1, (mq.TLO.Me.MaxBuffSlots() or 51) do
        collectBuff(mq.TLO.Me.Buff(i).Name() or '', mq.TLO.Me.Buff(i).Duration.TotalSeconds())
    end
    ---@diagnostic disable-next-line: undefined-field
    if mq.TLO.Me.ShortBuff then
        for i = 1, 29 do
            ---@diagnostic disable-next-line: undefined-field
            collectBuff(mq.TLO.Me.ShortBuff(i).Name() or '', mq.TLO.Me.ShortBuff(i).Duration.TotalSeconds()) ---@diagnostic disable-line: undefined-field
        end
    end
    local count = 0
    for _ in pairs(buffs) do count = count + 1 end
    local msg = payload('BUFFSTATE', { spawnID = mq.TLO.Me.ID(), buffs = buffs })
    _actor:send(msg)
    _utils.debug('comms', 'broadcastBuffState: id=%s buffs=%d', tostring(mq.TLO.Me.ID()), count)
end

-- Group-visible announcement mirroring .mac Sub BroadCast (mac:12820).
-- EQBC is deprecated in the Lua port (see events.lua) — cross-char comms go over
-- DanNet + Lua actors — so this uses /dgtell all when DanNet has peers, else a
-- local /echo. `color` is an MQ colour letter (o=orange, g=green, w=white, ...);
-- default 'w'. `\a<letter>` is the MQ colour escape (\a is the bell byte 0x07).
function Comms.announce(msg, color)
    color = color or 'w'

    local peerCount = _state.session.danNetOn
                      and mq.TLO.Plugin('MQ2DanNet')()
                      and (mq.TLO.DanNet.PeerCount() or 0)
                      or 0
    if peerCount > 0 then
        mq.cmdf('/dgtell all \a%s %s \aw', color, msg)
    else
        mq.cmd('/echo ' .. msg)
    end
end

-- Relay a guild or fellowship line to the other KissAssist characters
-- (Event_GUEQBC / Event_FSEQBC, mac:11589-11607). channel: 'guild'|'fellowship'.
function Comms.relayChat(channel, speaker, text)
    if not relayOn(channel) then return end
    speaker = tostring(speaker or '')
    if speaker == '' or speaker == (mq.TLO.Me.CleanName() or '') then return end
    -- EQ quotes the text: Name tells the guild, 'hello'
    text = tostring(text or ''):gsub("^'(.*)'$", '%1')
    local msg = payload('CHATRELAY', {
        channel    = channel,
        speaker    = speaker,
        text       = text,
        guild      = mq.TLO.Me.Guild() or '',
        fellowship = mq.TLO.Me.Fellowship.ID() or 0,
    })
    if _actor then _actor:send(msg) end
    _utils.debug('comms', 'relayChat %s: %s', channel, speaker)
end

-- Test hook: the CHATRELAY receive path.
Comms._onChatRelay = onChatRelay

-- Called each main loop iteration. Actors are event-driven via mq.doevents(),
-- so no polling is needed; this is a placeholder for future DanNet-specific polling.
function Comms.tick()
end

return Comms
