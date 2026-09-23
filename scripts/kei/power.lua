-- Player interaction layer for the electricity prototype.
-- The server owns the selected endpoint; the client mirrors it for preview.

local Power = require("kei/power_system")

local function SetPreviewWireScale(part, animation, scale)
    scale = scale or 1
    if animation == "UD" then
        part.AnimState:SetScale(1, scale)
    elseif animation == "LR" then
        part.AnimState:SetScale(scale, 1)
    else
        part.AnimState:SetScale(1, 1)
    end
end

local function ApplyPreviewGeometry(part, animation, length)
    animation = animation or "LR"
    part.AnimState:PlayAnimation(animation, true)
    -- Wire preview pieces use the same native-size geometry as the pieces
    -- spawned by the server.  `length` is retained in the helper signature
    -- because preview data is shared with the route splitter.
    SetPreviewWireScale(part, animation, length)
    local is_one_way = animation == "L"
        or animation == "U"
        or animation == "D"
        or animation == "R"
    local is_corner = animation == "LD"
        or animation == "LU"
        or animation == "RD"
        or animation == "RU"
        or animation == "LR_UD_Bridge"
    part.AnimState:SetLayer(LAYER_BACKGROUND)
    part.AnimState:SetSortOrder(is_one_way and -1 or (is_corner and 1 or 0))
end

AddModRPCHandler("TendouKei", "CancelPowerWireConnection", function(player)
    if player ~= nil then
        player.kei_power_wire_source = nil
    end
end)

local function IsPowerWire(item)
    return Power.IsWireItem(item)
end

local function GetWallPlacementPoint(doer, fallback)
    -- The wall placer has already resolved the cursor to the canonical wall
    -- point.  POINT actions normally receive the raw cursor position, which
    -- can differ from the position shown by the placer by a fraction of a
    -- tile.  Use the placer when it is available, while retaining the
    -- fallback for server-side actions where the client placer does not
    -- exist.
    local controller = doer ~= nil and doer.components ~= nil
        and doer.components.playercontroller or nil
    local placer = controller ~= nil and controller.deployplacer or nil
    if placer ~= nil and placer:IsValid() then
        return placer:GetPosition()
    end
    return fallback
end

local function CanPlacePowerNode(item, pos, doer)
    if item == nil or item.replica == nil
        or item.replica.inventoryitem == nil
        or pos == nil
    then
        return false
    end
    local snapped = Power.SnapWallPoint(pos)
    if item.components ~= nil and item.components.deployable ~= nil then
        return item.components.deployable:CanDeploy(snapped, nil, doer, 0)
    end
    return item.replica.inventoryitem:CanDeploy(snapped, nil, doer, 0)
end

local function ConsumeOne(item)
    if item ~= nil and item.components ~= nil and item.components.stackable ~= nil then
        local one = item.components.stackable:Get()
        if one ~= nil then
            one:Remove()
        end
    elseif item ~= nil then
        item:Remove()
    end
end

local CHARGER_PREFAB = "kei_electrobank_charger_small"

local function IsCharger(inst)
    return inst ~= nil and inst.prefab == CHARGER_PREFAB
end

local function IsEmptyElectrobank(item)
    return item ~= nil and item.prefab == "kei_emptyelectrobank"
end

local function IsFullElectrobank(item)
    return item ~= nil and item.prefab == "kei_electrobank"
end

local function GetChargerSlot(inst)
    local container = inst ~= nil and inst.components ~= nil
        and inst.components.container or nil
    return container ~= nil and container:GetItemInSlot(1) or nil
end

local function GetChargerReplicaSlot(inst)
    local container = inst ~= nil and inst.replica ~= nil
        and inst.replica.container or nil
    return container ~= nil and container:GetItemInSlot(1) or nil
end

local function GetChargerContentsState(inst)
    if inst ~= nil and inst._kei_charger_contents ~= nil then
        return inst._kei_charger_contents:value()
    end

    local item = GetChargerReplicaSlot(inst)
    return IsFullElectrobank(item) and 2 or (IsEmptyElectrobank(item) and 1 or 0)
end

local function GetActiveItem(doer)
    local inventory = doer ~= nil and doer.replica ~= nil
        and doer.replica.inventory or nil
    return inventory ~= nil and inventory:GetActiveItem() or nil
end

local function ChargerCanReceiveEmptyBattery(charger, item)
    return IsCharger(charger)
        and IsEmptyElectrobank(item)
        and GetChargerContentsState(charger) == 0
end

