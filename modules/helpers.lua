-- Pure helper functions with no mq dependencies — extracted so they can be
-- unit-tested without any mock injection.
local Helpers = {}

-- 2D Euclidean distance (mirrors Math.Distance[y1,x1:y2,x2] in kissassist.mac).
function Helpers.dist2D(y1, x1, y2, x2)
    return math.sqrt((y1 - y2)^2 + (x1 - x2)^2)
end

-- Apply a DAMod string to a base duration (seconds).
-- DAMod formats:
--   '+N' / '-N'  → add/subtract N from baseDur (clamped to 0)
--   plain 'N'    → override; return N regardless of baseDur
--   nil / '' / '+0' → return baseDur unchanged (0 means no timer)
-- Returns adjusted seconds; 0 means no timer applies.
function Helpers.applyDAMod(baseDur, daMod)
    if not daMod or daMod == '' or daMod == '+0' then
        return baseDur > 0 and baseDur or 0
    end
    local first = daMod:sub(1, 1)
    if first == '+' or first == '-' then
        return math.max(0, baseDur + (tonumber(daMod) or 0))
    else
        return tonumber(daMod) or 0
    end
end

return Helpers
