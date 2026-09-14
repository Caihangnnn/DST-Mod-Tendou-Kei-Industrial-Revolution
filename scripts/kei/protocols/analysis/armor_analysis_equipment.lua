local AnalysisArmorUpgrade = require("kei/analysis_armor_upgrade")
local VirtualEquipment = require("kei/protocols/analysis/virtual_equipment")
local Enchantment = require("kei/integrations/enchantment")

local ArmorAnalysisEquipment = {}

-- 根据护甲强化配方制作次数计算护甲吸收缩放：初始 50%，每次增加 10%。
-- 将解析装备提供的护甲吸收率应用到虚拟护甲上
-- 可使用协议数据中的 absorb 覆盖原护甲吸收，否则继承预制体自身的吸收率
local function ApplyArmorAbsorb(virtual, data, absorb_scale)
    local armor = virtual ~= nil and virtual.components ~= nil and virtual.components.armor or nil
    if armor == nil then return end

    local absorb = data ~= nil and data.absorb or nil
    if absorb == nil then
        absorb = armor.absorb_percent
    end
    if absorb == nil then return end

    if armor.SetAbsorption ~= nil then
        armor:SetAbsorption(absorb * absorb_scale)
    else
        armor.absorb_percent = absorb * absorb_scale
    end
end

-- 清理虚拟护甲的交互与持久化能力，使其只作为 Kei 私有状态的载体存在。
-- 虚拟护甲不再写入 inventory.equipslots；这能避免它参与原版装备栏重建、
-- inventory classified 同步，以及其它模组对全局 EQUIPSLOTS 的遍历。
local function CleanVirtualEquipment(item)
    item.persists = false
    item:AddTag("kei_virtual_equipment")
    item:AddTag("NOCLICK")
    item:RemoveTag("heavy")
    item:RemoveTag("repairable")

    if item.components.equippable ~= nil then
        VirtualEquipment.GuardBuildDiscount(item)
        -- Keep source equip callbacks while build discount is enabled. Some
        -- equipment applies its ingredient modifier from OnEquip.
        if TUNING.KEI_VIRTUAL_EQUIPMENT_BUILD_DISCOUNT == false then
            item.components.equippable:SetOnEquip(nil)
            item.components.equippable:SetOnUnequip(nil)
        end
        item.components.equippable.restrictedtag = nil
        -- 保留预制体默认装备类型给其自身回调使用，但不把它映射到
        -- Kei 的公共/隐藏装备槽。真正的归属由 protocolslots.virtual_equips 记录。
        item.components.equippable:SetPreventUnequipping(true)
    end

    if item.components.container ~= nil then
        item:RemoveComponent("container")
    end

    if item.components.inventoryitem ~= nil then
        item.components.inventoryitem.canbepickedup = false
        item.components.inventoryitem.cangoincontainer = false
        item.components.inventoryitem.keepondeath = true
    end

    if item.components.trader ~= nil then
        item:RemoveComponent("trader")
    end

    if item.components.repairable ~= nil then
        item:RemoveComponent("repairable")
    end

    -- Keep durability-related components available for source callbacks, but
    -- freeze the virtual copy so its state cannot change.
    VirtualEquipment.LockDurability(item)

end

-- 延迟移除虚拟护甲，避免在装备或卸下流程的回调链里直接删除实体
local function ScheduleRemove(item)
    if item == nil or not item:IsValid() or item.kei_pending_virtual_remove then return end

    item.kei_pending_virtual_remove = true
    item.persists = false
    item:Hide()
    item:DoTaskInTime(0.1, function(inst)
        if inst:IsValid() then
            inst:Remove()
        end
    end)
end

local function AttachVirtualEquipment(owner, item)
    if owner == nil or item == nil then
        return false
    end

    local inventoryitem = item.components ~= nil and item.components.inventoryitem or nil
    if inventoryitem ~= nil and inventoryitem.OnPutInInventory ~= nil then
        inventoryitem:OnPutInInventory(owner)
    end

    local equippable = item.components ~= nil and item.components.equippable or nil
    if equippable == nil or equippable.Equip == nil then
        if inventoryitem ~= nil and inventoryitem.OnRemoved ~= nil then
            inventoryitem:OnRemoved()
        end
        return false
    end

    equippable:Equip(owner, false)
    return true
