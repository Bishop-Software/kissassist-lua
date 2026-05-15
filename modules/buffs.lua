local mq     = require('mq')
local Config = require('modules.config')

local Buffs = {}
local _state, _utils, _cast

local BUFFS_FILE  = 'KissAssist_Buffs.ini'
local PET_ROLES   = { pettank=true, pullerpettank=true, hunterpettank=true }

-- Mirrors Sub CleanBuffsFile (mac:12425).
-- Removes entries from KissAssist_Buffs.ini that are from a different day or hour.
local function cleanBuffsFile()
    if _state.timers.cleanBuffs > os.clock() then return end
    local sectionStr = mq.TLO.Ini(BUFFS_FILE)() or ''
    local t = os.date('*t')
    local today = tostring(t.day)
    local hour  = tostring(t.hour)
    for section in sectionStr:gmatch('([^|]+)') do
        local entryDay = mq.TLO.Ini(BUFFS_FILE, section, 'Day')() or ''
        if entryDay ~= '' and entryDay ~= today then
            mq.cmd(string.format('/ini "%s" %s NULL NULL', BUFFS_FILE, section))
        elseif entryDay ~= '' then
            local entryHour = mq.TLO.Ini(BUFFS_FILE, section, 'Hour')() or ''
            if entryHour ~= '' and entryHour ~= hour then
                mq.cmd(string.format('/ini "%s" %s NULL NULL', BUFFS_FILE, section))
            end
        end
    end
    _state.timers.cleanBuffs = os.clock() + 600
end

-- Mirrors Sub WriteBuffs (mac:17072).
-- Writes character's current buff list + metadata to KissAssist_Buffs.ini every 30s OOC.
function Buffs.writeBuffs()
    if _state.timers.writeBuffs > os.clock() then return end
    if not _state.misc.redguides then return end
    if (_state.combat.aggroTargetID or '') ~= '' then return end
    if _state.session.danNetOn then return end
    if mq.TLO.EverQuest.GameState() ~= 'INGAME' then return end

    -- blockedBuffsCount: state.lua defaults to 30 (emu); live servers use 40 (mac:17083-17087)
    -- Dynamic build detection deferred — override via state.buffs.blockedBuffsCount if needed

    cleanBuffsFile()

    local id   = tostring(mq.TLO.Me.ID() or 0)
    local t    = os.date('*t')
    local day  = tostring(t.day)
    local hour = tostring(t.hour)

    -- Write metadata keys only if absent (mac:17090-17096)
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Day')()  then mq.cmd(string.format('/ini "%s" %s Day %s',  BUFFS_FILE, id, day))  end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Hour')() then mq.cmd(string.format('/ini "%s" %s Hour %s', BUFFS_FILE, id, hour)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Zone')() then
        mq.cmd(string.format('/ini "%s" %s Zone %s', BUFFS_FILE, id, tostring(mq.TLO.Zone.ID() or 0)))
    end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Buffs')()        then mq.cmd(string.format('/ini "%s" %s Buffs ""',        BUFFS_FILE, id)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Blockedbuffs')() then mq.cmd(string.format('/ini "%s" %s Blockedbuffs ""', BUFFS_FILE, id)) end
    mq.cmd(string.format('/ini "%s" %s AmILooting 0', BUFFS_FILE, id))  -- LootOn: M8
    mq.cmd(string.format('/ini "%s" %s MyRole %s',    BUFFS_FILE, id, _state.session.role))

    -- Collect buff list: slots 1..41, strip ':Permanent' suffix (mac:17098-17105)
    local bufflist = ''
    local buffCount = 0
    for i = 1, 41 do
        local name = mq.TLO.Me.Buff(i).Name() or ''
        if name ~= '' and name ~= 'null' then
            local perm = name:find(':Permanent', 1, true)
            if perm and perm > 1 then name = name:sub(1, perm - 1) end
            bufflist  = bufflist .. name .. '|'
            buffCount = buffCount + 1
        end
    end
    mq.cmd(string.format('/ini "%s" %s Buffs "%s"', BUFFS_FILE, id, bufflist))

    -- Collect blocked buff list (mac:17109-17115)
    local blockedlist = ''
    local blockedCount = 0
    for k = 1, _state.buffs.blockedBuffsCount do
        local name = mq.TLO.Me.BlockedBuff(k).Name() or ''
        if name ~= '' and name ~= 'null' then
            blockedlist  = blockedlist .. name .. '|'
            blockedCount = blockedCount + 1
        end
    end
    if blockedlist ~= '' then
        mq.cmd(string.format('/ini "%s" %s Blockedbuffs "%s"', BUFFS_FILE, id, blockedlist))
    end

    _state.timers.writeBuffs = os.clock() + 30
    _utils.debug('buffs', 'Buffs.writeBuffs: id=%s buffs=%d blocked=%d', id, buffCount, blockedCount)
