-- ServerScriptService/systems/horde.luau
-- Server-authoritative HORDE batch (replaces mob_brain + mob_move). One tight data-oriented
-- loop, NO per-mob raycasts/LOS:
--   • steer  — flow-field next-hop toward the nearest player; beeline once at the player's node
--   • spread — spatial-hash SEPARATION so the horde fans out instead of stacking. Authoritative,
--     so the server positions ARE the spread blob → bubble hitboxes match what the client sees.
--   • Y      — interpolated ALONG the current graph edge (F→T node heights). This keeps mobs on
--     the walkable surface (they climb ramps / take drops via the path) so they never sink under
--     overhangs, and per-mob edge progress avoids a flat floating plane on slopes. No raycast.
-- Positions are streamed to clients (UpdateTransformDelta f16 + periodic UpdateTransformFull f32).
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local world       = require(std.world)
local cts         = require(std.components)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local PathFinder  = require(std.PathFinder)
local FlowField   = require(std.FlowField)
local pathData    = require(std.PathData)

local Transform = cts.Transform
local Speed     = cts.Speed
local Mob       = cts.Mob
local PathNode  = cts.PathNode
local Character  = cts.Character
local Player     = cts.Player

local Waypoints = pathData[1]

-- ── Tunables ──────────────────────────────────────────────────────────────────
local MOVE_TICK     = 1 / 20
local SEP_RADIUS    = 3
local SEP_R2        = SEP_RADIUS * SEP_RADIUS
local SEP_GAIN      = 2.0     -- separation weight vs steer (higher → spreads more)
local HASH_CELL     = 6       -- ≥ SEP_RADIUS
local ADVANCE_DIST2 = 16      -- advance to next node within 4 studs (XZ)
local CONTACT       = 2
local CONTACT2      = CONTACT * CONTACT

-- streaming
local NET_TICK   = 1 / 15
local FULL_EVERY = 3          -- seconds between absolute snapshots (clears f16 drift)
local CHUNK      = 80         -- mobs per packet (id u32 + dp f16 ≈ 10B → < 900B cap)

-- ── Nav ─────────────────────────────────────────────────────────────────────────
local pathfinder = PathFinder.fromWaypoints(pathData[1], pathData[2])
local field      = FlowField.new(pathData[1], pathData[2])

local zombies    = world:query(Transform, Speed, PathNode):with(Mob):cached()
local characters = world:query(Character):with(Player):cached()

local hash = SpatialHash.new(HASH_CELL)
local out: { number } = {}
local posCache: { [number]: Vector3 } = {}

local pPos: { Vector3 } = {}
local sources: { number } = {}