end

local function DetachVirtualEquipment(owner, item)
    if item == nil then
        return
    end

    local equippable = item.components ~= nil and item.components.equippable or nil
    if equippable ~= nil and equippable.IsEquipped ~= nil and equippable:IsEquipped() then
        equippable:Unequip(owner)
    end

    local inventoryitem = item.components ~= nil and item.components.inventoryitem or nil
    if inventoryitem ~= nil and inventoryitem.OnRemoved ~= nil and inventoryitem:IsHeld() then
        inventoryitem:OnRemoved()
    end
end

-- 移除指定协议槽当前挂载的虚拟护甲，并从 Kei 私有状态中卸下后清理实体。
function ArmorAnalysisEquipment.Remove(protocolslots, slot)
    local virtual = protocolslots.virtual_equips[slot]
    if virtual == nil then return end

    DetachVirtualEquipment(protocolslots.inst, virtual)

    if virtual:IsValid() then
        ScheduleRemove(virtual)
    end
    protocolslots.virtual_equips[slot] = nil
end

-- 根据协议数据生成并挂载指定槽位的虚拟护甲。
-- 这里的“挂载”是 Kei 私有协议状态，不是 DST Inventory 的装备槽。
-- 如果同源虚拟护甲已经存在，则只更新吸收率而不重复生成
function ArmorAnalysisEquipment.Apply(protocolslots, entry)
    local data = entry.data
    local slot = entry.slot

    if data.source == nil then
        ArmorAnalysisEquipment.Remove(protocolslots, slot)
        return
    end

    local current = protocolslots.virtual_equips[slot]
    local enchantment_key = Enchantment.GetKey(data.enchantments)
    if current ~= nil
        and current:IsValid()
        and current.kei_source_prefab == data.source
        and current.kei_enchantment_key == enchantment_key
        and current.components ~= nil
        and current.components.equippable ~= nil
        and current.components.equippable:IsEquipped()
    then
        ApplyArmorAbsorb(current, data, AnalysisArmorUpgrade.GetAbsorbScale(protocolslots.inst))
        return
    end

    ArmorAnalysisEquipment.Remove(protocolslots, slot)

    local virtual = SpawnPrefab(data.source)
    if virtual == nil or virtual.components.equippable == nil then
        if virtual ~= nil then virtual:Remove() end
        return
    end

    virtual.kei_source_prefab = data.source
    virtual.kei_enchantment_key = enchantment_key
    Enchantment.Apply(virtual, data.enchantments)
    CleanVirtualEquipment(virtual)
    Enchantment.InstallVirtualArmorCallbacks(virtual)
    ApplyArmorAbsorb(virtual, data, AnalysisArmorUpgrade.GetAbsorbScale(protocolslots.inst))

    if AttachVirtualEquipment(protocolslots.inst, virtual) then
        virtual._kei_virtual_protocol_slot = slot
        virtual._kei_virtual_protocol_owner = protocolslots.inst
        virtual._kei_virtual_protocol_onremove = function(item)
            if protocolslots.virtual_equips[slot] == item then
                protocolslots.virtual_equips[slot] = nil
                protocolslots._protocol_state_dirty = true
                protocolslots:ScheduleRefresh()
            end
        end
        virtual:ListenForEvent("onremove", virtual._kei_virtual_protocol_onremove)
        protocolslots.virtual_equips[slot] = virtual
    else
        ScheduleRemove(virtual)
    end
end

-- 清空当前所有虚拟护甲，可通过 keep 表保留指定槽位
function ArmorAnalysisEquipment.Clear(protocolslots, keep)
    for slot in pairs(protocolslots.virtual_equips) do
        if keep == nil or not keep[slot] then
            ArmorAnalysisEquipment.Remove(protocolslots, slot)
        end
    end
end

return ArmorAnalysisEquipment
