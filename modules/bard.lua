-- bard.lua — Bard module: MQ2Medley context switching.
-- Step 8.5: scaffold + INI wiring.
-- Step 8.6: Bard.doBardStuff (MQ2Medley translation of DoBardStuff mac:6229-6331).

local mq     = require('mq')
local Config = require('modules.config')

local Bard = {}
local _state, _utils, _cast
-- Assigned in Bard.init() after MQ2Medley plugin is confirmed loaded.
---@diagnostic disable-next-line: undefined-field
local Medley

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

    if not mq.TLO.Plugin('MQ2Medley')() then
        printf('\ayKissAssist: loading missing bard plugin \awMQ2Medley')
        mq.cmd('/plugin MQ2Medley load')
        mq.delay(500)
        if not mq.TLO.Plugin('MQ2Medley')() then
            printf('\arKissAssist: MQ2Medley failed to load — bard medley switching will not function')
        end
    end
    ---@diagnostic disable-next-line: undefined-field
    Medley = mq.TLO.Medley

    -- [General] — medley on/off toggles
    _state.bard.twistOn      = Config.get('General', 'TwistOn',      '0') == '1'
    _state.bard.meleeTwistOn = tonumber(Config.get('General', 'MeleeTwistOn', '0')) or 0
    _state.bard.twistHold    = Config.get('General', 'TwistHold',    '0') == '1'
    _state.bard.pullTwistOn  = Config.get('Pull',    'PullTwistOn',  '0') == '1'

    -- MQ2Medley set names (Lua port addition; not in original .mac which used MQ2Twist)
    _state.bard.oocMedley    = Config.get('General', 'OOCMedley',    'ooc')
    _state.bard.meleeMedley  = Config.get('General', 'MeleeMedley',  'melee')
    _state.bard.burnMedley   = Config.get('General', 'BurnMedley',   'burn')
    _state.bard.gomMedley    = Config.get('General', 'GoMMedley',    'gomSong')

    -- Locate the MQ2 char INI and read all four medley song lists into State.
    local mqIniPath, mqIniFile = Config.findMQCharIni()
    _state.bard.mqIniPath = mqIniPath
    _state.bard.mqIniFile = mqIniFile
    if mqIniPath then
        local function readSongs(setName)
            local songs = {}
            local i = 1
            while true do
                local song = mq.TLO.Ini(mqIniFile, 'MQ2Medley-' .. setName, 'song' .. i)()
                if not song then break end
                songs[i] = song
                i = i + 1
            end
            return songs
        end
        _state.bard.oocSongs   = readSongs(_state.bard.oocMedley)
        _state.bard.meleeSongs = readSongs(_state.bard.meleeMedley)
        _state.bard.burnSongs  = readSongs(_state.bard.burnMedley)
        _state.bard.gomSongs   = readSongs(_state.bard.gomMedley)
    else
        printf('\ayKissAssist: \awMQ2 char INI not found — song set editor will be unavailable')
    end

    -- Expose saveSongSet through State so ui.lua can call it without a direct import.
    _state.bard.saveSongSet = Bard.saveSongSet

    _utils.debug('bard', 'Bard.init: twistOn=%s meleeTwistOn=%d meleeMedley=%s',
        tostring(_state.bard.twistOn), _state.bard.meleeTwistOn, _state.bard.meleeMedley)
end

-- ---------------------------------------------------------------------------
-- Bard.doBardStuff — MQ2Medley context switching.
-- Semantic translation of DoBardStuff (mac:6229-6331).
-- MQ2Twist TLOs (Twist, TwistWhat, MeleeTwistWhat) are replaced with
-- MQ2Medley equivalents: Medley.Active(), Medley.Medley(), /medley <set>.
-- The Continuous/non-Continuous MeleeTwistWhat distinction collapses into a
-- single /medley <meleeMedley> call since MQ2Medley manages the songs itself.
-- ---------------------------------------------------------------------------

function Bard.doBardStuff()
    local s = _state

    -- Class guard (mac:6230)
    if not s.session.iAmABard then return end
    if (mq.TLO.Me.Casting.ID() or 0) ~= 0 or mq.TLO.Window('CastingWindow').Open() then return end

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
        s.bard.manualStop = false  -- combat overrides manual stop
        if s.bard.meleeTwistOn ~= 0 and not s.bard.dpsTwisting then
            local activeSet = Medley.Medley() or ''
            if activeSet ~= s.bard.meleeMedley then
                stopMedley()
                mq.cmdf('/medley %s', s.bard.meleeMedley)
            end
            s.bard.dpsTwisting = true
            s.bard.twisting    = false
        end

    -- OOC path (mac:6303-6329): switch to OOC medley set when out of combat.
    elseif not s.combat.combatStart then
        if s.bard.manualStop then return end
        if s.bard.twistOn and not s.bard.twisting then
            local activeSet = Medley.Medley() or ''
            if activeSet ~= s.bard.oocMedley then
                stopMedley()
                mq.cmdf('/medley %s', s.bard.oocMedley)
            end
            s.bard.dpsTwisting = false
            s.bard.twisting    = true
        elseif not s.bard.twistOn then
            stopMedley()
        end
        -- GoM one-shot: queue after starting/resuming OOC medley (migration plan)
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

local _medleyWasPaused = false

-- Pause the active medley before an item/AA cast; stop is the only real pause MQ2Medley supports.
function Bard.pauseMedley()
    if Medley.Active() then
        mq.cmd('/medley stop')
        _medleyWasPaused = true
        mq.delay(300, function() return not (mq.TLO.Me.BardSongPlaying() or false) end)
    end
end

-- Resume a stopped medley after an item/AA cast — only if we actually stopped it.
function Bard.resumeMedley()
    if _medleyWasPaused then
        mq.cmd('/medley start')
        _medleyWasPaused = false
    end
end

-- Persist a song list to a [MQ2Medley-<setName>] section in the MQ2 char INI
-- and reload MQ2Medley so changes take effect immediately.
-- Rewrites the section line-by-line so excess old song keys are removed cleanly.
function Bard.saveSongSet(setName, songs)
    local path = _state and _state.bard.mqIniPath
    if not path then
        printf('\arKissAssist: cannot save song set — MQ2 char INI not found')
        return
    end

    local f = io.open(path, 'r')
    if not f then
        printf('\arKissAssist: cannot read MQ2 char INI')
        return
    end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()

    local target = '[MQ2Medley-' .. setName .. ']'
    local result = {}
    local i = 1
    local found = false

    while i <= #lines do
        if lines[i] == target then
            found = true
            result[#result + 1] = target
            for j, song in ipairs(songs) do
                result[#result + 1] = string.format('song%d=%s', j, song)
            end
            -- Skip the old song keys that follow.
            i = i + 1
            while i <= #lines and lines[i]:match('^song%d+=') do
                i = i + 1
            end
        else
            result[#result + 1] = lines[i]
            i = i + 1
        end
    end

    if not found then
        result[#result + 1] = ''
        result[#result + 1] = target
        for j, song in ipairs(songs) do
            result[#result + 1] = string.format('song%d=%s', j, song)
        end
    end

    local fw = io.open(path, 'w')
    if not fw then
        printf('\arKissAssist: cannot write MQ2 char INI')
        return
    end
    fw:write(table.concat(result, '\n'))
    fw:close()

    mq.cmd('/medley reload')
end

return Bard
