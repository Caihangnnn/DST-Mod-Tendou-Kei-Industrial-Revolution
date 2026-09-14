local GrowthRecipes = require("kei/growth_recipes")
local MiniAlice = require("kei/mini_alice")
local SpDamageUtil = require("components/spdamageutil")
local FISH_CALL_RECIPE = "kei_fish_call_spell"
local FULLMOON_RECIPE = "kei_fullmoon_spell"
local NEWMOON_RECIPE = "kei_newmoon_spell"
local RIPEN_RECIPE = "kei_ripen_spell"
local WEATHER_RECIPE = "kei_weather_spell"

AddComponentPostInit("builder", function(self)
    local old_HasCharacterIngredient = self.HasCharacterIngredient
    local old_RemoveIngredients = self.RemoveIngredients
    local old_DoBuild = self.DoBuild

    function self:HasCharacterIngredient(ingredient)
        if GrowthRecipes.IsExperienceIngredient(ingredient) then
            local amount = GrowthRecipes.GetExperienceIngredientAmount(ingredient, self.inst)
            ingredient.amount = amount
            return GrowthRecipes.HasEnoughExperienceIngredient(self.inst, ingredient), amount
        end
        return old_HasCharacterIngredient(self, ingredient)
    end

    function self:RemoveIngredients(ingredients, recname, discounted, ...)
        GrowthRecipes.ConsumeExperienceIngredients(self.inst, recname)
        return old_RemoveIngredients(self, ingredients, recname, discounted, ...)
    end

    function self:DoBuild(recname, pt, rotation, skin)
        if self.inst:HasTag("kei_dormant") then
            return false, "KEI_DORMANT"
        end

        if recname == FISH_CALL_RECIPE then
            return require("kei/protocols/life/effects/fish_call").DoBuild(self, recname, pt, rotation, skin)
        end

        if recname == FULLMOON_RECIPE then
            return require("kei/protocols/life/effects/fullmoon_recipe").DoBuild(self, recname, pt, rotation, skin)
        end

        if recname == NEWMOON_RECIPE then
            return require("kei/protocols/life/effects/newmoon_recipe").DoBuild(self, recname, pt, rotation, skin)
        end

        if recname == RIPEN_RECIPE then
            return require("kei/protocols/life/effects/ripen").DoBuild(self, recname, pt, rotation, skin)
        end

        if recname == WEATHER_RECIPE then
            return require("kei/protocols/life/effects/weather").DoBuild(self, recname, pt, rotation, skin)
        end
        if GrowthRecipes.IsGrowthRecipe(recname) then
            return GrowthRecipes.DoBuild(self, recname, pt, rotation, skin)
        end

        return old_DoBuild(self, recname, pt, rotation, skin)
    end

end)

AddClassPostConstruct("components/builder_replica", function(self)
    local old_HasCharacterIngredient = self.HasCharacterIngredient

    function self:HasCharacterIngredient(ingredient)
        if GrowthRecipes.IsExperienceIngredient(ingredient) then
            local amount = GrowthRecipes.GetExperienceIngredientAmount(ingredient, self.inst)
            ingredient.amount = amount
            return GrowthRecipes.HasEnoughExperienceIngredient(self.inst, ingredient), amount
        end
        return old_HasCharacterIngredient(self, ingredient)
    end

end)

-- 字符串、动作和配方分文件维护，避免入口文件继续膨胀。
local function IsProtectedVirtualEquipment(item)
    return item ~= nil
        and item:HasTag("kei_virtual_equipment")
        and not item.kei_allow_virtual_drop
        and item.components.equippable ~= nil
        and item.components.equippable:IsEquipped()
end

local function IsKeiVirtualHandEquipment(item)
    return item ~= nil and item:HasTag("kei_virtual_hand_equipment")
end

local function IsEquippedKeiHandItem(inventory, item)
    return inventory.inst ~= nil
        and inventory.inst:HasTag("kei")
        and item ~= nil
        and inventory.equipslots ~= nil
        and inventory.equipslots[EQUIPSLOTS.HANDS] == item
        and not item:HasTag("kei_virtual_equipment")
end

local function IsActivePlayerDrop(inventory, item)
    local buffered = inventory.inst ~= nil and inventory.inst.bufferedaction or nil
    return buffered ~= nil
        and buffered.action == ACTIONS.DROP
        and buffered.invobject == item
