-- Shared server-side data model for the electricity prototype.
--
-- Nodes use their actual world positions. A connection is represented by one
-- or two orthogonal logical segments. Long logical segments are rendered as
-- several repeated visual pieces, each placed at its own midpoint, following
-- the same geometric principle as the vanilla electric fence field.

local Power = {}
local EPSILON = 0.001
local POWER_TICK_INTERVAL = 0.2
-- Connections are limited by the wall-grid distance on either axis.  A
-- diagonal route is still allowed, but neither its horizontal nor vertical
-- span may exceed this many wall cells.
Power.MAX_CONNECTION_GRID_DISTANCE = 32

-- Prototype electrical quantities.  Energy is measured in watt-seconds, so a
-- 480W consumer removes 480 energy units per second from its circuit.
Power.DEFAULT_BATTERY_CAPACITY = 10000
Power.TEST_GENERATOR_POWER = 1000000
Power.ELECTROBANK_CHARGER_POWER = 480
-- All wire grades use the high-voltage geometry: pieces are centred on the
-- one-world-unit wall grid and the authored 111-pixel straight artwork is
-- stretched to 180 pixels.  Corner artwork reaches 65 pixels from its bend
-- to each connector.
local WIRE_GRID_LENGTH = 1
local WIRE_SCALE = 180 / 111
local WIRE_CONNECTOR_LENGTH = 65 / 150
local WIRE_CORNER_TAP_LENGTH = 100 / 150

local function IsValid(inst)
    return inst ~= nil and inst.IsValid ~= nil and inst:IsValid()
end

local function GetTileCenter(pt)
    if pt == nil or TheWorld == nil or TheWorld.Map == nil then
        return nil
    end
    local x, y, z = TheWorld.Map:GetTileCenterPoint(pt.x, 0, pt.z)
    return Vector3(x, y or 0, z)
end

local function CopyPoint(x, z)
    return { x = x, z = z }
end

local function DistanceSquared(a, b)
    local dx = b.x - a.x
    local dz = b.z - a.z
    return dx * dx + dz * dz
end

local function GetDirection(from, to)
    local dx = to.x - from.x
    local dz = to.z - from.z
    if math.abs(dx) > EPSILON then
        return dx < 0 and "L" or "R"
    end
    -- The ONI asset names use the same ground directions as the wire's
    -- OnGround animation: negative world Z is U and positive world Z is D.
    return dz < 0 and "U" or "D"
end

local GetPoint