end

-- Mirrors Sub WriteBuffsPet (mac:12364).
-- Writes pet's buff list to KissAssist_Buffs.ini; pettank roles only.
function Buffs.writeBuffsPet()
    if (mq.TLO.Me.Pet.ID() or 0) == 0 then return end
    if not PET_ROLES[_state.session.role] then return end
    if (_state.combat.aggroTargetID or '') ~= '' then return end
    if _state.timers.writeBuffsPet > os.clock() then return end
    if _state.session.danNetOn then return end
    if not _state.misc.redguides then return end

    cleanBuffsFile()

    local id  = tostring(mq.TLO.Me.Pet.ID())
    local t   = os.date('*t')
    local day = tostring(t.day)
    local hr  = tostring(t.hour)

    if not mq.TLO.Ini(BUFFS_FILE, id, 'Day')()  then mq.cmd(string.format('/ini "%s" %s Day %s',  BUFFS_FILE, id, day)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Hour')() then mq.cmd(string.format('/ini "%s" %s Hour %s', BUFFS_FILE, id, hr))  end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Zone')() then
        mq.cmd(string.format('/ini "%s" %s Zone %s', BUFFS_FILE, id, tostring(mq.TLO.Zone.ID() or 0)))
    end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Buffs')() then mq.cmd(string.format('/ini "%s" %s Buffs ""', BUFFS_FILE, id)) end

    -- Pet buffs via Me.PetBuff (no targeting needed; mac:12395-12406)
    local bufflist = ''
    local buffCount = 0
    for i = 1, 50 do
        local name = mq.TLO.Me.PetBuff(i).Name() or ''
        if name ~= '' then
            bufflist  = bufflist .. name .. '|'
            buffCount = buffCount + 1
        end
    end
    mq.cmd(string.format('/ini "%s" %s Buffs "%s"', BUFFS_FILE, id, bufflist))

    -- Blocked pet buffs: slots 0..39 (mac:12410-12416)
    local blockedlist = ''
    for k = 0, 39 do
        local name = mq.TLO.Me.BlockedPetBuff(k).Name() or ''
        if name ~= '' and name ~= 'null' then
            blockedlist = blockedlist .. name .. '|'
        end
    end
    if blockedlist ~= '' then
        mq.cmd(string.format('/ini "%s" %s Blockedbuffs "%s"', BUFFS_FILE, id, blockedlist))
    end

    _state.timers.writeBuffsPet = os.clock() + 30
    _utils.debug('buffs', 'Buffs.writeBuffsPet: id=%s buffs=%d', id, buffCount)
end