local function gatherPlayers()
    table.clear(pPos)
    table.clear(sources)
    for _e, char in characters do
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local node = pathfinder:GetNearestWaypoint(root.Position)
        if node then
            pPos[#pPos + 1] = root.Position
            sources[#sources + 1] = node
        end
    end
end

-- ── Movement ──────────────────────────────────────────────────────────────────
local function moveStep(dt: number)
    gatherPlayers()
    if #pPos == 0 then return end
    field:compute(sources)

    -- snapshot positions into the hash + a cache (so separation reads neighbours cheaply)
    hash:beginFrame()
    table.clear(posCache)
    for e, transform in zombies do
        local p = transform.new.Position
        posCache[e] = p
        hash:insert(e, p.X, p.Y, p.Z)
    end

    for e, transform, speed, node in zombies do
        local pos = posCache[e]

        -- nearest player (XZ)
        local bx, bz, bestD2 = pos.X, pos.Z, math.huge
        for _, pp in pPos do
            local dx, dz = pp.X - pos.X, pp.Z - pos.Z
            local d2 = dx * dx + dz * dz
            if d2 < bestD2 then bestD2 = d2; bx = pp.X; bz = pp.Z end
        end

        local F = Waypoints[node][1] :: Vector3
        local nextHop = field:next(node)
        local T: Vector3? = if nextHop then Waypoints[nextHop][1] :: Vector3 else nil

        -- steer toward the next path node, or beeline to the player once at the player's node
        local steerX, steerZ = 0, 0
        if T then
            steerX, steerZ = T.X - pos.X, T.Z - pos.Z
        else
            local dx, dz = bx - pos.X, bz - pos.Z
            if dx * dx + dz * dz > CONTACT2 then steerX, steerZ = dx, dz end
        end
        local sm = math.sqrt(steerX * steerX + steerZ * steerZ)
        if sm > 1e-4 then steerX, steerZ = steerX / sm, steerZ / sm end

        -- separation (read neighbours from the snapshot)
        local sepX, sepZ = 0, 0
        local cnt = hash:queryInto(pos.X, pos.Y, pos.Z, out)
        for j = 1, cnt do
            local k = out[j]
            if k ~= e then
                local qp = posCache[k]
                if qp then
                    local dx, dz = pos.X - qp.X, pos.Z - qp.Z
                    local d2 = dx * dx + dz * dz
                    if d2 > 1e-4 and d2 < SEP_R2 then
                        local d = math.sqrt(d2)
                        local w = (SEP_RADIUS - d) / SEP_RADIUS
                        sepX += dx / d * w
                        sepZ += dz / d * w
                    end
                end
            end
        end

        -- combine + integrate XZ
        local vx = steerX + sepX * SEP_GAIN
        local vz = steerZ + sepZ * SEP_GAIN
        local vm = math.sqrt(vx * vx + vz * vz)
        local nx, nz = pos.X, pos.Z
        if vm > 1e-4 then
            nx = pos.X + (vx / vm) * speed * dt
            nz = pos.Z + (vz / vm) * speed * dt
        end

        -- Y from the graph edge F→T (on the walkable surface; per-mob progress conforms to the
        -- slope without floating). Stays on the path so mobs climb ramps / drop — never under map.
        local ny: number
        if T then
            local ex, ez = T.X - F.X, T.Z - F.Z
            local elen2 = ex * ex + ez * ez
            local p = if elen2 > 1e-4 then math.clamp(((nx - F.X) * ex + (nz - F.Z) * ez) / elen2, 0, 1) else 1
            ny = F.Y + (T.Y - F.Y) * p
            local tdx, tdz = nx - T.X, nz - T.Z
            if tdx * tdx + tdz * tdz < ADVANCE_DIST2 then
                world:set(e, PathNode, nextHop) -- advance (safe value-update)
            end
        else
            ny = F.Y
        end

        transform.new = CFrame.new(nx, ny, nz) -- same table ref → combat & streaming see it
    end
end

-- ── Streaming ──────────────────────────────────────────────────────────────────
local lastSent: { [number]: Vector3 } = {}
local batch = {}

local function sendStep(full: boolean)
    table.clear(batch)
    for e, transform in zombies do
        local pos = transform.new.Position
        if full then
            lastSent[e] = pos
            batch[#batch + 1] = { id = e, dp = pos }
            if #batch >= CHUNK then blink.UpdateTransformFull.FireAll(batch); table.clear(batch) end
        else
            local last = lastSent[e]
            if not last then last = pos; lastSent[e] = pos end
            local d = pos - last
            if d.Magnitude > 0.01 then
                lastSent[e] = pos
                batch[#batch + 1] = { id = e, dp = d }
                if #batch >= CHUNK then blink.UpdateTransformDelta.FireAll(batch); table.clear(batch) end
            end
        end
    end
    if #batch > 0 then
        if full then blink.UpdateTransformFull.FireAll(batch) else blink.UpdateTransformDelta.FireAll(batch) end
    end
end

-- ── Ticks ──────────────────────────────────────────────────────────────────────
local moveAcc, netAcc, fullAcc = 0, 0, 0

local function moveWrapper(dt: number)
    moveAcc += dt
    if moveAcc < MOVE_TICK then return end
    local step = moveAcc
    moveAcc = 0
    moveStep(step)
end

local function netWrapper(dt: number)
    netAcc += dt
    fullAcc += dt
    if netAcc < NET_TICK then return end
    netAcc = 0
    local full = fullAcc >= FULL_EVERY
    if full then fullAcc = 0 end
    sendStep(full)
end

scheduler.SYSTEM(moveWrapper, phases.AIMovement)
scheduler.SYSTEM(netWrapper, phases.NetworkDelta)
return 0