local function GetNodeAnimation(inst)
    if not IsValid(inst) or not inst.kei_power_is_node
        or inst.kei_power_node_type == "device"
    then
        return nil
    end

    local point = GetPoint(inst)
    if point == nil then
        return "None"
    end

    local directions = {}
    for _, target in pairs(inst.kei_power_links or {}) do
        if IsValid(target) then
            local direction
            local route = inst.kei_power_routes ~= nil
                and inst.kei_power_routes[target.GUID] or nil
            if route ~= nil and route.segments ~= nil
                and #route.segments > 0
            then
                -- Use the actual orthogonal route rather than the direct
                -- vector between endpoints.  A diagonal connection may turn
                -- first, so its node must show the same one-direction
                -- connector as the first/last straight wire piece.
                local is_route_source = route.source == inst
                if route.source == nil and route.start ~= nil then
                    is_route_source = math.abs(point.x - route.start.x) <= EPSILON
                        and math.abs(point.z - route.start.z) <= EPSILON
                end
                if is_route_source then
                    local first = route.segments[1]
                    direction = GetDirection(first.start, first.target)
                else
                    local last = route.segments[#route.segments]
                    direction = GetDirection(last.target, last.start)
                end
            else
                local target_point = GetPoint(target)
                if target_point ~= nil then
                    direction = GetDirection(point, target_point)
                end
            end
            if direction ~= nil then
                directions[direction] = true
            end
        end
    end

    local has_l = directions.L == true
    local has_r = directions.R == true
    local has_u = directions.U == true
    local has_d = directions.D == true
    local count = (has_l and 1 or 0)
        + (has_r and 1 or 0)
        + (has_u and 1 or 0)
        + (has_d and 1 or 0)

    if count == 0 then
        return "None"
    elseif count == 1 then
        return has_l and "L"
            or has_r and "R"
            or has_u and "U"
            or "D"
    elseif count == 2 then
        if has_l and has_r then
            return "LR"
        elseif has_u and has_d then
            return "UD"
        elseif has_l and has_u then
            -- The authored corner assets use the opposite names for these
            -- two diagonal cases.  Keep node corners consistent with the
            -- mapping used by GetCornerAnimation below.
            return "RD"
        elseif has_l and has_d then
            return "LD"
        elseif has_r and has_u then
            return "RU"
        else
            return "LU"
        end
    elseif count == 3 then
        if not has_l then
            return "RUD"
        elseif not has_r then
            return "LUD"
        elseif not has_u then
            return "LRD"
        else
            return "LRU"
        end
    end
    return "LRUD"
end

local function UpdateNodeAnimation(inst)
    local animation = GetNodeAnimation(inst)
    if animation == nil or inst.SetWireGeometry == nil then
        return
    end
    inst:SetWireGeometry(animation, 1, 0)
end

local function GetLineAnimation(from, to)
    return math.abs(to.x - from.x) > EPSILON and "LR" or "UD"
end

local function GetCornerAnimation(corner, start, target)
    local first = GetDirection(corner, start)
    local second = GetDirection(corner, target)
    local horizontal = (first == "L" or first == "R") and first or nil
    if horizontal == nil then
        horizontal = (second == "L" or second == "R") and second or nil
    end
    local vertical = (first == "U" or first == "D") and first or nil
    if vertical == nil then
        vertical = (second == "U" or second == "D") and second or nil
    end
    -- The authored corner assets name the upper-left and lower-right shapes
    -- oppositely to their geometric direction.  Keep this mapping shared by
    -- route corners and node corners.
    local corner_animations = {
        L = { U = "RD", D = "LD" },
        R = { U = "RU", D = "LU" },
    }
    if horizontal ~= nil and vertical ~= nil then
        return corner_animations[horizontal][vertical]
    end
    return "LR_UD_Bridge"
end

GetPoint = function(inst)
    if not IsValid(inst) then
        return nil
    end
    local x, _, z = inst.Transform:GetWorldPosition()
    return CopyPoint(x, z)
end

Power.GetGridPoint = GetPoint
Power.GetPoint = GetPoint

function Power.GetGridKey(x, z)
    return string.format("%.4f:%.4f", x, z)
end

function Power.IsDeviceTileOccupied(pt)
    local center = GetTileCenter(pt)
    if center == nil then
        return true
    end
    local entities = TheSim:FindEntities(center.x, 0, center.z, 0.75,
        { "kei_power_device" }, { "INLIMBO" })
    for _, entity in ipairs(entities) do
        if IsValid(entity) then
            return true
        end
    end
    return false
end

function Power.CanDeployDevice(item, pt, mouseover, deployer, rot)
    local center = GetTileCenter(pt)
    if center == nil or Power.IsDeviceTileOccupied(center) then
        return false
    end
    return TheWorld.Map:CanDeployAtPoint(center, item, mouseover)
end

function Power.GetDeviceTileCenter(pt)
    return GetTileCenter(pt)
end

local function FindPowerEndpointAtPoint(x, z, radius)
    local entities = TheSim:FindEntities(x, 0, z, radius or 0.7, { "kei_power_node" }, { "INLIMBO" })
    for _, entity in ipairs(entities) do
        if IsValid(entity) then
            return entity
        end
    end
end

Power.FindPowerEndpointAtPoint = FindPowerEndpointAtPoint

function Power.FindNodeAtPoint(x, z, radius)
    return FindPowerEndpointAtPoint(x, z, radius)
end

function Power.IsWireItem(inst)
    return IsValid(inst) and inst:HasTag("kei_power_wire_item")
end

local function IsCompatibleEndpoint(node, grade, wire_kind)
    if not IsValid(node) or not node:HasTag("kei_power_node") then
        return false
    end
    if node:HasTag("kei_power_device") or node.kei_power_node_type == "device" then
        return true
    end

    local expected_type = wire_kind == "signal"
        and "signal"
        or (grade or "kei_utilities_electric")
    return node.kei_power_node_type == expected_type
end

Power.IsCompatibleEndpoint = IsCompatibleEndpoint

function Power.CanConnectNodes(source, target, grade, wire_kind)
    if not IsValid(source) or not IsValid(target) or source == target then
        return false
    end
    local source_point = GetPoint(source)
    local target_point = GetPoint(target)
    if source_point == nil or target_point == nil
        or math.abs(target_point.x - source_point.x)
            > Power.MAX_CONNECTION_GRID_DISTANCE + EPSILON
        or math.abs(target_point.z - source_point.z)
            > Power.MAX_CONNECTION_GRID_DISTANCE + EPSILON
    then
        return false
    end
    return IsCompatibleEndpoint(source, grade, wire_kind)
        and IsCompatibleEndpoint(target, grade, wire_kind)
end

function Power.SnapWallPoint(pt)
    if pt == nil then
        return nil
    end
    return Vector3(math.floor(pt.x) + 0.5, 0, math.floor(pt.z) + 0.5)
end

-- Place a node at the canonical wall-grid point selected by the player.  The
-- geometry of a connection is calculated from these two world-space
-- endpoints later, so this must match the point used by the placer/action.
function Power.PlaceNode(item, pt, grade, wire_kind)
    if not Power.IsWireItem(item) or pt == nil or TheWorld == nil or not TheWorld.ismastersim then
        return false
    end

    -- DEPLOYMODE.WALL makes the vanilla placer show a half-tile wall point,
    -- but this action is a custom RMB action and receives the raw mouse point.
    -- Snap again on the server so placement and saved connection geometry use
    -- exactly the same coordinates as vanilla walls.
    local snapped = Power.SnapWallPoint(pt)
    local x, z = snapped.x, snapped.z

    if FindPowerEndpointAtPoint(x, z, 0.7) ~= nil then
        return false
    end

    local is_signal = wire_kind == "signal"
    local node_prefab = item.kei_power_node_prefab
        or (is_signal and "kei_logic_wire_node" or "kei_power_wire_node")
    local node = SpawnPrefab(node_prefab)
    if node == nil then
        return false
    end

    -- Match vanilla wall/fence deployment.  Teleporting the active physics
    -- body keeps the visual transform and the collision body's world point
    -- in the same simulation position.
    if node.Physics ~= nil then
        node.Physics:SetCollides(false)
        node.Physics:Teleport(x, 0, z)
        node.Physics:SetCollides(true)
    else
        node.Transform:SetPosition(x, 0, z)
    end
    node.kei_power_grade = grade or item.kei_power_grade or "kei_utilities_electric"
    node.kei_power_wire_kind = wire_kind or item.kei_power_wire_kind or "power"
    if node.SetPowerGrade ~= nil then
        node:SetPowerGrade(node.kei_power_grade)
    end
    node:PushEvent("onbuilt", { builder = nil, pos = Vector3(x, 0, z), deployable = item })

    if item.components ~= nil and item.components.stackable ~= nil then
        local one = item.components.stackable:Get()
        if one ~= nil then
            one:Remove()
        end
    else
        item:Remove()
    end
    return true
end

-- Build one deterministic Manhattan route. Endpoints are arbitrary world
-- positions, but every segment is horizontal or vertical and there is at
-- most one 90-degree bend.
function Power.BuildPath(from, to)
    if not IsValid(from) or not IsValid(to) or from == to then
        return nil
    end

    local start = GetPoint(from)
    local target = GetPoint(to)
    if start == nil or target == nil or DistanceSquared(start, target) <= EPSILON * EPSILON then
        return nil
    end

    local dx = target.x - start.x
    local dz = target.z - start.z
    local route = {
        start = start,
        target = target,
        source = from,
        target_endpoint = to,
        segments = {},
    }

    if math.abs(dx) <= EPSILON or math.abs(dz) <= EPSILON then
        table.insert(route.segments, {
            start = CopyPoint(start.x, start.z),
            target = CopyPoint(target.x, target.z),
            animation = GetLineAnimation(start, target),
            rotation = 0,
        })
        return route
    end

    local horizontal_first = math.abs(dx) >= math.abs(dz)
    -- Prefer the bend that follows the longer axis.  Both candidates are
    -- valid Manhattan paths; this one minimizes the visually dominant run
    -- changing direction and remains deterministic on equal lengths.
    local corner = horizontal_first
        and CopyPoint(target.x, start.z)
        or CopyPoint(start.x, target.z)
    route.corner = corner
    route.corner_animation = GetCornerAnimation(corner, start, target)

    table.insert(route.segments, {
        start = CopyPoint(start.x, start.z),
        target = CopyPoint(corner.x, corner.z),
        animation = GetLineAnimation(start, corner),
        rotation = 0,
    })
    table.insert(route.segments, {
        start = CopyPoint(corner.x, corner.z),
        target = CopyPoint(target.x, target.z),
        animation = GetLineAnimation(corner, target),
        rotation = 0,
    })
    return route
end

local function SegmentLength(segment)
    return math.sqrt(DistanceSquared(segment.start, segment.target))
end

local function AddWirePiece(pieces, point, animation, scale)
    table.insert(pieces, {
        start = CopyPoint(point.x, point.z),
        target = CopyPoint(point.x, point.z),
        animation = animation,
        rotation = 0,
        scale = scale or 1,
    })
end

local function CountLinks(endpoint)
    local count = 0
    for _, target in pairs(endpoint ~= nil and endpoint.kei_power_links or {}) do
        if IsValid(target) then
            count = count + 1
        end
    end
    return count
end

local function ShouldAddSignalEndpointPiece(route, endpoint)
    if route == nil or endpoint == nil then
        return true
    end

    local count = CountLinks(endpoint)
    local route_target = route.target_endpoint or route.target
    local other = route.source == endpoint and route_target or route.source
    -- During construction the new route is not in the endpoint's link table
    -- yet.  Include it when deciding whether this endpoint is still a
    -- single-connection node.  This also makes previews match the final
    -- route geometry.
    if other ~= nil
        and (endpoint.kei_power_links == nil
            or endpoint.kei_power_links[other.GUID] == nil)
    then
        count = count + 1
    end
    return count <= 1
end

local function BuildGridVisualSegments(route, grade, wire_kind)
    local pieces = {}
    if route == nil or route.segments == nil then
        return pieces
    end

    local segments = route.segments
    local first_segment = segments[1]
    local last_segment = segments[#segments]
    local first_direction = GetDirection(first_segment.start, first_segment.target)
    local last_direction = GetDirection(last_segment.target, last_segment.start)

    -- The one-way pieces are anchored on the endpoint wall grids.  Their
    -- authored connector reaches 65 pixels into the route; the corner piece
    -- has the same 65-pixel arm on each side.
    if wire_kind ~= "signal"
        or ShouldAddSignalEndpointPiece(route, route.source)
    then
        AddWirePiece(pieces, route.start, first_direction, 1)
    end
    if wire_kind ~= "signal"
        or ShouldAddSignalEndpointPiece(route, route.target_endpoint)
    then
        AddWirePiece(pieces, route.target, last_direction, 1)
    end

    -- Add a one-way connector on each arm of a corner for power wires.  Signal
    -- wires use the same corner artwork and straight-piece geometry, but do
    -- not need these extra short one-way pieces.
    if wire_kind ~= "signal" and route.corner ~= nil and #segments >= 2 then
        local corner_sides = {
            { endpoint = segments[1].start },
            { endpoint = segments[2].target },
        }
        for _, side in ipairs(corner_sides) do
            local dx = side.endpoint.x - route.corner.x
            local dz = side.endpoint.z - route.corner.z
            local length = math.sqrt(dx * dx + dz * dz)
            if length > EPSILON then
                AddWirePiece(pieces, {
                    x = route.corner.x + dx / length * WIRE_CORNER_TAP_LENGTH,
                    z = route.corner.z + dz / length * WIRE_CORNER_TAP_LENGTH,
                }, GetDirection(side.endpoint, route.corner), 1)
            end
        end
    end

    -- Full straight pieces are centred on intervening wall grids.  A corner
    -- occupies 65 pixels on each of its two arms, so no straight piece is
    -- allowed to be placed inside that connector space.
    for segment_index, segment in ipairs(segments) do
        local length = SegmentLength(segment)
        if length > EPSILON then
            local dx = (segment.target.x - segment.start.x) / length
            local dz = (segment.target.z - segment.start.z) / length
            local cells = math.floor(length + 0.5)
            for cell = 1, cells - 1 do
                local distance = cell * WIRE_GRID_LENGTH
                local from_corner = segment_index > 1
                    and WIRE_CONNECTOR_LENGTH
                    or 0
                local to_corner = segment_index < #segments
                    and WIRE_CONNECTOR_LENGTH
                    or 0
                if distance > from_corner
                    and length - distance > to_corner
                then
                    AddWirePiece(pieces, {
                        x = segment.start.x + dx * distance,
                        z = segment.start.z + dz * distance,
                    }, segment.animation, WIRE_SCALE)
                end
            end
        end
    end
    return pieces
end

function Power.GetVisualSegments(route, grade, wire_kind)
    return BuildGridVisualSegments(route, grade, wire_kind or route.wire_kind)
end

local function SpawnWirePiece(segment, grade, route, wire_kind)
    local piece = SpawnPrefab(wire_kind == "signal"
        and "kei_logic_wire_segment"
        or "kei_power_wire_segment")
    if piece == nil then
        return nil
    end

    piece.Transform:SetPosition(
        (segment.start.x + segment.target.x) * 0.5,
        0,
        (segment.start.z + segment.target.z) * 0.5
    )
    piece.kei_power_grade = grade or "kei_utilities_electric"
    piece.kei_power_wire_kind = wire_kind or "power"
    -- All visual pieces keep a reference to their logical route.  The
    -- reference lets hammering any repeated straight piece remove the whole
    -- connection instead of only the clicked sprite.
    piece.kei_power_route = route
    if piece.SetPowerGrade ~= nil then
        piece:SetPowerGrade(piece.kei_power_grade)
    end
    if piece.SetWireKind ~= nil then
        piece:SetWireKind(piece.kei_power_wire_kind)
    end
    if piece.SetWireGeometry ~= nil then
        piece:SetWireGeometry(segment.animation, segment.scale or 1, 0)
    else
        piece.AnimState:PlayAnimation(segment.animation, true)
    end
    return piece
end

local function SpawnWireCorner(route, grade, wire_kind)
    if route.corner == nil then
        return nil
    end

    local corner = SpawnPrefab(wire_kind == "signal"
        and "kei_logic_wire_segment"
        or "kei_power_wire_segment")
    if corner == nil then
        return nil
    end
    corner.Transform:SetPosition(route.corner.x, 0, route.corner.z)
    corner.kei_power_grade = grade or "kei_utilities_electric"
    corner.kei_power_wire_kind = wire_kind or "power"
    corner.kei_power_route = route
    if corner.SetPowerGrade ~= nil then
        corner:SetPowerGrade(corner.kei_power_grade)
    end
    if corner.SetWireKind ~= nil then
        corner:SetWireKind(corner.kei_power_wire_kind)
    end
    if corner.SetWireGeometry ~= nil then
        corner:SetWireGeometry(route.corner_animation, 1)
    else
        corner.AnimState:PlayAnimation(route.corner_animation, true)
    end
    return corner
end

local RemoveRoutePieces

local function RebuildRouteVisuals(route)
    if route == nil then
        return false
    end
    RemoveRoutePieces(route)
    route.pieces = {}
    for _, segment in ipairs(Power.GetVisualSegments(
        route,
        route.grade,
        route.wire_kind
    )) do
        local piece = SpawnWirePiece(
            segment,
            route.grade,
            route,
            route.wire_kind
        )
        if piece == nil then
            RemoveRoutePieces(route)
            return false
        end
        table.insert(route.pieces, piece)
    end
    local corner = SpawnWireCorner(route, route.grade, route.wire_kind)
    if route.corner ~= nil and corner == nil then
        RemoveRoutePieces(route)
        return false
    end
    if corner ~= nil then
        table.insert(route.pieces, corner)
    end
    return true
end

local function RefreshSignalRoutes(endpoint, except_route)
    for _, route in pairs(endpoint ~= nil and endpoint.kei_power_routes or {}) do
        if route ~= except_route and route.wire_kind == "signal" then
            RebuildRouteVisuals(route)
        end
    end
end

local function SetDevicePowered(inst, powered)
    if IsValid(inst) and inst.SetPowerState ~= nil then
        inst:SetPowerState(powered == true)
    end
end

local function RefreshDevicePower(inst)
    if not IsValid(inst) then
        return
    end
    local powered = next(inst.kei_power_links or {}) ~= nil
    SetDevicePowered(inst.kei_power_device, powered)
end

local function GetConnectedComponent(start)
    local component = {}
    local queue = { start }
    local seen = {}
    local head = 1
    while queue[head] ~= nil do
        local endpoint = queue[head]
        head = head + 1
        if IsValid(endpoint) and not seen[endpoint.GUID] then
            seen[endpoint.GUID] = true
            table.insert(component, endpoint)
            for _, target in pairs(endpoint.kei_power_links or {}) do
                if IsValid(target) and not seen[target.GUID] then
                    table.insert(queue, target)
                end
            end
        end
    end
    return component
end

local function GetFuelAvailability(generator, dt)
    local fueled = generator.components ~= nil and generator.components.fueled or nil
    if fueled == nil then
        return 1
    end
    if fueled.currentfuel <= EPSILON then
        return 0
    end
    if dt == nil or dt <= 0 or generator.kei_power_fuel_rate <= EPSILON then
        return 1
    end
    return math.min(1, fueled.currentfuel /
        (generator.kei_power_fuel_rate * dt))
end

local function ConsumeGeneratorFuel(generator, dt)
    local fueled = generator.components ~= nil and generator.components.fueled or nil
    if fueled == nil or dt == nil or dt <= 0 then
        return
    end
    local amount = (generator.kei_power_fuel_rate or 0) * dt
    if amount > 0 then
        fueled:DoDelta(-amount)
    end
end

local function UpdateBatteryVisual(inst)
    if not IsValid(inst) or inst.kei_power_battery_empty_animation == nil then
        return
    end
    local level = inst.kei_power_battery_level or 0
    local animation = level <= EPSILON
        and inst.kei_power_battery_empty_animation
        or inst.kei_power_battery_full_animation
    if animation ~= nil and inst.AnimState ~= nil then
        inst.AnimState:PlayAnimation(animation, true)
    end
end

local function SetBatteryLevel(inst, amount)
    if not IsValid(inst) or inst.kei_power_battery_capacity == nil then
        return
    end
    inst.kei_power_battery_level = math.max(0, math.min(
        inst.kei_power_battery_capacity, amount or 0))
    if inst._kei_battery_level ~= nil then
        inst._kei_battery_level:set(inst.kei_power_battery_level)
    end
    UpdateBatteryVisual(inst)
end

local function RefreshCircuit(component, dt)
    local generators = {}
    local consumers = {}
    local batteries = {}
    local generation = 0
    local demand = 0

    for _, endpoint in ipairs(component) do
        local device = endpoint:HasTag("kei_power_device") and endpoint or nil
        if device ~= nil then
            local generated = tonumber(device.kei_power_generation) or 0
            local consumed = tonumber(device.kei_power_consumption) or 0
            local signal = device.kei_power_work_signal ~= false
            local connected = next(device.kei_power_links or {}) ~= nil
            if generated > EPSILON and signal and connected then
                local availability = GetFuelAvailability(device, dt)
                if availability > EPSILON then
                    table.insert(generators, device)
                    generation = generation + generated * availability
                end
            end
            if consumed > EPSILON and signal and connected then
                table.insert(consumers, device)
                demand = demand + consumed
            end
            if (tonumber(device.kei_power_battery_capacity) or 0) > EPSILON
                and connected
            then
                table.insert(batteries, device)
            end
        end
    end

    local energy_before = 0
    local capacity = 0
    for _, battery in ipairs(batteries) do
        energy_before = energy_before + (battery.kei_power_battery_level or 0)
        capacity = capacity + battery.kei_power_battery_capacity
    end

    local energy_delta = 0
    local consumers_working = demand <= EPSILON
    if demand > EPSILON then
        local battery_power = math.max(0, energy_before / math.max(dt, POWER_TICK_INTERVAL))
        consumers_working = generation + battery_power > demand + EPSILON
        if consumers_working and generation < demand then
            energy_delta = -(demand - generation) * (dt or 0)
        end
    end

    -- Excess generator output is stored after the circuit load is satisfied.
    if consumers_working and generation > demand and capacity > energy_before then
        energy_delta = math.min(
            (generation - demand) * (dt or 0),
            capacity - energy_before)
    end

    if math.abs(energy_delta) > EPSILON and #batteries > 0 then
        local remaining = energy_delta
        for _, battery in ipairs(batteries) do
            local level = battery.kei_power_battery_level or 0
            local change
            if remaining > 0 then
                change = math.min(remaining,
                    battery.kei_power_battery_capacity - level)
            else
                change = -math.min(-remaining, level)
            end
            SetBatteryLevel(battery, level + change)
            remaining = remaining - change
            if math.abs(remaining) <= EPSILON then
                break
            end
        end
    end

    -- Build the final state first.  The old implementation cleared every
    -- device to `false` and then immediately set generators/consumers back to
    -- `true`.  For a charger this created a real pause/resume pair on every
    -- power tick; the pause dirty event could arrive after the resume event
    -- and leave the client animation frozen even though the circuit was
    -- powered.  Apply each device's final state exactly once per refresh.
    local powered_devices = {}
    for _, generator in ipairs(generators) do
        powered_devices[generator.GUID] = true
        ConsumeGeneratorFuel(generator, dt)
    end
    for _, consumer in ipairs(consumers) do
        powered_devices[consumer.GUID] = consumers_working
    end
    for _, battery in ipairs(batteries) do
        powered_devices[battery.GUID] = math.abs(energy_delta) > EPSILON
    end
    for _, endpoint in ipairs(component) do
        if endpoint:HasTag("kei_power_device") then
            SetDevicePowered(endpoint, powered_devices[endpoint.GUID] == true)
        end
    end
end

Power._devices = {}

function Power.RegisterDevice(inst)
    if not IsValid(inst) or TheWorld == nil or not TheWorld.ismastersim then
        return
    end
    Power._devices[inst.GUID] = inst
    if Power._refresh_task == nil and TheWorld ~= nil then
        Power._refresh_task = TheWorld:DoPeriodicTask(POWER_TICK_INTERVAL,
            function()
                Power.RefreshAll(POWER_TICK_INTERVAL)
            end)
    end
    inst:ListenForEvent("onremove", function(entity)
        Power.DisconnectAll(entity)
        Power._devices[entity.GUID] = nil
    end)
end

function Power.RefreshAll(dt)
    local visited = {}
    for _, device in pairs(Power._devices) do
        if IsValid(device) and not visited[device.GUID] then
            local component = GetConnectedComponent(device)
            for _, endpoint in ipairs(component) do
                visited[endpoint.GUID] = true
            end
            RefreshCircuit(component, dt or 0)
        end
    end
end

RemoveRoutePieces = function(route)
    if route == nil or route.pieces == nil then
        return
    end
    for _, piece in ipairs(route.pieces) do
        if IsValid(piece) then
            piece:Remove()
        end
    end
    route.pieces = nil
end

function Power.DisconnectNodes(source, target)
    if not IsValid(source) or not IsValid(target) then
        return false
    end

    local route = source.kei_power_routes ~= nil and source.kei_power_routes[target.GUID] or nil
    if route ~= nil then
        RemoveRoutePieces(route)
    end
    if source.kei_power_routes ~= nil then source.kei_power_routes[target.GUID] = nil end
    if target.kei_power_routes ~= nil then target.kei_power_routes[source.GUID] = nil end
    if source.kei_power_links ~= nil then source.kei_power_links[target.GUID] = nil end
    if target.kei_power_links ~= nil then target.kei_power_links[source.GUID] = nil end
    -- A signal node may become single-ended after a disconnect.  Rebuild its
    -- remaining signal routes so the one-way endpoint piece is restored.
    RefreshSignalRoutes(source, route)
    RefreshSignalRoutes(target, route)
    UpdateNodeAnimation(source)
    UpdateNodeAnimation(target)
    RefreshDevicePower(source)
    RefreshDevicePower(target)
    Power.RefreshAll(0)
    return route ~= nil
end

function Power.DisconnectRoute(route)
    if route == nil
        or not IsValid(route.source)
        or not IsValid(route.target_endpoint)
    then
        return false
    end
    return Power.DisconnectNodes(route.source, route.target_endpoint)
end

function Power.DisconnectAll(inst)
    if not IsValid(inst) then
        return
    end
    local targets = {}
    for _, target in pairs(inst.kei_power_links or {}) do
        table.insert(targets, target)
    end
    for _, target in ipairs(targets) do
        Power.DisconnectNodes(inst, target)
    end
    inst.kei_power_links = {}
    inst.kei_power_routes = {}
end

function Power.ConnectNodes(source, target, grade, wire_kind)
    if not Power.CanConnectNodes(source, target, grade, wire_kind) then
        return false
    end
    if source.kei_power_links ~= nil and source.kei_power_links[target.GUID] ~= nil then
        return false
    end

    local route = Power.BuildPath(source, target)
    if route == nil then
        local source_point = GetPoint(source)
        local target_point = GetPoint(target)
        if source_point == nil or target_point == nil
            or DistanceSquared(source_point, target_point) > EPSILON * EPSILON
        then
            return false
        end
        -- A device placed on top of a node is a logical connection even
        -- though it needs no visible wire segment.
        route = {
            start = source_point,
            target = target_point,
            source = source,
            target_endpoint = target,
            segments = {},
        }
    end

    route.pieces = {}
    local kind = wire_kind or source.kei_power_wire_kind or "power"
    local build = kind == "signal"
        and "kei_logic_wires"
        or (grade or source.kei_power_grade or "kei_utilities_electric")
    route.source = source
    route.target_endpoint = target
    route.grade = build
    route.wire_kind = kind
    for _, segment in ipairs(Power.GetVisualSegments(route, build, kind)) do
        local piece = SpawnWirePiece(segment, build, route, kind)
        if piece == nil then
            RemoveRoutePieces(route)
            return false
        end
        table.insert(route.pieces, piece)
    end
    local corner = SpawnWireCorner(route, build, kind)
    if route.corner ~= nil and corner == nil then
        RemoveRoutePieces(route)
        return false
    end
    if corner ~= nil then table.insert(route.pieces, corner) end

    source.kei_power_links = source.kei_power_links or {}
    target.kei_power_links = target.kei_power_links or {}
    source.kei_power_routes = source.kei_power_routes or {}
    target.kei_power_routes = target.kei_power_routes or {}
    source.kei_power_links[target.GUID] = target
    target.kei_power_links[source.GUID] = source
    source.kei_power_routes[target.GUID] = route
    target.kei_power_routes[source.GUID] = route
    -- Existing signal routes need to be rebuilt after this connection is
    -- added: a node that has become multi-directional must lose its old
    -- endpoint one-way piece as well.
    RefreshSignalRoutes(source, route)
    RefreshSignalRoutes(target, route)

    UpdateNodeAnimation(source)
    UpdateNodeAnimation(target)

    Power.RefreshAll(0)
    return true
end

function Power.SaveConnections(inst, data)
    if not IsValid(inst) or data == nil then
        return
    end
    local connections = {}
    for guid, target in pairs(inst.kei_power_links or {}) do
        local route = inst.kei_power_routes ~= nil and inst.kei_power_routes[guid] or nil
        table.insert(connections, {
            target = guid,
            grade = route ~= nil and route.grade or inst.kei_power_grade,
            wire_kind = route ~= nil and route.wire_kind or inst.kei_power_wire_kind,
        })
    end
    if #connections > 0 then data.kei_power_connections = connections end
end

function Power.LoadConnections(inst, newents, data)
    if not IsValid(inst) or data == nil or data.kei_power_connections == nil then
        return
    end
    for _, connection in ipairs(data.kei_power_connections) do
        local saved = newents ~= nil and newents[connection.target] or nil
        local target = saved ~= nil and saved.entity or nil
        if target ~= nil and inst.GUID < target.GUID then
            Power.ConnectNodes(inst, target, connection.grade, connection.wire_kind)
        end
    end
end

function Power.GetPreviewPath(source, target)
    return Power.BuildPath(source, target)
end

return Power