-- Mirrors Sub WriteBuffsMerc (mac:12318).
-- Writes mercenary's buff list to KissAssist_Buffs.ini.
function Buffs.writeBuffsMerc()
    if mq.TLO.Mercenary.State() ~= 'Active' then return end
    if (_state.combat.aggroTargetID or '') ~= '' then return end
    if _state.timers.writeBuffsMerc > os.clock() then return end
    if _state.session.danNetOn then return end
    if not _state.misc.redguides then return end
    if mq.TLO.EverQuest.GameState() ~= 'INGAME' then return end

    cleanBuffsFile()

    local id  = tostring(mq.TLO.Mercenary.ID() or 0)
    local t   = os.date('*t')
    local day = tostring(t.day)
    local hr  = tostring(t.hour)

    if not mq.TLO.Ini(BUFFS_FILE, id, 'Day')()  then mq.cmd(string.format('/ini "%s" %s Day %s',  BUFFS_FILE, id, day)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Hour')() then mq.cmd(string.format('/ini "%s" %s Hour %s', BUFFS_FILE, id, hr))  end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Zone')() then
        mq.cmd(string.format('/ini "%s" %s Zone %s', BUFFS_FILE, id, tostring(mq.TLO.Zone.ID() or 0)))
    end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Buffs')() then mq.cmd(string.format('/ini "%s" %s Buffs ""', BUFFS_FILE, id)) end

    -- Merc buffs: slots 1..15 via Mercenary.Buff (mac:12343-12355)
    -- Note: mac targets merc first to populate buffs; Mercenary.Buff TLO may not require it in Lua
    local bufflist = ''
    local buffCount = 0
    for i = 1, 15 do
        local name = mq.TLO.Mercenary.Buff(i).Name() or ''
        if name ~= '' then
            bufflist  = bufflist .. name .. '|'
            buffCount = buffCount + 1
        end
    end
    mq.cmd(string.format('/ini "%s" %s Buffs "%s"', BUFFS_FILE, id, bufflist))

    _state.timers.writeBuffsMerc = os.clock() + 30
    _utils.debug('buffs', 'Buffs.writeBuffsMerc: id=%s buffs=%d', id, buffCount)
end

-- Mirrors Bind_Settings buff loading (kissassist.mac:14657-14671) and
-- Pet buff loading from [Pet] INI section.
function Buffs.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    -- Cross-char comms flag (guards all write functions)
    _state.session.danNetOn = Config.get('General', 'DanNetOn', '0') == '1'

    -- [Buffs] section
    _state.buffs.buffsOn         = Config.get('Buffs', 'BuffsOn',        '0') == '1'
    _state.buffs.rebuffOn        = Config.get('Buffs', 'RebuffOn',       '1') == '1'
    _state.buffs.checkBuffsTimer = tonumber(Config.get('Buffs', 'CheckBuffsTimer', '15')) or 15
    _state.buffs.powerSource     = Config.get('Buffs', 'PowerSource',    '') or ''

    local buffsArr = Config.get('Buffs', 'Buffs', nil)
    if type(buffsArr) == 'table' then
        for _, v in ipairs(buffsArr) do
            if v and v ~= '' then
                _state.buffs.buffsArray[#_state.buffs.buffsArray + 1] = v
            end
        end
    end

    -- Mount fields from [General] (mac:4200)
    local mountOnRaw = Config.get('General', 'MountOn', nil)
    if mountOnRaw ~= nil then
        _state.misc.mountOn = mountOnRaw == '1'
    end
    _state.buffs.mountSpell = Config.get('General', 'MountSpell', '') or ''

    -- [Pet] buff list
    _state.buffs.petBuffsOn = Config.get('Pet', 'PetBuffsOn', '0') == '1'
    local petBuffsArr = Config.get('Pet', 'PetBuffs', nil)
    if type(petBuffsArr) == 'table' then
        for _, v in ipairs(petBuffsArr) do
            if v and v ~= '' then
                _state.buffs.petBuffsArray[#_state.buffs.petBuffsArray + 1] = v
            end
        end
    end

    utils.debug('buffs',
        'Buffs.init: buffsOn=%s buffs#=%d petBuffsOn=%s petBuffs#=%d rebuffOn=%s checkBuffsTimer=%d mountOn=%s danNetOn=%s',
        tostring(_state.buffs.buffsOn),
        #_state.buffs.buffsArray,
        tostring(_state.buffs.petBuffsOn),
        #_state.buffs.petBuffsArray,
        tostring(_state.buffs.rebuffOn),
        _state.buffs.checkBuffsTimer,
        tostring(_state.misc.mountOn),
        tostring(_state.session.danNetOn))
end

return Buffs
