-- modules/aliases.lua
-- Creates kissassist.mac's /alias shortcuts at startup (mac Sub LoadAliases,
-- mac:16565-16645). MacroQuest keeps aliases in MacroQuest.ini [Aliases], so
-- without this /chaseon, /camphere, /assistat ... only exist on installs where
-- the mac has run.
--
-- The mac rewrites every alias on every start (ForceAlias defaults to 1). Here we
-- only write the ones that are missing or differ, so MacroQuest.ini isn't rewritten
-- 50+ times per start. ${Alias[/x]} only reports existence, so the current text is
-- read from [Aliases] directly; MacroQuest writes every alias change through to it.

local mq = require('mq')

local Aliases = {}

-- mac:16574-16632, in the mac's order. Left out:
--   /switchma  -> /switchma : points at itself, and /switchma is a bound command
--                             (an alias can't be added while a command exists).
--   /dpsspam               : the mac creates it, then deletes it (mac:16643).
--   /ktdoor /kthail /ktinvite /ktsay /kttarget : KissTell task helpers, won't do
--                             (deleted below instead; /ktdismount is kept).
Aliases.LIST = {
    { '/afktoolson',    '/changevarint AFKTools AFKToolsOn' },
    { '/assistat',      '/changevarint Melee AssistAt' },
    { '/autofireon',    '/togglevariable AutoFireOn' },
    { '/autorezon',     '/togglevariable AutoRezOn' },
    { '/buffson',       '/togglevariable BuffsOn' },
    { '/camphere',      '/togglevariable ReturnToCamp' },
    { '/campradius',    '/changevarint General CampRadius' },
    { '/chase',         '/togglevariable ChaseAssist' },
    { '/chasedistance', '/changevarint General ChaseDistance' },
    { '/chaseoff',      '/changevarint General ChaseAssist 0' },
    { '/chaseon',       '/changevarint General ChaseAssist 1' },
    { '/debugall',      '/debug all on log' },
    { '/dpsinterval',   '/changevarint DPS DPSInterval' },
    { '/dpsmeter',      '/togglevariable DPSMeter' },
    { '/dpson',         '/changevarint DPS DPSOn' },
    { '/dpsskip',       '/changevarint DPS DPSSkip' },
    { '/dpswrite',      '/togglevariable DPSWriteOn' },
    { '/healson',       '/changevarint Heals HealsOn' },
    { '/interrupton',   '/togglevariable CastingInterruptOn' },
    { '/ktdismount',    '/echo KTDismount' },
    { '/katwistpause',  '/togglevariable TwistHold 1' },
    { '/katwistresume', '/togglevariable TwistHold 0' },
    { '/looton',        '/changevarint General LootOn' },
    { '/maxradius',     '/changevarint Pull MaxRadius' },
    { '/maxzrange',     '/changevarint Pull MaxZRange' },
    { '/medcombat',     '/togglevariable MedCombat' },
    { '/medstart',      '/changevarint General MedStart' },
    { '/meleedistance', '/changevarint Melee MeleeDistance' },
    { '/meleeon',       '/togglevariable MeleeOn' },
    { '/mercassistat',  '/changevarint Merc MercAssistAt' },
    { '/mezon',         '/changevarint Mez MezOn' },
    { '/movewhenhit',   '/togglevariable MoveWhenHit' },
    { '/pethold',       '/togglevariable PetHold' },
    { '/peton',         '/togglevariable PetOn' },
    { '/pettoyson',     '/togglevariable PetToysOn' },
    { '/pettoysplz',    '/echo PetToysPlease' },
    { '/rebuffon',      '/togglevariable RebuffOn' },
    { '/returntocamp',  '/togglevariable ReturnToCamp' },
    { '/rezallon',      '/togglevariable AutoRezAll 1' },
    { '/rezalloff',     '/togglevariable AutoRezAll 0' },
    { '/scatteron',     '/togglevariable ScatterOn' },
    { '/setae',         '/iniwrite AE' },
    { '/setaggro',      '/iniwrite Aggro' },
    { '/setbackoff',    '/backoff' },
    { '/setbuffs',      '/iniwrite Buffs' },
    { '/setburn',       '/iniwrite Burn' },
    { '/setcure',       '/iniwrite Cure' },
    { '/setdps',        '/iniwrite DPS' },
    { '/setheals',      '/iniwrite Heals' },
    { '/targetswitch',  '/togglevariable TargetSwitchingOn' },
    { '/trackme',       '/trackmedown' },
    { '/waithere',      '/togglevariable waithere' },
}

-- mac:16633-16643: old aliases the mac removes on every start, plus the KissTell
-- task-helper aliases the port doesn't support (they only echo to chat). The mac
-- recreates those on its own start, so rolling a character back is unaffected.
Aliases.DELETES = {
    '/debug', '/debugbuffs', '/debugcombat', '/debugcast', '/debugchainpull',
    '/debugheal', '/debugmez', '/debugmove', '/debugpull', '/debugrk', '/dpsspam',
    '/ktdoor', '/kthail', '/ktinvite', '/ktsay', '/kttarget',
}

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Parses the [Aliases] section of INI text into { ['/name'] = 'text' }, with
-- lowercase keys (INI keys and alias names are case-insensitive).
function Aliases.parse(text)
    local out, inSection = {}, false
    for line in (text or ''):gmatch('[^\r\n]+') do
        local section = line:match('^%s*%[(.-)%]')
        if section then
            inSection = trim(section):lower() == 'aliases'
        elseif inSection then
            local k, v = line:match('^%s*([^=;]-)%s*=(.*)$')
            if k and k ~= '' then out[k:lower()] = trim(v) end
        end
    end
    return out
end

-- Default reader: the whole of MacroQuest.ini, or nil if it can't be opened.
local function readMQIni()
    local f = io.open(mq.configDir .. '/MacroQuest.ini', 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

-- Creates missing/changed aliases and runs the mac's deletes.
--   isBound(name) -> true if the port binds that command (those are skipped).
--   readIni()     -> MacroQuest.ini text (default: reads the real file).
--   cmd(line)     -> runs a command (default: mq.cmd).
-- Returns written, deleted counts.
function Aliases.sync(isBound, readIni, cmd)
    isBound = isBound or function() return false end
    cmd     = cmd or mq.cmd
    local current = Aliases.parse((readIni or readMQIni)())

    local written, deleted = 0, 0
    for _, a in ipairs(Aliases.LIST) do
        local name, target = a[1], a[2]
        if not isBound(name) then
            local have = current[name:lower()]
            if not have or have:lower() ~= target:lower() then
                cmd(string.format('/squelch /alias %s %s', name, target))
                written = written + 1
            end
        end
    end
    for _, name in ipairs(Aliases.DELETES) do
        if current[name:lower()] then
            cmd(string.format('/squelch /alias %s delete', name))
            deleted = deleted + 1
        end
    end
    return written, deleted
end

return Aliases