end

local function IsProjectileOrThrowableHandItem(item)
    if item == nil then
        return false
    end

    if item:HasTag("projectile")
        or item:HasTag("rangedweapon")
        or item:HasTag("blowdart")
        or item:HasTag("throwable")
    then
        return true
    end

    local components = item.components
    return components ~= nil
        and (components.complexprojectile ~= nil
            or components.throwable ~= nil
            or (components.weapon ~= nil and components.weapon.projectile ~= nil))
end

local function IsActiveHandItemUse(inventory, item)
    local buffered = inventory.inst ~= nil and inventory.inst.bufferedaction or nil
    if buffered == nil or buffered.action == nil or buffered.action == ACTIONS.DROP then
        return false
    end

    if buffered.invobject == item then
        return true
    end

    return buffered.action == ACTIONS.ATTACK
        and inventory.equipslots ~= nil
        and inventory.equipslots[EQUIPSLOTS.HANDS] == item
        and IsProjectileOrThrowableHandItem(item)
end

local function IsSpentEquipment(item)
    if item == nil or item.components == nil then
        return false
    end

    local finiteuses = item.components.finiteuses
    if finiteuses ~= nil and finiteuses.GetUses ~= nil and finiteuses:GetUses() <= 0 then
        return true
    end

    local fueled = item.components.fueled
    if fueled ~= nil and fueled.IsEmpty ~= nil and fueled:IsEmpty() then
        return true
    end

    local armor = item.components.armor
    if armor ~= nil and armor.GetPercent ~= nil and armor:GetPercent() <= 0 then
        return true
    end

    return false
end

local function GetArmorAbsorption(item, attacker, weapon)
    local armor = item ~= nil and item.components ~= nil and item.components.armor or nil
    if armor == nil then
        return 0
    end

    local value = nil
    if armor.GetAbsorption ~= nil then
        local ok, result = pcall(armor.GetAbsorption, armor, attacker, weapon)
        if ok then
            value = result
        end
    end
    return math.min(1, math.max(0, tonumber(value ~= nil and value or armor.absorb_percent) or 0))
end

-- 解析护甲不再进入 inventory.equipslots。为了保持原版“护甲取最大吸收率”
-- 的语义，把私有协议护甲和真实装备的吸收率合并成一个输入缩放，再交给
-- 原版 ApplyDamage 处理真实装备、特殊伤害和耐久逻辑。
local function ScaleDamageForVirtualArmor(inventory, damage, attacker, weapon)
    if type(damage) ~= "number"
        or inventory == nil
        or inventory.inst == nil
        or not inventory.inst:HasTag("kei")
    then
        return damage
    end

    local slots = inventory.inst.components ~= nil
        and inventory.inst.components.kei_protocolslots
        or nil
    if slots == nil or slots.GetVirtualArmorAbsorption == nil then
        return damage
    end

    local virtual_absorb = math.min(1, math.max(0,
        tonumber(slots:GetVirtualArmorAbsorption(attacker, weapon)) or 0
    ))
    if virtual_absorb <= 0 then
        return damage
    end

    local real_absorb = 0
    for _, item in pairs(inventory.equipslots or {}) do
        real_absorb = math.max(real_absorb, GetArmorAbsorption(item, attacker, weapon))
    end
    if real_absorb >= virtual_absorb then
        return damage
    end

    local denominator = 1 - real_absorb
    if denominator <= 0 then
        return damage
    end

    local multiplier = (1 - virtual_absorb) / denominator
    return damage * math.min(1, math.max(0, multiplier))
end

local function ApplyVirtualDamageTypeResist(inventory, damage, attacker, weapon, spdamage)
    local slots = inventory ~= nil
        and inventory.inst ~= nil
        and inventory.inst.components ~= nil
        and inventory.inst.components.kei_protocolslots
        or nil
    if slots == nil or slots.GetVirtualDamageTypeMultiplier == nil then
        return damage, spdamage
    end

    local multiplier = slots:GetVirtualDamageTypeMultiplier(attacker, weapon)
    if type(multiplier) ~= "number" then
        multiplier = 1
    end

    damage = damage * multiplier
    if spdamage ~= nil then
        for sptype, value in pairs(spdamage) do
            if type(value) == "number" then
                spdamage[sptype] = value * multiplier
            end
        end
    end
    return damage, spdamage
