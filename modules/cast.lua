-- Casting engine — CastTarget, CastCommand, CastSkill primitives (Step 3.1).
-- CastSpell/CastAA/CastDisc/CastItem added in Steps 3.2-3.3.
-- CastMem/CastReMem/CastMemSpell added in Step 3.4.
-- CastWhat dispatcher completed in Step 3.5.
local mq = require('mq')

local Cast = {}

local utils

function Cast.init(_, u)
    utils = u
end

-- ─── Primitives ───────────────────────────────────────────────────────────────

-- Mirrors CastTarget (kissassist.mac:3069-3078).
-- Clear current target then acquire targetID. Polls up to 500ms each step.
local function castTarget(targetID)
    if not targetID or targetID == 0 then return end
    mq.cmd('/squelch /target clear')
    local t0 = os.clock() + 0.5
    while os.clock() < t0 do
        if not mq.TLO.Target.ID() or mq.TLO.Target.ID() == 0 then break end
        mq.delay(50)
    end
    mq.cmdf('/squelch /target id %d', targetID)
    local t1 = os.clock() + 0.5
    while os.clock() < t1 do
        if (mq.TLO.Target.ID() or 0) == targetID then break end
        mq.delay(50)
    end
    utils.debug('cast', 'CastTarget %d → got %d', targetID, mq.TLO.Target.ID() or 0)
end

-- Mirrors CastCommand (kissassist.mac:2807-2815).
-- Strips "command:" prefix (8 chars) and executes the remainder via /docommand.
local function castCommand(spellName)
    local cmd = spellName:sub(9)
    utils.debug('cast', 'CastCommand: %s', cmd)
    mq.cmdf('/docommand %s', cmd)
    mq.delay(250)
    return 'CAST_SUCCESS'
end

-- Mirrors CastSkill (kissassist.mac:2819-2829).
-- Invis guard (except SingleHeal); /doability; poll up to 1s for ability to go not-ready.
local function castSkill(spellName, sentFrom)
    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' then
        utils.debug('cast', 'CastSkill cancelled — invisible')
        return 'CAST_CANCELLED'
    end
    utils.debug('cast', 'CastSkill: %s', spellName)
    mq.cmdf('/doability "%s"', spellName)
    local timeout = os.clock() + 1.0  -- 20 ticks × 50ms
    while os.clock() < timeout do
        if not mq.TLO.Me.AbilityReady(spellName)() then
            return 'CAST_SUCCESS'
        end
        mq.delay(50)
    end
    return 'CAST_SUCCESS'
end

-- ─── Public API ───────────────────────────────────────────────────────────────

Cast.castTarget  = castTarget
Cast.castCommand = castCommand
Cast.castSkill   = castSkill

-- CastWhat dispatcher — Step 3.5. Stub returns SUCCESS so callers can be wired now.
function Cast.castWhat(spellName, targetID, sentFrom) -- condNumber, castCount added in Step 3.5
    utils.debug('cast', 'CastWhat [stub]: %s target=%s from=%s',
        tostring(spellName), tostring(targetID), tostring(sentFrom))
    return 'CAST_SUCCESS'
end

return Cast
