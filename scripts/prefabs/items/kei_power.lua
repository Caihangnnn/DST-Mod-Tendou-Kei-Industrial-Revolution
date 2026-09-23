require("prefabutil")

local Power = require("kei/power_system")

local IR_ATLAS = "images/inventoryimages/kei_items_ir.xml"

-- InventoryItem:ChangeImageName receives the atlas element basename and adds
-- ".tex" itself when it is networked.  Passing "foo.tex" would therefore
-- look up "foo.tex.tex" and leave the inventory icon blank.
local function InventoryImageName(image)
    return image ~= nil and image:gsub("%.tex$", "") or nil
end

local function ConsumeOne(inst)
    if inst ~= nil and inst.components.stackable ~= nil then
        local one = inst.components.stackable:Get()
        if one ~= nil then
            one:Remove()
        end
    elseif inst ~= nil then
        inst:Remove()
    end
end

local function GiveOrDropEmptyElectrobank(eater)
    local empty = SpawnPrefab("kei_emptyelectrobank")
    if empty == nil then
        return
    end

    local inventory = eater ~= nil and eater.components ~= nil
        and eater.components.inventory or nil
    if inventory ~= nil and inventory:GiveItem(empty) then
        return
    end

    -- The source battery is consumed after OnEaten returns.  If the new empty
    -- battery cannot fit in the inventory, leave it at the eater's feet.
    if eater ~= nil and eater.Transform ~= nil then
        local x, y, z = eater.Transform:GetWorldPosition()
        if empty.Physics ~= nil then
            empty.Physics:Teleport(x, y, z)
        else
            empty.Transform:SetPosition(x, y, z)
        end
    end
    if empty.components ~= nil and empty.components.inventoryitem ~= nil then
        empty.components.inventoryitem:OnDropped(true, 0.5)
    end
end

local function ElectrobankOnEaten(inst, eater)
    if eater == nil or eater.components == nil then
        return
    end

    if eater.components.hunger ~= nil then
        -- This is intentionally an absolute restore rather than a +100 value:
        -- the battery always leaves the user's power at 100% of its maximum.
        eater.components.hunger:SetPercent(1)
    end

    if eater.components.talker ~= nil
        and STRINGS.CHARACTERS.KEI ~= nil
        and STRINGS.CHARACTERS.KEI.ANNOUNCE_KEI_CHARGED ~= nil
    then
        eater.components.talker:Say(STRINGS.CHARACTERS.KEI.ANNOUNCE_KEI_CHARGED)
    end

    GiveOrDropEmptyElectrobank(eater)
end

local function MakeElectrobankItem(prefab, animation, image, on_eaten)
    local assets = {
        Asset("ANIM", "anim/kei_electrobank.zip"),
        Asset("ATLAS", IR_ATLAS),
        Asset("IMAGE", "images/inventoryimages/kei_items_ir.tex"),
    }

    local function fn()
        local inst = CreateEntity()
        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)
        inst.AnimState:SetBank("kei_electrobank")
        inst.AnimState:SetBuild("kei_electrobank")
        -- The item uses the authored ground animation, not the building
        -- animation or a deploy placer.
        inst.AnimState:PlayAnimation(animation, true)
        inst.AnimState:SetScale(1.5, 1.5)
        inst:AddTag("kei_mobile_battery")

        MakeInventoryFloatable(inst, "small", nil, 0.8)
        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = IR_ATLAS
        inst.components.inventoryitem:ChangeImageName(image)

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        if on_eaten ~= nil then
            inst:AddComponent("edible")
            inst.components.edible.foodtype = FOODTYPE.KEI_DEVICE
            inst.components.edible.healthvalue = 0
            inst.components.edible.hungervalue = 0
            inst.components.edible.sanityvalue = 0
            inst.components.edible:SetOnEatenFn(on_eaten)
            inst:AddTag("quickeat")
        end

        MakeHauntableLaunch(inst)
        return inst
    end

    return Prefab(prefab, fn, assets)
end

local function MakeDeviceItem(prefab, deployed_prefab, bank, build, image)
    local assets = {
        Asset("ANIM", "anim/" .. build .. ".zip"),
        Asset("ATLAS", IR_ATLAS),
        Asset("IMAGE", "images/inventoryimages/kei_items_ir.tex"),
    }
    local function fn()
        local inst = CreateEntity()
        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()
        MakeInventoryPhysics(inst)
        inst.AnimState:SetBank(bank)
        inst.AnimState:SetBuild(build)
        -- Ground item appearance.  The placement preview keeps its own
        -- animation below; this is the dropped/in-world item entity.
        inst.AnimState:PlayAnimation("ui", true)
        inst:AddTag("kei_power_device_item")
        inst._custom_candeploy_fn = function(item, pt, mouseover, deployer, rot)
            return Power.CanDeployDevice(item, pt, mouseover, deployer, rot)
        end
        inst.entity:SetPristine()
        if not TheWorld.ismastersim then
            return inst
        end
        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = IR_ATLAS
        inst.components.inventoryitem:ChangeImageName(InventoryImageName(image))
        inst:AddComponent("deployable")
        inst.components.deployable.ondeploy = function(item, pt, deployer)
            local center = Power.GetDeviceTileCenter(pt)
            if center == nil or Power.IsDeviceTileOccupied(center) then
                return
            end
            local structure = SpawnPrefab(deployed_prefab)
            if structure ~= nil then
                local x, _, z = center:Get()
                structure.Transform:SetPosition(x, 0, z)
                structure:PushEvent("onbuilt", { builder = deployer, pos = Vector3(x, 0, z), deployable = item })
                ConsumeOne(item)
            end
        end
        inst.components.deployable._custom_candeploy_fn = inst._custom_candeploy_fn
        inst.components.deployable:SetDeployMode(DEPLOYMODE.CUSTOM)
        inst.components.deployable:SetDeploySpacing(DEPLOYSPACING.LESS)
        return inst
    end
    return Prefab(prefab, fn, assets),
        MakePlacer(prefab .. "_placer", build, build, "ui_place", false, true, nil, nil, nil, "eight")