end

local function ApplyVirtualSpDefense(inventory, spdamage)
    if spdamage == nil then
        return
    end

    local slots = inventory ~= nil
        and inventory.inst ~= nil
        and inventory.inst.components ~= nil
        and inventory.inst.components.kei_protocolslots
        or nil
    if slots == nil or slots.GetVirtualSpDefenseForType == nil then
        return
    end

    for sptype, damage in pairs(spdamage) do
        if type(damage) == "number" and damage > 0 then
            local defense = slots:GetVirtualSpDefenseForType(sptype)
            if type(defense) == "number" and defense > 0 then
                spdamage[sptype] = math.max(0, damage - defense)
                if spdamage[sptype] <= 0 then
                    spdamage[sptype] = nil
                end
            end
        end
    end
end

local function IsCraftingContainer(container)
    return container ~= nil
        and container.excludefromcrafting ~= true
        and container.readonlycontainer ~= true
end

local function AddCraftingItems(target, container, item, amount, total, use_open_containers)
    if container == nil or total >= amount then
        return total
    end

    local found = container:GetCraftingIngredient(
        item,
        amount - total,
        use_open_containers
    )
    for found_item, count in pairs(found) do
        local accepted = math.min(count, amount - total)
        target[found_item] = accepted
        total = total + accepted
        if total >= amount then
            break
        end
    end

    return total
end

local function AddInventoryCraftingItems(target, inventory, item, amount, total)
    local candidates = {}
    for slot = 1, inventory.maxslots do
        local candidate = inventory:GetItemInSlot(slot)
        if candidate ~= nil
            and candidate.prefab == item
            and not candidate:HasTag("nocrafting")
        then
            table.insert(candidates, {
                item = candidate,
                stacksize = candidate.components.stackable
                    and candidate.components.stackable:StackSize()
                    or 1,
                slot = slot,
            })
        end
    end

    table.sort(candidates, function(a, b)
        if a.stacksize == b.stacksize then
            return a.slot < b.slot
        end
        return a.stacksize < b.stacksize
    end)

    for _, candidate in ipairs(candidates) do
        local count = math.min(candidate.stacksize, amount - total)
        target[candidate.item] = count
        total = total + count
        if total >= amount then
            break
        end
    end

    return total
end

local function GetOtherOpenCraftingContainers(inventory, overflow, alice)
    local containers = {}
    for container_inst in pairs(inventory.opencontainers) do
        local container = container_inst.components.container or container_inst.components.inventory
        if container ~= nil
            and container ~= overflow
            and container ~= alice
            and not MiniAlice.IsContainer(container)
            and IsCraftingContainer(container)
        then
            table.insert(containers, container)
        end
    end
    return containers
end