local function InsertElectrobankIntoCharger(act)
    local charger = act ~= nil and act.target or nil
    local item = act ~= nil and act.invobject or nil
    local inventory = act ~= nil and act.doer ~= nil
        and act.doer.components ~= nil and act.doer.components.inventory or nil
    local container = charger ~= nil and charger.components ~= nil
        and charger.components.container or nil
    if charger == nil or not IsCharger(charger)
        or not IsEmptyElectrobank(item)
        or inventory == nil or container == nil
        or container:GetItemInSlot(1) ~= nil
        or not container:CanTakeItemInSlot(item, 1)
    then
        return false
    end

    -- Remove exactly one battery from a stack, then put that same instance in
    -- the hidden charger slot. GiveItem emits itemget, which starts charging
    -- through the existing charger state machine.
    local battery = inventory:RemoveItem(item)
    if battery == nil then
        return false
    end
    if container:GiveItem(battery, 1, act.doer:GetPosition(), false) then
        return true
    end

    inventory:GiveItem(battery)
    return false
end

local function HarvestChargedElectrobank(act)
    local charger = act ~= nil and act.target or nil
    local inventory = act ~= nil and act.doer ~= nil
        and act.doer.components ~= nil and act.doer.components.inventory or nil
    local container = charger ~= nil and charger.components ~= nil
        and charger.components.container or nil
    if charger == nil or not IsCharger(charger)
        or inventory == nil or container == nil
        or not IsFullElectrobank(container:GetItemInSlot(1))
    then
        return false
    end

    local battery = container:RemoveItemBySlot(1)
    if battery == nil then
        return false
    end

    -- Inventory:GiveItem handles a full inventory by dropping the item at the
    -- player's feet, so harvesting never destroys a completed battery.
    inventory:GiveItem(battery)
    return true
end

local charger_insert_action = AddAction(
    "KEI_CHARGER_INSERT",
    "充电",
    InsertElectrobankIntoCharger
)
charger_insert_action.priority = 25

local charger_harvest_action = AddAction(
    "KEI_CHARGER_HARVEST",
    "收获电池",
    HarvestChargedElectrobank
)
charger_harvest_action.priority = 25

AddStategraphActionHandler(
    "wilson",
    ActionHandler(ACTIONS.KEI_CHARGER_INSERT, "doshortaction")
)
AddStategraphActionHandler(
    "wilson_client",
    ActionHandler(ACTIONS.KEI_CHARGER_INSERT, "doshortaction")
)
AddStategraphActionHandler(
    "wilson",
    ActionHandler(ACTIONS.KEI_CHARGER_HARVEST, "doshortaction")
)
AddStategraphActionHandler(
    "wilson_client",
    ActionHandler(ACTIONS.KEI_CHARGER_HARVEST, "doshortaction")
)

-- These actions deliberately bypass the vanilla container component actions:
-- a closed charger accepts an empty battery without opening its one-slot
-- widget. Harvesting is exposed by the charger's inspectable scene action so
-- it remains available even though the container replica is closed.
AddComponentAction("SCENE", "container", function(target, doer, actions)
    -- A charger is still represented by a hidden container internally.  The
    -- action picker can therefore enter SCENE instead of USEITEM when the
    -- player is holding an active item, especially on the right-click path.
    -- Handle insertion here as well so that opening the container is never
    -- required to put in an empty battery.
    local active_item = GetActiveItem(doer)
    if ChargerCanReceiveEmptyBattery(target, active_item) then
        table.insert(actions, ACTIONS.KEI_CHARGER_INSERT)
    end
end)

local place_node_action = AddAction("KEI_POWER_PLACE_NODE", "建立节点", function(act)
    local item = act.invobject
    local pt = GetWallPlacementPoint(act.doer, act:GetActionPoint())
    if not IsPowerWire(item) or pt == nil then
        return false
    end
    if act.doer.kei_power_wire_source ~= nil then
        act.doer.kei_power_wire_source = nil
        return true
    end
    if item.components == nil
        or item.components.deployable == nil
        or not CanPlacePowerNode(item, pt, act.doer)
    then
        return false
    end
    return Power.PlaceNode(item, pt, item.kei_power_grade, item.kei_power_wire_kind)
end)
place_node_action.rmb = true
place_node_action.priority = 20
AddStategraphActionHandler("wilson", ActionHandler(ACTIONS.KEI_POWER_PLACE_NODE, "doshortaction"))
AddStategraphActionHandler("wilson_client", ActionHandler(ACTIONS.KEI_POWER_PLACE_NODE, "doshortaction"))

local connect_action = AddAction("KEI_POWER_CONNECT", "连接电线", function(act)
    local item = act.invobject
    local target = act.target
    if not IsPowerWire(item)
        or not Power.IsCompatibleEndpoint(target, item.kei_power_grade, item.kei_power_wire_kind)
    then
        return false
    end

    local doer = act.doer
    local source = doer.kei_power_wire_source
    if source == nil or not source:IsValid() then
        doer.kei_power_wire_source = target
        return true
    end

    if not Power.CanConnectNodes(source, target, item.kei_power_grade, item.kei_power_wire_kind) then
        doer.kei_power_wire_source = nil
        return false
    end

    local connected = Power.ConnectNodes(source, target, item.kei_power_grade, item.kei_power_wire_kind)
    doer.kei_power_wire_source = nil
    if connected then
        ConsumeOne(item)
    end
    return connected
end)
connect_action.rmb = true
connect_action.priority = 25
connect_action.pre_action_cb = function(act)
    if TheWorld ~= nil and not TheWorld.ismastersim and ThePlayer ~= nil then
        -- Mirror the two-click endpoint state locally so preview responds
        -- before the server action roundtrip completes.
        if ThePlayer.kei_power_wire_source == nil then
            ThePlayer.kei_power_wire_source = act.target
        else
            ThePlayer.kei_power_wire_source = nil
        end
    end
