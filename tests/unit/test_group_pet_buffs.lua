-- tests/unit/test_group_pet_buffs.lua
-- #333 item 4: BuffsOn=2 also buffs group members' pets, checked over DanNet
-- (mac:4579-4610). Covers BuffsOn loading, the DanNet answer parsing, the
-- peer lookup, /dquery + the DanNet TLO, and the pet decision (blocked buff,
-- pet already has it, doesn't stack, no pet, not a peer, no answer).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_group_pet_buffs')

    local RealConfig = require('modules.config')
    local buffsOnIni = '2'
    package.loaded['modules.config'] = {
        parseCondArray = RealConfig.parseCondArray,
        get = function(section, key, default)
            if section == 'Buffs' and key == 'BuffsOn' then return buffsOnIni end
            return default
        end,
    }
    package.loaded['modules.buffs'] = nil
    local Buffs = require('modules.buffs')
    MockMQ.set('TLO.Plugin', function() return { IsLoaded = function() return false end } end)

    local function init()
        local st = { session = {}, misc = {}, pet = { toysArray = {} },
                     buffs = { buffsArray = {}, petBuffsArray = {} } }
        Buffs.init(st, { debug = function() end }, {}, {}, nil, {})
        return st
    end

    -- BuffsOn loading: 2 = on + group pets; 1 = on only; 0 = off.
    local st = init()
    TH.assert_true(st.buffs.buffsOn, 'BuffsOn=2: buffs on')
    TH.assert_true(st.buffs.buffGroupPets, 'BuffsOn=2: group pets on')
    buffsOnIni = '1'
    st = init()
    TH.assert_true(st.buffs.buffsOn, 'BuffsOn=1: buffs on')
    TH.assert_false(st.buffs.buffGroupPets, 'BuffsOn=1: no group pets')
    buffsOnIni = '0'
    st = init()
    TH.assert_false(st.buffs.buffsOn, 'BuffsOn=0: buffs off')

    -- DanNet answers read like ${Bool[...]}.
    TH.assert_true(Buffs._dnTrue('TRUE'), 'TRUE is true')
    TH.assert_true(Buffs._dnTrue('1234'), 'an ID is true')
    TH.assert_false(Buffs._dnTrue('NULL'), 'NULL is false')
    TH.assert_false(Buffs._dnTrue('FALSE'), 'FALSE is false')
    TH.assert_false(Buffs._dnTrue('0'), '0 is false')
    TH.assert_false(Buffs._dnTrue(nil), 'no answer is false')

    -- Peer lookup: plain names and server_name full names.
    local peers = 'me|petowner|'
    MockMQ.set('TLO.DanNet.Peers', function() return peers end)
    TH.assert_eq(Buffs._danNetPeer('PetOwner'), 'petowner', 'peer found by name, any case')
    TH.assert_eq(Buffs._danNetPeer('Stranger'), nil, 'not a peer')
    peers = 'myserver_me|myserver_petowner|'
    TH.assert_eq(Buffs._danNetPeer('PetOwner'), 'myserver_petowner', 'full-name peer found')
    peers = 'me|petowner|'

    -- A fake peer that answers each /dquery through the DanNet TLO.
    local answers, received, answering = {}, {}, true
    MockMQ.set('TLO.DanNet', function()
        return {
            QReceived = function(q) return function() return received[q] or 0 end end,
            Q         = function(q) return function() return answers[q] end end,
        }
    end)
    local savedCmdf = MockMQ.cmdf
    MockMQ.cmdf = function(fmt, ...)
        local cmd = string.format(fmt, ...)
        local q = cmd:match('^/squelch /dquery %S+ %-q "(.*)"$')
        if q and answering then received[q] = (received[q] or 0) + 1 end
        return savedCmdf(fmt, ...)
    end

    TH.assert_eq(Buffs._dquery('petowner', 'Me.Level'), nil, 'no answer yet set: nil value')
    answers['Me.Level'] = '120'
    TH.assert_eq(Buffs._dquery('petowner', 'Me.Level'), '120', '/dquery returns the fresh answer')
    answering = false
    TH.assert_eq(Buffs._dquery('petowner', 'Me.Level'), nil, 'no fresh answer: nil (timeout)')
    answering = true

    local B = 'Spirit of Wolf'
    local function set(blocked, has, stacks, pet)
        answers['Me.BlockedPetBuff[' .. B .. '].ID'] = blocked
        answers['Me.Pet.Buff[' .. B .. ']']          = has
        answers['Spell[' .. B .. '].StacksPet[0]']   = stacks
        answers['Me.Pet.ID']                         = pet
    end

    set('NULL', 'NULL', 'TRUE', '500')
    TH.assert_eq(Buffs._groupPetTargetDanNet('PetOwner', B), 500, 'pet needs the buff: its ID')
    set('77', 'NULL', 'TRUE', '500')
    TH.assert_eq(Buffs._groupPetTargetDanNet('PetOwner', B), nil, 'buff blocked on the pet: skip')
    set('NULL', B, 'TRUE', '500')
    TH.assert_eq(Buffs._groupPetTargetDanNet('PetOwner', B), nil, 'pet already has it: skip')
    set('NULL', 'NULL', 'FALSE', '500')
    TH.assert_eq(Buffs._groupPetTargetDanNet('PetOwner', B), nil, "doesn't stack: skip")
    set('NULL', 'NULL', 'TRUE', '0')
    TH.assert_eq(Buffs._groupPetTargetDanNet('PetOwner', B), nil, 'no pet: skip')
    set('NULL', 'NULL', 'TRUE', '500')
    TH.assert_eq(Buffs._groupPetTargetDanNet('Stranger', B), nil, 'owner not a DanNet peer: skip')
    answering = false
    TH.assert_eq(Buffs._groupPetTargetDanNet('PetOwner', B), nil, 'no DanNet answers: skip')

    MockMQ.cmdf = savedCmdf

    -- ── Actor path and the dispatcher ──────────────────────────────────────
    -- The decision from a petBuffInfo table (local read or PETBUFFA reply).
    local from = Buffs._petTargetFromInfo
    TH.assert_eq(from({ petID = 500, has = false, blocked = false, stacks = true }), 500, 'info: needs it -> pet ID')
    TH.assert_eq(from({ petID = 500, has = true,  blocked = false, stacks = true }), nil, 'info: has it -> skip')
    TH.assert_eq(from({ petID = 500, has = false, blocked = true,  stacks = true }), nil, 'info: blocked -> skip')
    TH.assert_eq(from({ petID = 500, has = false, blocked = false, stacks = false }), nil, "info: doesn't stack -> skip")
    TH.assert_eq(from({ petID = 0,   has = false, blocked = false, stacks = true }), nil, 'info: no pet -> skip')
    TH.assert_eq(from(nil), nil, 'info: no reply -> skip')

    -- petBuffInfo reads my own pet.
    local myPetBuffSlot = nil
    MockMQ.set('TLO.Me.Pet.ID', 600)
    MockMQ.set('TLO.Me.Pet.Buff', function() return function() return myPetBuffSlot end end)
    MockMQ.set('TLO.Me.BlockedPetBuff', function() return { ID = function() return nil end } end)
    MockMQ.set('TLO.Spell', function() return { StacksPet = function() return true end } end)
    local info = Buffs.petBuffInfo(B)
    TH.assert_true(info.petID == 600 and not info.has and not info.blocked and info.stacks, 'petBuffInfo: my pet needs it')
    myPetBuffSlot = 3
    TH.assert_true(Buffs.petBuffInfo(B).has, 'petBuffInfo: buff in a pet slot -> has')
    myPetBuffSlot = nil

    -- Dispatcher: me -> local; Lua peer -> actors; else DanNet when on.
    local sent = {}
    local reply = { petID = 700, has = false, blocked = false, stacks = true }
    local dstate = { session = {}, misc = {}, pet = { toysArray = {} },
                     buffs = { buffsArray = {}, petBuffsArray = {}, petBuffReplies = {},
                               memberBuffsExpiry = {}, remote = {} } }
    local comms = {
        send = function(to, msgType, data)
            sent[#sent + 1] = to .. ':' .. msgType
            -- The owner answers straight away (in game it arrives during mq.delay).
            if reply then
                local r = {}
                for k, v in pairs(reply) do r[k] = v end
                r.reqID = data.reqID
                dstate.buffs.petBuffReplies[data.reqID] = r
            end
        end,
    }
    buffsOnIni = '2'
    Buffs.init(dstate, { debug = function() end }, {}, {}, comms, {})
    MockMQ.set('TLO.Me.CleanName', 'Me')

    TH.assert_eq(Buffs._groupPetTarget('Me', 1, B), 600, 'my own pet: checked locally')
    TH.assert_eq(#sent, 0, 'my own pet: no message sent')

    dstate.buffs.memberBuffsExpiry[42] = os.clock() + 60
    TH.assert_eq(Buffs._groupPetTarget('LuaOwner', 42, B), 700, 'Lua peer: asked over actors')
    TH.assert_eq(sent[1], 'LuaOwner:PETBUFFQ', 'Lua peer: PETBUFFQ sent to the owner')
    TH.assert_eq(next(dstate.buffs.petBuffReplies), nil, 'Lua peer: reply cleared after use')
    reply = nil
    TH.assert_eq(Buffs._groupPetTarget('LuaOwner', 42, B), nil, 'Lua peer, no reply: skip')
    reply = { petID = 700, has = false, blocked = false, stacks = true }
    dstate.buffs.memberBuffsExpiry[42] = nil
    dstate.buffs.remote.LuaOwner = {}
    sent = {}
    TH.assert_eq(Buffs._groupPetTarget('LuaOwner', 42, B), 700, 'Lua peer known from a BUFFS message: actors')
    TH.assert_eq(#sent, 1, 'Lua peer known from BUFFS: one PETBUFFQ')

    sent = {}
    dstate.session.danNetOn = false
    TH.assert_eq(Buffs._groupPetTarget('MacOwner', 43, B), nil, 'not a Lua peer, DanNet off: skip')
    TH.assert_eq(#sent, 0, 'not a Lua peer: no actor message')

    package.loaded['modules.buffs']  = nil
    package.loaded['modules.config'] = nil
end

return M