AddComponentPostInit("inventory", function(self)
    local old_DropItem = self.DropItem
    local old_RemoveItem = self.RemoveItem
    local old_Unequip = self.Unequip
    local old_Equip = self.Equip
    local old_ApplyDamage = self.ApplyDamage
    local old_HasAnyEquipment = self.HasAnyEquipment
    local old_ForEachEquipment = self.ForEachEquipment
    local old_ArmorHasTag = self.ArmorHasTag
    local old_IsWearingArmor = self.IsWearingArmor
    local old_EquipHasSpDefenseForType = self.EquipHasSpDefenseForType
    local old_IsInsulated = self.IsInsulated
    local old_GetEquippedMoistureRate = self.GetEquippedMoistureRate
    local old_GetWaterproofness = self.GetWaterproofness
    local old_EquipHasTag = self.EquipHasTag

    local function ForEachVirtualEquipment(fn, ...)
        local slots = self.inst.components ~= nil
            and self.inst.components.kei_protocolslots
            or nil
        if slots ~= nil and slots.ForEachVirtualEquipment ~= nil then
            slots:ForEachVirtualEquipment(fn, ...)
        end
    end

    function self:HasAnyEquipment(...)
        if old_HasAnyEquipment ~= nil and old_HasAnyEquipment(self, ...) then
            return true
        end

        local found = false
        ForEachVirtualEquipment(function()
            found = true
        end)
        if found then
            return true
        end
        return false
    end

    -- 解析装备不写入 inventory.equipslots。把它们只追加到原版的遍历型
    -- 查询中，使 setbonus、战斗视觉和第三方装备扫描仍能看到实际的护甲。
    -- 这里不包含仍占用真实 HANDS 槽的虚拟手部装备，避免重复处理。
    function self:ForEachEquipment(fn, ...)
        local result = old_ForEachEquipment(self, fn, ...)
        ForEachVirtualEquipment(fn, ...)
        return result
    end

    function self:IsWearingArmor(...)
        if old_IsWearingArmor ~= nil and old_IsWearingArmor(self, ...) then
            return true
        end

        local found = false
        ForEachVirtualEquipment(function(item)
            if not found
                and item.components ~= nil
                and item.components.armor ~= nil
            then
                found = true
            end
        end)
        if found then
            return true
        end
    end

    function self:ArmorHasTag(tag, ...)
        if old_ArmorHasTag ~= nil and old_ArmorHasTag(self, tag, ...) then
            return true
        end

        local found = false
        ForEachVirtualEquipment(function(item)
            if not found
                and item.components ~= nil
                and item.components.armor ~= nil
                and item:HasTag(tag)
            then
                found = true
            end
        end)
        if found then
            return true
        end
    end

    function self:EquipHasSpDefenseForType(sptype, ...)
        if old_EquipHasSpDefenseForType ~= nil
            and old_EquipHasSpDefenseForType(self, sptype, ...)
        then
            return true
        end

        local found = false
        ForEachVirtualEquipment(function(item)
            if not found and SpDamageUtil.GetSpDefenseForType(item, sptype) > 0 then
                found = true
            end
        end)
        if found then
            return true
        end
    end

    function self:IsInsulated(...)
        -- ForceNoInsulated is an explicit override and must also suppress
        -- virtual equipment, just as it suppresses real equipment.
        if self.force_no_insulation then
            return false
        end
        if old_IsInsulated ~= nil and old_IsInsulated(self, ...) then
            return true
        end

        local found = false
        ForEachVirtualEquipment(function(item)
            local equippable = item.components ~= nil and item.components.equippable or nil
            if not found and equippable ~= nil and equippable.IsInsulated ~= nil
                and equippable:IsInsulated()
            then
                found = true
            end
        end)
        if found then
            return true
        end
        return false
    end

    function self:GetEquippedMoistureRate(slot, ...)
        local moisture, max = old_GetEquippedMoistureRate(self, slot, ...)
        -- A concrete slot refers to inventory.itemslots in the vanilla API;
        -- private protocol slots have no corresponding public item slot.
        if slot ~= nil then
            return moisture, max
        end

        ForEachVirtualEquipment(function(item)
            local equippable = item.components ~= nil and item.components.equippable or nil
            if equippable ~= nil and equippable.GetEquippedMoisture ~= nil then
                local data = equippable:GetEquippedMoisture()
                if data ~= nil then
                    moisture = moisture + (tonumber(data.moisture) or 0)
                    max = max + (tonumber(data.max) or 0)
                end
            end
        end)
        return moisture, max
    end

    function self:GetWaterproofness(slot, ...)
        local waterproofness = old_GetWaterproofness(self, slot, ...)
        if slot ~= nil then
            return waterproofness
        end

        if self.inst.components ~= nil
            and self.inst.components.moisture ~= nil
            and self.inst.components.moisture.GetWaterproofInventory ~= nil
            and self.inst.components.moisture:GetWaterproofInventory()
        then
            return 1
        end

        ForEachVirtualEquipment(function(item)
            local waterproofer = item.components ~= nil and item.components.waterproofer or nil
            if waterproofer ~= nil and waterproofer.GetEffectiveness ~= nil then
                waterproofness = waterproofness + (tonumber(waterproofer:GetEffectiveness()) or 0)
            end
        end)
        return waterproofness
    end

    -- 第三方装备的功能标签（例如 functional medal 的 nooverheat）仍然
    -- 通过 Inventory:EquipHasTag() 查询。解析护甲不在 equipslots，因此将
    -- Kei 私有虚拟装备作为额外查询源，同时保留其它模组已经安装的包装。
    function self:EquipHasTag(tag, ...)
        if old_EquipHasTag ~= nil and old_EquipHasTag(self, tag, ...) then
            return true
        end

        local slots = self.inst.components ~= nil
            and self.inst.components.kei_protocolslots
            or nil
        if slots ~= nil and slots.ForEachVirtualEquipment ~= nil then
            local found = false
            slots:ForEachVirtualEquipment(function(item)
                if not found and item:HasTag(tag) then
                    found = true
                end
            end)
            if found then
                return true
            end
        end
    end

    function self:GetCraftingIngredient(item, amount)
        local overflow = self:GetOverflowContainer()
        local alice = MiniAlice.GetOpenContainer(self.inst)
        local crafting_items = {}
        local total = 0

        -- Preserve the vanilla order for other opened containers.
        for _, container in ipairs(GetOtherOpenCraftingContainers(self, overflow, alice)) do
            total = AddCraftingItems(crafting_items, container, item, amount, total, true)
            if total >= amount then
                return crafting_items
            end
        end

        total = AddInventoryCraftingItems(crafting_items, self, item, amount, total)
        if total >= amount then
            return crafting_items
        end

        -- Mini Alice is deliberately between the player's inventory and the body backpack.
        total = AddCraftingItems(crafting_items, alice, item, amount, total, false)
        if total >= amount then
            return crafting_items
        end

        total = AddCraftingItems(crafting_items, overflow, item, amount, total, false)
        if total >= amount then
            return crafting_items
        end

        local activeitem = self.activeitem
        if activeitem ~= nil
            and activeitem.prefab == item
            and not activeitem:HasTag("nocrafting")
        then
            crafting_items[activeitem] = math.min(
                activeitem.components.stackable
                    and activeitem.components.stackable:StackSize()
                    or 1,
                amount - total
            )
        end

        return crafting_items
    end

    function self:Unequip(equipslot, slip, force)
        local item = self.equipslots ~= nil and self.equipslots[equipslot] or nil
        if IsKeiVirtualHandEquipment(item) then
            return nil
        end

        return old_Unequip(self, equipslot, slip, force)
    end

    function self:Equip(item, old_to_active, no_animation, force_ui_anim)
        if self.inst:HasTag("kei")
            and item ~= nil
            and item.components ~= nil
            and item.components.equippable ~= nil
            and item.components.equippable.equipslot == EQUIPSLOTS.HANDS
        then
            local current = self:GetEquippedItem(EQUIPSLOTS.HANDS)
            local protocolslots = self.inst.components ~= nil and self.inst.components.kei_protocolslots or nil
            if IsKeiVirtualHandEquipment(current) and protocolslots ~= nil then
                protocolslots._kei_suppress_hand_virtual = true
                protocolslots:RemoveHandVirtualEquip()
                local ok, result1, result2, result3 = pcall(old_Equip, self, item, old_to_active, no_animation, force_ui_anim)
                protocolslots._kei_suppress_hand_virtual = nil
                protocolslots:Refresh()
                if not ok then
                    error(result1)
                end
                return result1, result2, result3
            end
        end

        return old_Equip(self, item, old_to_active, no_animation, force_ui_anim)
    end

    function self:ApplyDamage(damage, attacker, weapon, spdamage, ...)
        local slots = self.inst.components ~= nil
            and self.inst.components.kei_protocolslots
            or nil
        if slots ~= nil
            and slots.TryResistDamage ~= nil
            and slots:TryResistDamage(damage, attacker, weapon)
        then
            return 0, nil
        end

        damage, spdamage = ApplyVirtualDamageTypeResist(
            self, damage, attacker, weapon, spdamage
        )
        ApplyVirtualSpDefense(self, spdamage)
        damage = ScaleDamageForVirtualArmor(self, damage, attacker, weapon)
        return old_ApplyDamage(self, damage, attacker, weapon, spdamage, ...)
    end

    function self:DropItem(item, wholestack, randomdir, pos, keepoverstacked)
        if self.inst:HasTag("kei_dormant") then
            return nil
        end

        if IsProtectedVirtualEquipment(item) then
            return nil
        end

        if IsEquippedKeiHandItem(self, item)
            and not IsActivePlayerDrop(self, item)
            and not IsActiveHandItemUse(self, item)
            and not IsSpentEquipment(item)
        then
            return nil
        end

        return old_DropItem(self, item, wholestack, randomdir, pos, keepoverstacked)
    end

    function self:RemoveItem(item, wholestack, checkallcontainers, keepoverstacked)
        if IsProtectedVirtualEquipment(item) then
            return nil
        end

        return old_RemoveItem(self, item, wholestack, checkallcontainers, keepoverstacked)
    end
end)