end

local function MakeWireItem(prefab, build, image, wire_kind, node_prefab)
    local assets = {
        Asset("ANIM", "anim/" .. build .. ".zip"),
        Asset("ATLAS", IR_ATLAS),
        Asset("IMAGE", "images/inventoryimages/kei_items_ir.tex"),
    }
    local function fn()
        local inst = CreateEntity()
        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()
        MakeInventoryPhysics(inst)
        inst.AnimState:SetBank(build)
        inst.AnimState:SetBuild(build)
        -- Ground item appearance.  Wire connection geometry belongs to the
        -- deployed node/segment prefabs, not to this inventory item.
        inst.AnimState:PlayAnimation("ui", true)
        inst:AddTag("kei_power_wire_item")
        inst.kei_power_grade = build
        inst.kei_power_wire_kind = wire_kind or "power"
        inst.kei_power_node_prefab = node_prefab
        inst.entity:SetPristine()
        if not TheWorld.ismastersim then
            return inst
        end
        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = IR_ATLAS
        inst.components.inventoryitem:ChangeImageName(InventoryImageName(image))
        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_MEDITEM
        inst:AddComponent("deployable")
        inst.components.deployable.ondeploy = function(item, pt)
            Power.PlaceNode(item, pt, build, wire_kind)
        end
        -- Match the game's wall placement. Power.PlaceNode also repeats the
        -- snap on the server because the custom RMB action receives raw input.
        inst.components.deployable:SetDeployMode(DEPLOYMODE.WALL)
        inst.components.deployable:SetDeploySpacing(DEPLOYSPACING.LESS)
        return inst
    end
    return Prefab(prefab, fn, assets),
        MakePlacer(prefab .. "_placer", build, build, "None_place", false, false, true, nil, nil, "eight")
end

local prefabs = {}
local generator, generator_placer = MakeDeviceItem("kei_dev_generator_item", "kei_dev_generator", "kei_dev_generator", "kei_dev_generator", "kei_dev_generator.tex")
table.insert(prefabs, generator)
table.insert(prefabs, generator_placer)
local battery, battery_placer = MakeDeviceItem("kei_batterysm_item", "kei_batterysm", "kei_batterySm", "kei_batterysm", "kei_batterysm.tex")
table.insert(prefabs, battery)
table.insert(prefabs, battery_placer)
-- Mobile batteries are inventory items rather than placeable power devices.
-- A full one restores Kei's hunger/power to 100% and returns an empty one.
table.insert(prefabs, MakeElectrobankItem(
    "kei_electrobank",
    "ui",
    "kei_electrobank",
    ElectrobankOnEaten
))
table.insert(prefabs, MakeElectrobankItem(
    "kei_emptyelectrobank",
    "kei_emptyelectrobank",
    "kei_emptyelectrobank"
))
local charger, charger_placer = MakeDeviceItem(
    "kei_electrobank_charger_small_item",
    "kei_electrobank_charger_small",
    "kei_electrobank_charger_small",
    "kei_electrobank_charger_small",
    "kei_electrobank_charger_small.tex"
)
table.insert(prefabs, charger)
table.insert(prefabs, charger_placer)
local wire, wire_placer = MakeWireItem(
    "kei_utilities_electric_item",
    "kei_utilities_electric",
    "kei_utilities_electric.tex",
    "power",
    "kei_power_wire_node"
)
table.insert(prefabs, wire)
table.insert(prefabs, wire_placer)
local conduct, conduct_placer = MakeWireItem(
    "kei_utilities_electric_conduct_item",
    "kei_utilities_electric_conduct",
    "kei_utilities_electric_conduct.tex",
    "power",
    "kei_power_conduct_wire_node"
)
table.insert(prefabs, conduct)
table.insert(prefabs, conduct_placer)
local hiwatt, hiwatt_placer = MakeWireItem(
    "kei_utilities_electric_conduct_hiwatt_item",
    "kei_utilities_electric_conduct_hiwatt",
    "kei_utilities_electric_conduct_hiwatt.tex",
    "power",
    "kei_power_hiwatt_wire_node"
)

local signal, signal_placer = MakeWireItem(
    "kei_logic_wires_item",
    "kei_logic_wires",
    "kei_logic_wires.tex",
    "signal",
    "kei_logic_wire_node"
)
table.insert(prefabs, signal)
table.insert(prefabs, signal_placer)
table.insert(prefabs, hiwatt)
table.insert(prefabs, hiwatt_placer)

return unpack(prefabs)