end
AddStategraphActionHandler("wilson", ActionHandler(ACTIONS.KEI_POWER_CONNECT, "doshortaction"))
AddStategraphActionHandler("wilson_client", ActionHandler(ACTIONS.KEI_POWER_CONNECT, "doshortaction"))

AddComponentAction("POINT", "inventoryitem", function(item, doer, pos, actions, right)
    local placement_pos = GetWallPlacementPoint(doer, pos)
    if right
        and IsPowerWire(item)
        and placement_pos ~= nil
        and item.replica ~= nil
        and item.replica.inventoryitem ~= nil
        and CanPlacePowerNode(item, placement_pos, doer)
    then
        table.insert(actions, ACTIONS.KEI_POWER_PLACE_NODE)
    end
end)

if not TheNet:IsDedicated() and TheInput ~= nil then
    local preview_parts = {}
    local last_had_wire = false

    local function ClearPreview()
        for _, part in ipairs(preview_parts) do
            if part:IsValid() then
                part:Remove()
            end
        end
        preview_parts = {}
    end

    local function MakePreviewPart(grade, animation, length, x, z, wire_kind)
        local part = CreateEntity()
        part:AddTag("CLASSIFIED")
        part:AddTag("NOCLICK")
        part:AddTag("placer")
        part.persists = false
        part.entity:SetCanSleep(false)
        part.entity:AddTransform()
        part.entity:AddAnimState()
        part.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
        local bank = wire_kind == "signal" and "kei_logic_wires" or grade
        part.AnimState:SetBank(bank)
        part.AnimState:SetBuild(bank)
        ApplyPreviewGeometry(part, animation, length)
        part.AnimState:SetMultColour(0.3, 0.9, 1, 0.65)
        part.AnimState:SetLightOverride(1)
        part.Transform:SetPosition(x, 0, z)
        return part
    end

    local function RefreshPreview()
        local player = ThePlayer
        local item = player ~= nil and player.replica.inventory ~= nil
            and player.replica.inventory:GetActiveItem() or nil
        local source = player ~= nil and player.kei_power_wire_source or nil
        if player == nil or not IsPowerWire(item) or source == nil or not source:IsValid() then
            if player ~= nil and not IsPowerWire(item) then
                if last_had_wire and player.kei_power_wire_source ~= nil
                    and MOD_RPC ~= nil
                    and MOD_RPC.TendouKei ~= nil
                    and MOD_RPC.TendouKei.CancelPowerWireConnection ~= nil
                then
                    SendModRPCToServer(MOD_RPC.TendouKei.CancelPowerWireConnection)
                end
                player.kei_power_wire_source = nil
            end
            last_had_wire = IsPowerWire(item)
            ClearPreview()
            return
        end
        last_had_wire = true

        local target = TheInput:GetWorldEntityUnderMouse()
        if target == nil
            or not Power.CanConnectNodes(source, target, item.kei_power_grade, item.kei_power_wire_kind)
        then
            ClearPreview()
            return
        end

        local route = Power.GetPreviewPath(source, target)
        if route == nil then
            ClearPreview()
            return
        end

        ClearPreview()
        for _, segment in ipairs(Power.GetVisualSegments(
            route,
            item.kei_power_grade,
            item.kei_power_wire_kind
        )) do
            local x = (segment.start.x + segment.target.x) * 0.5
            local z = (segment.start.z + segment.target.z) * 0.5
            table.insert(preview_parts, MakePreviewPart(
                item.kei_power_grade,
                segment.animation,
                segment.scale,
                x,
                z,
                item.kei_power_wire_kind
            ))
        end
        if route.corner ~= nil then
            table.insert(preview_parts, MakePreviewPart(
                item.kei_power_grade,
                route.corner_animation,
                1,
                route.corner.x,
                route.corner.z,
                item.kei_power_wire_kind
            ))
        end
    end

    TheInput:AddMoveHandler(RefreshPreview)
    TheInput:AddMouseButtonHandler(function(button, down)
        if down and button == MOUSEBUTTON_RIGHT then
            RefreshPreview()
        end
    end)

    AddPlayerPostInit(function(player)
        player:DoPeriodicTask(0.1, function()
            if ThePlayer == player then
                RefreshPreview()
            end
        end)
        player:ListenForEvent("onremove", ClearPreview)
    end)
end
