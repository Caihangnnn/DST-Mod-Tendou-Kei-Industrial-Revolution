local CombatProtocolDefs = require("kei/protocols/combat")
local LifeProtocolDefs = require("kei/protocols/life")
local BasicAttributeProtocolDefs = require("kei/protocols/basic_attributes")
local ProtocolSlotUnlocks = require("kei/protocol_slot_unlocks")
local AnalysisArmorUpgrade = require("kei/analysis_armor_upgrade")
local LifeRecipeUnlocks = require("kei/protocols/life/recipe_unlocks")
local VirtualHandEquipment = require("kei/protocols/analysis/virtual_hand_equipment")
local HandAnalysisInheritance = require("kei/protocols/analysis/hand_analysis_inheritance")
local ArmorAnalysisEquipment = require("kei/protocols/analysis/armor_analysis_equipment")
local MiniAlice = require("kei/mini_alice")
local BeastCommon = require("kei/protocols/combat/effects/beast/_beast_common")
local SpDamageUtil = require("components/spdamageutil")

local LIFE_PROTOCOLS = LifeProtocolDefs.LIFE_PROTOCOLS
local BASIC_ATTRIBUTE_PROTOCOLS = BasicAttributeProtocolDefs.BASIC_ATTRIBUTE_PROTOCOLS

local function GetCombatEffectPath(def)
    if def.category == "beast" or def.category == "biome" then
        return "kei/protocols/combat/effects/" .. def.category .. "/" .. (def.effect_file or def.protocol)
    end
    return "kei/protocols/combat/effects/" .. (def.effect_file or def.protocol)
end

local function BuildCombatEffectHandlers()
    local handlers = {}
    for _, def in ipairs(CombatProtocolDefs.COMBAT_PROTOCOL_LIST) do
        handlers[def.protocol] = require(GetCombatEffectPath(def))
    end
    return handlers
end

local function BuildLifeEffects()
    local effects = {}
    for _, def in ipairs(LifeProtocolDefs.LIFE_PROTOCOL_LIST) do
        effects[def.protocol] = require("kei/protocols/life/effects/" .. def.protocol)
    end
    return effects
end

--- 战斗协议效果处理器注册表。
local EFFECT_HANDLERS = BuildCombatEffectHandlers()

--- 生活协议效果处理器（导出 Apply 方法，非 EffectHandler 接口）。
local LIFE_EFFECTS = BuildLifeEffects()
local ANALYSIS_ARMOR_MODIFIER = "kei_analysis_armor"
local BASIC_DAMAGE_MODIFIER = "kei_basic_attribute_damage"
local COMBAT_PROTOCOL_DAMAGE_MODIFIER = "kei_combat_protocol_damage"
local BASIC_SPEED_MODIFIER = "kei_basic_attribute_speed"
local BASIC_ABSORB_MODIFIER = "kei_basic_attribute_absorb"
local DRAGONFLY_FIRE_IMMUNITY_MODIFIER = "kei_dragonfly_fire_immunity"
local MINI_ALICE_ACTION_TAKEOUT = "takeout"
local MINI_ALICE_ACTION_STORE = "store"
local MINI_ALICE_ACTION_SORT = "sort"

local function FormatStatusNumber(value)
    value = tonumber(value) or 0
    if math.abs(value - math.floor(value + .5)) < .001 then
        return tostring(math.floor(value + .5))
    end
    return string.format("%.1f", value)
end

local function GetWeaponBaseDamage(inst, combat)
    local weapon = combat ~= nil and combat.GetWeapon ~= nil and combat:GetWeapon() or nil
    local weapon_component = weapon ~= nil and weapon.components ~= nil and weapon.components.weapon or nil
    if weapon_component ~= nil then
        if weapon_component.GetDamage ~= nil then
            local ok, damage = pcall(weapon_component.GetDamage, weapon_component, inst, nil)
            if ok and type(damage) == "number" then
                return damage
            end
        end
        if type(weapon_component.damage) == "number" then
            return weapon_component.damage
        end
    end
    return combat ~= nil and combat.defaultdamage or 0
end

local function GetArmorAbsorption(inst)
    local inventory = inst ~= nil and inst.components ~= nil and inst.components.inventory or nil
    local protocolslots = inst ~= nil and inst.components ~= nil and inst.components.kei_protocolslots or nil
    local absorption = 0
    if inventory ~= nil then
        for _, item in pairs(inventory.equipslots or {}) do
            local armor = item ~= nil and item.components ~= nil and item.components.armor or nil
            if armor ~= nil then
                local value = nil
                if armor.GetAbsorption ~= nil then
                    local ok, result = pcall(armor.GetAbsorption, armor, nil, nil)
                    if ok then value = result end
                end
                value = value ~= nil and value or armor.absorb_percent
                absorption = math.max(absorption, tonumber(value) or 0)
            end
        end
    end

    -- 解析护甲由 Kei 私有协议槽管理，不进入 inventory.equipslots。
    if protocolslots ~= nil and protocolslots.GetVirtualArmorAbsorption ~= nil then
        absorption = math.max(absorption, protocolslots:GetVirtualArmorAbsorption())
    end
    return math.min(math.max(absorption, 0), 1)
end

----------------------------------------------------------------
-- 辅助函数
----------------------------------------------------------------

local function IsProtocol(item)
    return item ~= nil and item:HasTag("kei_protocol_cd") and item.kei_protocol_data ~= nil
end

local function IsProtocolContainer(item)
    return item ~= nil and item.prefab == "kei_protocol_container"
end

local function ProtocolNeedsPower(data)
    return data.kind == "analysis"
end

local function ProtocolNeedsStability(data)
    return data.kind == "combat"
end

-- 深度植入后再次插入同类协议时，基础属性按数值叠加；战斗协议只有
-- 明确声明 stackable=true 时才允许保留槽内来源，默认不可叠加。
local function IsProtocolStackable(data)
    if data == nil then
        return false
    end
    if data.stackable ~= nil then
        return data.stackable == true
    end
    if data.kind == "basic_attribute" then
        return true
    end
    if data.kind == "combat" then
        local definition = CombatProtocolDefs.COMBAT_PROTOCOLS[data.protocol]
        return definition ~= nil and definition.stackable == true
    end
    if data.kind == "life" then
        local definition = LIFE_PROTOCOLS[data.protocol]
        return definition ~= nil and definition.stackable == true
    end
    return false
end

local function GetProtocolDrainSettings()
    return {
        analysis_amount = TUNING.KEI_PROTOCOL_DRAIN_AMOUNT or 1,
        combat_amount = TUNING.KEI_PROTOCOL_DRAIN_AMOUNT or 1,
        cap = TUNING.KEI_PROTOCOL_DRAIN_MAX_PER_PERIOD or 5,
    }
end

local function ReturnItemToOwner(owner, item)
    if owner ~= nil and owner.components.inventory ~= nil then
        if owner.components.inventory:GiveItem(item, nil, owner:GetPosition()) then
            return
        end
    end
    if owner ~= nil then
        item.Transform:SetPosition(owner.Transform:GetWorldPosition())
    end
end

local function GetItemIdentity(item)
    if item == nil then
        return nil
    end
    return tostring(item.prefab or "") .. "\31" .. tostring(item.skinname or "")
end

local function ContainerHasRoomForItem(container, item)
    if container == nil
        or item == nil
        or not container:CanTakeItemInSlot(item)
    then
        return false
    end

    for slot = 1, container:GetNumSlots() do
        local stored = container:GetItemInSlot(slot)
        if stored == nil then
            if container:CanTakeItemInSlot(item, slot) then
                return true
            end
        elseif container:AcceptsStacks()
            and stored.components ~= nil
            and stored.components.stackable ~= nil
            and not stored.components.stackable:IsFull()
            and stored.components.stackable:CanStackWith(item)
            and container:CanTakeItemInSlot(item, slot)
        then
            return true
        end
    end

    return false
end

local function GetOpenChestContainers(owner, alice)
    local inventory = owner ~= nil and owner.components ~= nil and owner.components.inventory or nil
    if inventory == nil then
        return {}
    end

    local result = {}
    for container_inst in pairs(inventory.opencontainers or {}) do
        local container = container_inst ~= nil
            and container_inst.components ~= nil
            and container_inst.components.container
            or nil
        if container ~= nil
            and container ~= alice
            and container.type == "chest"
            and container:IsOpenedBy(owner)
            and not container.readonlycontainer
        then
            result[#result + 1] = container
        end
    end

    table.sort(result, function(a, b)
        return (a.inst.GUID or 0) < (b.inst.GUID or 0)
    end)
    return result
end

local function CollectItemIdentities(container, accessible_only)
    local identities = {}
    if container == nil then
        return identities
    end

    for slot = 1, container:GetNumSlots() do
        if not accessible_only or MiniAlice.IsSlotAccessible(container, slot) then
            local item = container:GetItemInSlot(slot)
            local identity = GetItemIdentity(item)
            if identity ~= nil then
                identities[identity] = true
            end
        end
    end
    return identities
end

local function AddContainerItemIdentities(identities, container)
    for identity in pairs(CollectItemIdentities(container, false)) do
        identities[identity] = true
    end
end

local function MoveMatchingItems(source, target, identities, owner)
    if source == nil or target == nil or identities == nil then
        return
    end

    for slot = 1, source:GetNumSlots() do
        local item = source:GetItemInSlot(slot)
        if item ~= nil
            and identities[GetItemIdentity(item)]
            and ContainerHasRoomForItem(target, item)
        then
            source:MoveItemFromAllOfSlot(slot, target.inst, owner)
        end
    end
end

local function GetPerishablePercent(item)
    local perishable = item ~= nil
        and item.components ~= nil
        and item.components.perishable
        or nil
    if perishable ~= nil and perishable.GetPercent ~= nil then
        return tonumber(perishable:GetPercent()) or 0
    end
    return 0
end

local function SortMiniAliceItems(alice, owner)
    local slots = {}
    local items = {}
    for slot = 1, alice:GetNumSlots() do
        if MiniAlice.IsSlotAccessible(alice, slot) then
            slots[#slots + 1] = slot
            local item = alice:GetItemInSlot(slot)
            if item ~= nil then
                items[#items + 1] = {
                    item = item,
                    slot = slot,
                    identity = GetItemIdentity(item) or "",
                    has_freshness = item.components ~= nil and item.components.perishable ~= nil,
                    is_stackable = item.components ~= nil and item.components.stackable ~= nil,
                    freshness = GetPerishablePercent(item),
                }
            end
        end
    end

    if #items <= 1 then
        return
    end

    table.sort(items, function(a, b)
        if a.has_freshness ~= b.has_freshness then
            return a.has_freshness
        elseif a.is_stackable ~= b.is_stackable then
            return a.is_stackable
        elseif a.identity ~= b.identity then
            return a.identity < b.identity
        elseif a.has_freshness and a.freshness ~= b.freshness then
            return a.freshness > b.freshness
        end
        return a.slot < b.slot
    end)

    local removed = {}
    for _, entry in ipairs(items) do
        removed[entry.slot] = alice:RemoveItemBySlot(entry.slot)
    end

    local old_ignoresound = alice.ignoresound
    alice.ignoresound = true
    for index, entry in ipairs(items) do
        local item = removed[entry.slot]
        if item ~= nil and not alice:GiveItem(item, slots[index], nil, false) then
            -- Keep the item in the original slot if an external container hook
            -- rejects the sorted destination.
            alice:GiveItem(item, entry.slot, nil, false)
        end
    end
    alice.ignoresound = old_ignoresound
end

local function RemoveProtocolContainer(owner, inventory, container)
    if container.components.container ~= nil then
        local stored = container.components.container:GetItemInSlot(1)
        if stored ~= nil then
            stored = container.components.container:RemoveItem(stored, true)
            if stored ~= nil then
                ReturnItemToOwner(owner, stored)
            end
        end
    end
    if inventory ~= nil then
        inventory:RemoveItem(container, true)
    end
    if container:IsValid() then
        container:Remove()
    end
end

----------------------------------------------------------------
-- 构造函数
----------------------------------------------------------------

local KeiProtocolSlots = Class(function(self, inst)
    self.inst = inst
    self.unlocked_slots = ProtocolSlotUnlocks.GetInitialSlots()
    self.mini_alice_pages = 1
    self.analysis_armor_upgrade_level = 0
    self.implanted_combat_protocols = {}
    self.implanted_basic_attributes = {}
    self.permanent_life_recipes = {}
    self.active = {}
    self.active_combat = {}
    self.active_life = {}
    self.virtual_equips = {}
    self.virtual_hand_equip = nil
    self._kei_virtual_staff_attack_cooldown_until = nil
    self._kei_virtual_staff_attack_cd_task = nil
    self.analysis_base_damage_bonus = 0
    self.analysis_tool_actions = {}
    self._kei_worker_action_old_values = {}
    self._kei_tool_action_old_tags = {}
    self._kei_mutateddeerclops_slowed = {}
    self._protocol_state_dirty = true
    self._implanted_effects_dirty = true
    self._prev_active_combat = {}
    self._protocol_slot_snapshot = {}
    self._protocols_disabled = false
    self.basic_attribute_modifiers = {}
    self._combat_damage_multipliers = {}
    self._combat_damage_reductions = {}
    self._kei_combat_attack_depth = 0
    self._kei_damage_parts_context = 0
    self._kei_damage_parts_multiplier = 1
    self._kei_damage_parts_fixed_bonus = 0
    self._kei_last_damage_parts = nil

    local combat = inst.components ~= nil and inst.components.combat or nil
    if combat ~= nil then
        self._old_combat_getattacked = combat.GetAttacked
        combat.GetAttacked = function(component, attacker, damage, weapon, stimuli, spdamage, ...)
            local reduction = self.basic_attribute_modifiers.fixed_damage_reduction or 0
            local true_fixed_damage = 0
            local attacker_combat = attacker ~= nil
                and attacker.components ~= nil
                and attacker.components.combat
                or nil
            local damage_parts = attacker_combat ~= nil
                and attacker_combat._kei_last_damage_parts
                or nil
            if type(damage) == "number" then
                if attacker_combat ~= nil
                    and (attacker_combat._kei_damage_parts_context or 0) > 0
                    and damage_parts ~= nil
                    and damage_parts.target == component.inst
                then
                    local attack_multiplier = math.max(0, damage_parts.multiplier or 1)
                    local scalable_damage = (damage_parts.scalable or 0) * attack_multiplier
                    -- Negative fixed damage only offsets the fixed damage segment.
                    -- The resulting true damage segment cannot be below zero.
                    true_fixed_damage = math.max(0, (damage_parts.fixed or 0) * attack_multiplier)
                    damage = math.max(0, scalable_damage - reduction)
                    attacker_combat._kei_last_damage_parts = nil
                else
                    damage = math.max(0, damage - reduction)
                end
            end

            -- 固定伤害减免后、进入原版护甲结算前，执行需要提前结算的防御效果。
            if self._kei_pre_armor_damagefn ~= nil then
                local adjusted_damage = self._kei_pre_armor_damagefn(
                    attacker,
                    damage,
                    weapon,
                    stimuli,
                    spdamage
                )
                if type(adjusted_damage) == "number" then
                    damage = math.max(0, adjusted_damage)
                end
            end
            self._kei_combat_attack_depth = self._kei_combat_attack_depth + 1
            local ok, result = pcall(
                self._old_combat_getattacked,
                component,
                attacker,
                damage,
                weapon,
                stimuli,
                spdamage,
                ...
            )
            self._kei_combat_attack_depth = math.max(0, self._kei_combat_attack_depth - 1)
            if not ok then
                error(result)
            end

            if true_fixed_damage > 0
                and component.inst.components ~= nil
                and component.inst.components.health ~= nil
            then
                -- Bypass armor and percentage damage reduction, but keep the normal
                -- invincibility check and attribute the damage to the attacker.
                component.inst.components.health:DoDelta(
                    -true_fixed_damage,
                    nil,
                    "kei_fixed_damage",
                    nil,
                    attacker,
                    true
                )
            end
            return result
        end

        self._old_combat_calcdamage = combat.CalcDamage
        combat.CalcDamage = function(component, target, weapon, multiplier, ...)
            local base_bonus = self:GetBaseDamageBonus()
            local old_getdamage = nil
            local old_defaultdamage = nil
            local defaultdamage_was_overridden = false
            local damage_source = nil

            if weapon ~= nil
                and weapon.components ~= nil
                and weapon.components.weapon ~= nil
                and weapon.components.weapon.GetDamage ~= nil
                and base_bonus ~= 0
            then
                damage_source = weapon.components.weapon
                old_getdamage = damage_source.GetDamage
                damage_source.GetDamage = function(weapon_component, ...)
                    local basedamage, spdamage = old_getdamage(weapon_component, ...)
                    if type(basedamage) == "number" then
                        basedamage = basedamage + base_bonus
                    end
                    return basedamage, spdamage
                end
            elseif weapon == nil and base_bonus ~= 0 then
                damage_source = component
                if component.inst.components ~= nil
                    and component.inst.components.rider ~= nil
                    and component.inst.components.rider:IsRiding()
                then
                    local mount = component.inst.components.rider:GetMount()
                    if mount ~= nil and mount.components ~= nil and mount.components.combat ~= nil then
                        damage_source = mount.components.combat
                    end
                end
                old_defaultdamage = damage_source.defaultdamage
                damage_source.defaultdamage = (old_defaultdamage or 0) + base_bonus
                defaultdamage_was_overridden = true
            end

            local results = { pcall(
                self._old_combat_calcdamage,
                component,
                target,
                weapon,
                multiplier,
                ...
            ) }

            if old_getdamage ~= nil then
                damage_source.GetDamage = old_getdamage
            end
            if defaultdamage_was_overridden then
                damage_source.defaultdamage = old_defaultdamage
            end
            if not results[1] then
                error(results[2])
            end

            local damage = results[2]
            local fixed_bonus = component._kei_damage_parts_fixed_bonus or 0
            if self._kei_damage_parts_context > 0 and type(damage) == "number" then
                self._kei_last_damage_parts = {
                    target = target,
                    scalable = damage - fixed_bonus,
                    fixed = fixed_bonus,
                    multiplier = self._kei_damage_parts_multiplier or 1,
                }
            end
            return unpack(results, 2)
        end

        self._old_combat_doattack = combat.DoAttack
        combat.DoAttack = function(component, ...)
            local weapon = select(2, ...)
            local projectile = select(3, ...)
            if weapon == nil and component.GetWeapon ~= nil then
                weapon = component:GetWeapon()
            end

            -- A ranged staff calls DoAttack twice: once to launch its
            -- projectile and once again when that projectile hits.  The
            -- cooldown belongs to the launch, while the hit-side call must
            -- continue so the staff's onattack callback can apply its effect.
            if VirtualHandEquipment.IsVirtualStaff(weapon) and projectile == nil then
                local now = GetTime()
                if self._kei_virtual_staff_attack_cooldown_until ~= nil
                    and self._kei_virtual_staff_attack_cooldown_until > now
                then
                    component:ClearAttackTemps()
                    return
                end

                local cooldown = math.max(0, TUNING.KEI_VIRTUAL_STAFF_ATTACK_COOLDOWN or 3)
                self._kei_virtual_staff_attack_cooldown_until = now + cooldown
                if self.inst._kei_virtual_staff_on_cooldown ~= nil then
                    self.inst._kei_virtual_staff_on_cooldown:set(true)
                end
                if self._kei_virtual_staff_attack_cd_task ~= nil then
                    self._kei_virtual_staff_attack_cd_task:Cancel()
                end
                self._kei_virtual_staff_attack_cd_task = self.inst:DoTaskInTime(cooldown, function()
                    self._kei_virtual_staff_attack_cooldown_until = nil
                    self._kei_virtual_staff_attack_cd_task = nil
                    if self.inst._kei_virtual_staff_on_cooldown ~= nil then
                        self.inst._kei_virtual_staff_on_cooldown:set(false)
                    end
                end)
            end

            local bonus = self.basic_attribute_modifiers.fixed_damage_bonus or 0
            local old_bonus = component.damagebonus or 0
            local old_context = component._kei_damage_parts_context or 0
            local old_multiplier = component._kei_damage_parts_multiplier or 1
            local old_fixed_bonus = component._kei_damage_parts_fixed_bonus or 0
            component.damagebonus = old_bonus + bonus
            component._kei_damage_parts_context = old_context + 1
            component._kei_damage_parts_multiplier = select(5, ...) or 1
            component._kei_damage_parts_fixed_bonus = bonus
            local result = { pcall(self._old_combat_doattack, component, ...) }
            component._kei_damage_parts_context = old_context
            component._kei_damage_parts_multiplier = old_multiplier
            component._kei_damage_parts_fixed_bonus = old_fixed_bonus
            component.damagebonus = old_bonus
            if not result[1] then
                error(result[2])
            end
            return unpack(result, 2)
        end
    end

    local health = inst.components ~= nil and inst.components.health or nil
    if health ~= nil then
        -- Health:DoDelta 会先处理外部百分比减伤，再调用 deltamodifierfn。
        -- 因此基础属性减伤在这里执行时，已经位于护甲和战斗协议减伤之后。
        self._old_health_deltamodifierfn = health.deltamodifierfn
        self._kei_basic_attribute_deltamodifierfn = function(component, amount, overtime, cause, ignore_invincible, afflicter, ignore_absorb)
            if self._old_health_deltamodifierfn ~= nil then
                amount = self._old_health_deltamodifierfn(
                    component,
                    amount,
                    overtime,
                    cause,
                    ignore_invincible,
                    afflicter,
                    ignore_absorb
                )
            end

            local reduction = math.min(
                TUNING.KEI_BASIC_ATTRIBUTE_MAX_DAMAGE_REDUCTION or 90,
                self.basic_attribute_modifiers.percent_damage_reduction or 0
            )
            if type(amount) == "number"
                and amount < 0
                and not ignore_absorb
                and self._kei_combat_attack_depth > 0
            then
                local combat_reduction = self:GetCombatDamageReduction()
                if combat_reduction > 0 then
                    amount = amount * math.max(1 - combat_reduction, 0)
                end
            end

            if type(amount) == "number"
                and amount < 0
                and not ignore_absorb
                and reduction ~= 0
            then
                amount = amount * (1 - reduction / 100)
            end

            -- 这是最后一层固定扣血修正，正值抵扣，负值增加每次生命损失。
            local fixed_health_loss_reduction = self.basic_attribute_modifiers.fixed_health_loss_reduction or 0
            if type(amount) == "number" and amount < 0 then
                amount = math.min(0, amount + fixed_health_loss_reduction)
            end
            return amount
        end
        health.deltamodifierfn = self._kei_basic_attribute_deltamodifierfn
    end

    self:SyncUnlockedSlots()
    self:SyncMiniAlicePages()

    inst:DoTaskInTime(0, function()
        self:EnsureProtocolContainers()
        self:Refresh()
    end)

    -- Protocol changes are event-driven. Keep only a low-frequency watchdog
    -- for unusual inventory/container mutations that bypass normal events.
    self._refresh_task = inst:DoPeriodicTask(5, function()
        if self:HasProtocolSlotContentsChanged() then
            self:ScheduleRefresh()
        end
    end)

    self._drain_task = inst:DoPeriodicTask(TUNING.KEI_PROTOCOL_DRAIN_PERIOD, function()
        self:DrainProtocols()
    end)

    self._life_growth_task = inst:DoPeriodicTask(TUNING.KEI_LIFE_GROWTH_ACCELERATION_PERIOD or 1, function()
        local stacks = self:GetLifeProtocolCount("growth_acceleration")
        LIFE_EFFECTS.growth_acceleration.Apply(self, self.inst, stacks)
    end)

    self._life_durability_task = inst:DoPeriodicTask(TUNING.KEI_LIFE_DURABILITY_RESTORE_PERIOD or 60, function()
        local stacks = self:GetLifeProtocolCount("durability_restore")
        LIFE_EFFECTS.durability_restore.Apply(self, self.inst, stacks)
    end)

    inst:ListenForEvent("onhitother", function(_, data)
        self:OnHitOther(data)
    end)

    inst:ListenForEvent("attacked", function(_, data)
        self:OnAttacked(data)
    end)

    local function ScheduleCombatStatusSync()
        if self._combat_status_sync_task ~= nil then
            return
        end
        self._combat_status_sync_task = inst:DoTaskInTime(0, function()
            self._combat_status_sync_task = nil
            self:SyncCombatStatusValues()
        end)
    end

    inst:ListenForEvent("equip", function(_, data)
        if data ~= nil and data.eslot == EQUIPSLOTS.HANDS then
            self._protocol_state_dirty = true
            self:Refresh()
        end
        ScheduleCombatStatusSync()
    end)

    inst:ListenForEvent("unequip", function(_, data)
        if data ~= nil and data.eslot == EQUIPSLOTS.HANDS then
            self._protocol_state_dirty = true
            self:Refresh()
        end
        ScheduleCombatStatusSync()
    end)

    inst:ListenForEvent("healthdelta", function(_, data)
        if self:IsDisabledByHealth() then
            self:DisableAllProtocols()
            return
        end

        local old_percent = data ~= nil and tonumber(data.oldpercent) or nil
        local new_percent = data ~= nil and tonumber(data.newpercent) or nil
        if old_percent ~= nil and new_percent ~= nil
            and old_percent <= 0 and new_percent > 0
        then
            self:ScheduleRefresh()
        end
    end)

    -- Combat protocols are filtered out while stability is zero. Rescan the
    -- slot contents when crossing the zero boundary so they can return after
    -- stability recovery instead of remaining absent from self.active.
    inst:ListenForEvent("sanitydelta", function(_, data)
        local old_percent = data ~= nil and tonumber(data.oldpercent) or nil
        local new_percent = data ~= nil and tonumber(data.newpercent) or nil
        if old_percent == nil or new_percent == nil then
            return
        end

        local reached_zero = old_percent > 0 and new_percent <= 0
        local recovered = old_percent <= 0 and new_percent > 0
        if reached_zero or recovered then
            self:ScheduleRefresh()
        end
    end)

    inst:ListenForEvent("hungerdelta", function(_, data)
        local old_percent = data ~= nil and tonumber(data.oldpercent) or nil
        local new_percent = data ~= nil and tonumber(data.newpercent) or nil
        if old_percent == nil or new_percent == nil then
            return
        end

        local reached_zero = old_percent > 0 and new_percent <= 0
        local recovered = old_percent <= 0 and new_percent > 0
        if reached_zero or recovered then
            self:ScheduleRefresh()
        end
    end)

    inst:ListenForEvent("death", function()
        self:DisableAllProtocols()
    end)


    local function OnProtocolInventoryEvent(_, data)
        local item = data ~= nil and (data.item or data.object) or nil
        if item == nil or IsProtocol(item) or IsProtocolContainer(item) then
            self:ScheduleRefresh()
        end
    end
    inst:ListenForEvent("itemget", OnProtocolInventoryEvent)
    inst:ListenForEvent("itemlose", OnProtocolInventoryEvent)
    inst:ListenForEvent("respawnfromghost", function()
        self:ScheduleRefresh()
    end)

    -- The server-side join event fires after reconnect/resume has restored the
    -- player. Queue one final scan so load order cannot leave stale effects.
    self._player_joined_refresh_fn = function(_, player)
        if player ~= inst then
            return
        end
        self:ScheduleRefresh()
    end
    inst:ListenForEvent("ms_playerjoined", self._player_joined_refresh_fn, TheWorld)
end)

function KeiProtocolSlots:PerformMiniAliceAction(action)
    if action ~= MINI_ALICE_ACTION_TAKEOUT
        and action ~= MINI_ALICE_ACTION_STORE
        and action ~= MINI_ALICE_ACTION_SORT
    then
        return false
    end

    local alice = MiniAlice.GetContainer(self.inst)
    if alice == nil or not alice:IsOpenedBy(self.inst) then
        return false
    end

    if action == MINI_ALICE_ACTION_SORT then
        SortMiniAliceItems(alice, self.inst)
        return true
    end

    local chests = GetOpenChestContainers(self.inst, alice)
    if #chests == 0 then
        return false
    end

    if action == MINI_ALICE_ACTION_STORE then
        local alice_items = CollectItemIdentities(alice, true)
        for _, chest in ipairs(chests) do
            MoveMatchingItems(chest, alice, alice_items, self.inst)
        end
    else
        local chest_items = {}
        for _, chest in ipairs(chests) do
            AddContainerItemIdentities(chest_items, chest)
        end
        for _, chest in ipairs(chests) do
            MoveMatchingItems(alice, chest, chest_items, self.inst)
        end
    end

    return true
end

----------------------------------------------------------------
-- 槽位管理
----------------------------------------------------------------

function KeiProtocolSlots:SyncUnlockedSlots()
    if self.inst._kei_unlocked_protocol_slots ~= nil then
        self.inst._kei_unlocked_protocol_slots:set(self.unlocked_slots)
    end
end

function KeiProtocolSlots:SyncProtocolSlotVisuals()
    local visual_vars = self.inst._kei_protocol_slot_visuals
    if visual_vars == nil then
        return
    end

    local inventory = self.inst.components.inventory
    for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
        local value = ""
        local protocol_container = inventory ~= nil and inventory:GetItemInSlot(slot) or nil
        local container = protocol_container ~= nil and protocol_container.components.container or nil
        local item = container ~= nil and container:GetItemInSlot(1) or nil
        local inventoryitem = item ~= nil and item.components.inventoryitem or nil
        if inventoryitem ~= nil then
            local image = inventoryitem.imagename or item.prefab
            local atlas = inventoryitem.atlasname or GetInventoryItemAtlas(image .. ".tex")
            if type(atlas) == "string" and atlas ~= "" and type(image) == "string" and image ~= "" then
                value = atlas .. "\t" .. image
            end
        end

        local visual_var = visual_vars[slot]
        if visual_var ~= nil and visual_var:value() ~= value then
            visual_var:set(value)
        end
    end
end

function KeiProtocolSlots:SyncAnalysisArmorUpgrade()
    self.analysis_armor_upgrade_level = AnalysisArmorUpgrade.ClampLevel(
        self.analysis_armor_upgrade_level
    )
    if self.inst._kei_analysis_armor_upgrade_level ~= nil then
        self.inst._kei_analysis_armor_upgrade_level:set(self.analysis_armor_upgrade_level)
    end
end

function KeiProtocolSlots:CanUpgradeAnalysisArmor()
    if self.analysis_armor_upgrade_level >= AnalysisArmorUpgrade.MAX_LEVEL then
        return false, "KEI_ANALYSIS_ARMOR_UPGRADE_MAX"
    end
    return true
end

function KeiProtocolSlots:UpgradeAnalysisArmor()
    local can_upgrade, reason = self:CanUpgradeAnalysisArmor()
    if not can_upgrade then
        return false, reason
    end

    self.analysis_armor_upgrade_level = self.analysis_armor_upgrade_level + 1
    self:SyncAnalysisArmorUpgrade()
    self._protocol_state_dirty = true
    self:Refresh()
    return true
end

function KeiProtocolSlots:SyncMiniAlicePages()
    local max_pages = math.clamp(tonumber(TUNING.KEI_MINI_ALICE_MAX_PAGES) or 7, 1, 7)
    self.mini_alice_pages = math.clamp(
        math.floor(tonumber(self.mini_alice_pages) or 1),
        1,
        max_pages
    )
    if self.inst._kei_mini_alice_pages ~= nil then
        self.inst._kei_mini_alice_pages:set(self.mini_alice_pages)
    end
end

function KeiProtocolSlots:ScheduleRefresh()
    self._protocol_state_dirty = true
    if self._scheduled_refresh_task ~= nil then
        return
    end

    self._scheduled_refresh_task = self.inst:DoTaskInTime(0, function()
        self._scheduled_refresh_task = nil
        self:EnsureProtocolContainers()
        self:Refresh()
    end)
end

function KeiProtocolSlots:UpdateProtocolSlotSnapshot()
    local inventory = self.inst.components ~= nil and self.inst.components.inventory or nil
    if inventory == nil then
        self._protocol_slot_snapshot = {}
        return
    end

    local snapshot = {}
    for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
        local container = inventory:GetItemInSlot(slot)
        local contents = IsProtocolContainer(container)
            and container.components ~= nil
            and container.components.container
            or nil
        snapshot[slot] = {
            container = container,
            item = contents ~= nil and contents:GetItemInSlot(1) or nil,
        }
    end
    self._protocol_slot_snapshot = snapshot
end

function KeiProtocolSlots:HasProtocolSlotContentsChanged()
    local inventory = self.inst.components ~= nil and self.inst.components.inventory or nil
    if inventory == nil then
        return false
    end

    local snapshot = self._protocol_slot_snapshot or {}
    for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
        local container = inventory:GetItemInSlot(slot)
        local contents = IsProtocolContainer(container)
            and container.components ~= nil
            and container.components.container
            or nil
        local item = contents ~= nil and contents:GetItemInSlot(1) or nil
        local previous = snapshot[slot]
        if previous == nil
            or previous.container ~= container
            or previous.item ~= item
        then
            return true
        end
    end
    return false
end

function KeiProtocolSlots:GetStatBonus()
    return ProtocolSlotUnlocks.GetStatBonus(self.unlocked_slots)
end

function KeiProtocolSlots:ApplyStatProgression()
    local max_stats = ProtocolSlotUnlocks.GetStatMaximums(self.unlocked_slots)
    local modifiers = self.basic_attribute_modifiers or {}
    max_stats.integrity = math.max(1, max_stats.integrity + (modifiers.integrity_max or 0))
    max_stats.power = math.max(1, max_stats.power + (modifiers.power_max or 0))
    max_stats.stability = math.max(1, max_stats.stability + (modifiers.stability_max or 0))
    local health = self.inst.components.health
    local hunger = self.inst.components.hunger
    local sanity = self.inst.components.sanity

    if health ~= nil and health.maxhealth ~= max_stats.integrity then
        local current = health.currenthealth
        health:SetMaxHealth(max_stats.integrity)
        -- 原版 SetMaxHealth 会将当前生命值设为新上限；属性协议只应修改上限。
        health.currenthealth = math.min(current or max_stats.integrity, health:GetMaxWithPenalty())
    end
    if hunger ~= nil and hunger.max ~= max_stats.power then
        local current = hunger.current
        hunger:SetMax(max_stats.power)
        -- 原版 SetMax 会回满饥饿度；属性协议只应修改电量上限。
        hunger.current = math.min(current or max_stats.power, hunger.max)
    end
    if sanity ~= nil and sanity.max ~= max_stats.stability then
        local current = sanity.current
        sanity:SetMax(max_stats.stability)
        -- 原版 SetMax 会回满精神值；属性协议只应修改稳定性上限。
        sanity.current = math.min(current or max_stats.stability, sanity.max)
    end
end

local function AddBasicAttributeValue(target, data)
    if data == nil
        or data.kind ~= "basic_attribute"
        or BASIC_ATTRIBUTE_PROTOCOLS[data.protocol] == nil
        or data.attribute == nil
        or type(data.attribute_value) ~= "number"
    then
        return
    end
    target[data.attribute] = (target[data.attribute] or 0) + data.attribute_value
end

-- 深度植入的基础属性数据在早期版本中没有保存 kind 字段。统一在读档时
-- 补齐该字段，确保旧存档也能被 Refresh 重新汇总并应用。
local function NormalizeImplantedBasicAttributes(attributes)
    if type(attributes) ~= "table" then
        return {}
    end

    for _, data in ipairs(attributes) do
        if type(data) == "table"
            and data.kind == nil
            and data.protocol ~= nil
            and BASIC_ATTRIBUTE_PROTOCOLS[data.protocol] ~= nil
        then
            data.kind = "basic_attribute"
        end
    end
    return attributes
end

function KeiProtocolSlots:GetPowerDrainMultiplier()
    local reduction = math.min(
        TUNING.KEI_BASIC_ATTRIBUTE_MAX_POWER_DRAIN_REDUCTION or 90,
        math.max(0, self.basic_attribute_modifiers.power_drain_reduction or 0)
    )
    return math.max(0.1, 1 - reduction / 100)
end

function KeiProtocolSlots:ApplyBasicAttributes(modifiers)
    modifiers = modifiers or {}
    self.basic_attribute_modifiers = modifiers

    self:ApplyStatProgression()

    local combat = self.inst.components ~= nil and self.inst.components.combat or nil
    if combat ~= nil then
        combat.externaldamagemultipliers:RemoveModifier(self.inst, BASIC_DAMAGE_MODIFIER)
        local damage_multiplier = math.max(0, 1 + (modifiers.percent_damage_bonus or 0) / 100)
        if damage_multiplier ~= 1 then
            combat.externaldamagemultipliers:SetModifier(self.inst, damage_multiplier, BASIC_DAMAGE_MODIFIER)
        end
    end

    local locomotor = self.inst.components ~= nil and self.inst.components.locomotor or nil
    if locomotor ~= nil then
        locomotor:RemoveExternalSpeedMultiplier(self.inst, BASIC_SPEED_MODIFIER)
        local speed_multiplier = math.max(0, 1 + (modifiers.percent_speed_bonus or 0) / 100)
        if speed_multiplier ~= 1 then
            locomotor:SetExternalSpeedMultiplier(self.inst, BASIC_SPEED_MODIFIER, speed_multiplier)
        end
    end

    local health = self.inst.components ~= nil and self.inst.components.health or nil
    if health ~= nil then
        health.externalabsorbmodifiers:RemoveModifier(self.inst, BASIC_ABSORB_MODIFIER)
    end
    self:SyncCombatStatusValues()
end

-- 获取进入原版 CalcDamage 基础伤害段的额外伤害。
function KeiProtocolSlots:GetBaseDamageBonus()
    return (self.basic_attribute_modifiers.base_damage_bonus or 0)
        + (self.analysis_base_damage_bonus or 0)
end

local function RefreshCombatDamageMultiplier(self)
    local combat = self.inst.components ~= nil and self.inst.components.combat or nil
    if combat == nil then
        return
    end

    local multiplier = 1
    for _, value in pairs(self._combat_damage_multipliers or {}) do
        multiplier = multiplier + (value - 1)
    end
    multiplier = math.max(0, multiplier)
    combat.externaldamagemultipliers:RemoveModifier(self.inst, COMBAT_PROTOCOL_DAMAGE_MODIFIER)
    if multiplier ~= 1 then
        combat.externaldamagemultipliers:SetModifier(self.inst, multiplier, COMBAT_PROTOCOL_DAMAGE_MODIFIER)
    end
end

-- 战斗协议的攻击倍率统一采用加算，最后以一个乘区接入原版普通伤害。
function KeiProtocolSlots:SetCombatDamageMultiplier(source, multiplier)
    if source == nil then
        return
    end
    if multiplier == nil then
        self._combat_damage_multipliers[source] = nil
    else
        self._combat_damage_multipliers[source] = tonumber(multiplier) or 1
    end
    RefreshCombatDamageMultiplier(self)
    self:SyncCombatStatusValues()
end

-- 设置一个战斗协议的攻击减伤来源。该列表只在 Combat:GetAttacked 的扣血路径中使用。
function KeiProtocolSlots:SetCombatDamageReduction(source, value)
    if source == nil then
        return
    end
    if value == nil then
        self._combat_damage_reductions[source] = nil
    else
        self._combat_damage_reductions[source] = math.max(0, tonumber(value) or 0)
    end
    self:SyncCombatStatusValues()
end

-- 战斗协议之间采用加算，最终限制在配置的最大减伤以内。
function KeiProtocolSlots:GetCombatDamageReduction()
    local reduction = 0
    for _, value in pairs(self._combat_damage_reductions or {}) do
        reduction = reduction + value
    end
    local maximum_percent = math.min(
        90,
        math.max(0, tonumber(TUNING.KEI_COMBAT_PROTOCOL_MAX_DAMAGE_REDUCTION) or 90)
    )
    return math.min(math.max(reduction, 0), maximum_percent / 100)
end

-- The task book is a client widget, while these components only exist on the
-- server. Send the settled generic combat values and their calculation steps.
function KeiProtocolSlots:SyncCombatStatusValues()
    local combat = self.inst.components ~= nil and self.inst.components.combat or nil
    local health = self.inst.components ~= nil and self.inst.components.health or nil
    local modifiers = self.basic_attribute_modifiers or {}

    local base_damage = GetWeaponBaseDamage(self.inst, combat)
    local base_bonus = self:GetBaseDamageBonus()
    local combat_multiplier = combat ~= nil and combat.damagemultiplier or 1
    local external_multiplier = combat ~= nil and combat.externaldamagemultipliers ~= nil
        and combat.externaldamagemultipliers:Get() or 1
    local fixed_bonus = modifiers.fixed_damage_bonus or 0
    local attack = (base_damage + base_bonus) * combat_multiplier * external_multiplier + fixed_bonus
    local attack_detail = string.format(
        "(%s + %s) x %s x %s + %s = %s",
        FormatStatusNumber(base_damage),
        FormatStatusNumber(base_bonus),
        FormatStatusNumber(combat_multiplier),
        FormatStatusNumber(external_multiplier),
        FormatStatusNumber(fixed_bonus),
        FormatStatusNumber(attack)
    )

    local armor_absorb = GetArmorAbsorption(self.inst)
    local external_absorb = health ~= nil and health.externalabsorbmodifiers ~= nil
        and health.externalabsorbmodifiers:Get() or 0
    local combat_reduction = self:GetCombatDamageReduction()
    local basic_reduction = math.min(
        TUNING.KEI_BASIC_ATTRIBUTE_MAX_DAMAGE_REDUCTION or 90,
        math.max(0, modifiers.percent_damage_reduction or 0)
    ) / 100
    local remaining_damage = math.max(0, 1 - armor_absorb)
        * math.max(0, 1 - external_absorb)
        * math.max(0, 1 - combat_reduction)
        * math.max(0, 1 - basic_reduction)
    local defense = (1 - remaining_damage) * 100
    local defense_detail = string.format(
        "1 - %s%% x %s%% x %s%% x %s%% = %s%%",
        FormatStatusNumber((1 - armor_absorb) * 100),
        FormatStatusNumber((1 - external_absorb) * 100),
        FormatStatusNumber((1 - combat_reduction) * 100),
        FormatStatusNumber((1 - basic_reduction) * 100),
        FormatStatusNumber(defense)
    )

    if self.inst._kei_status_attack ~= nil then
        self.inst._kei_status_attack:set(attack)
    end
    if self.inst._kei_status_defense ~= nil then
        self.inst._kei_status_defense:set(defense)
    end
    if self.inst._kei_status_attack_detail ~= nil then
        self.inst._kei_status_attack_detail:set(attack_detail)
    end
    if self.inst._kei_status_defense_detail ~= nil then
        self.inst._kei_status_defense_detail:set(defense_detail)
    end
end

function KeiProtocolSlots:ConfigureProtocolContainer(container, slot)
    container:AddTag("kei_protocol_slot")
    container.kei_protocol_slot_index = slot

    if container._kei_protocol_slot_contents_fn == nil then
        container._kei_protocol_slot_contents_fn = function()
            self._protocol_state_dirty = true
            self:SyncProtocolSlotVisuals()
            self:ScheduleRefresh()
        end
        container:ListenForEvent("itemget", container._kei_protocol_slot_contents_fn)
        container:ListenForEvent("itemlose", container._kei_protocol_slot_contents_fn)
    end

    if container.components.inventoryitem ~= nil then
        container.components.inventoryitem.islockedinslot = true
        container.components.inventoryitem.canbepickedup = false
        container.components.inventoryitem.keepondeath = true
    end

    if container.components.container ~= nil then
        local stored = container.components.container:GetItemInSlot(1)
        if stored ~= nil and not IsProtocol(stored) then
            stored = container.components.container:RemoveItem(stored, true)
            if stored ~= nil then
                ReturnItemToOwner(self.inst, stored)
            end
        end
        stored = container.components.container:GetItemInSlot(1)
        if stored ~= nil and stored.components.inventoryitem ~= nil then
            stored.components.inventoryitem.keepondeath = true
        end
        if container.SetPowered ~= nil then
            container:SetPowered(slot <= self.unlocked_slots and self:IsFunctional())
        else
            container.components.container.canbeopened = slot <= self.unlocked_slots and self:IsFunctional()
        end
    end
end

function KeiProtocolSlots:EnsureProtocolContainers()
    local inventory = self.inst.components.inventory
    if inventory == nil then return end

    local max_slots = ProtocolSlotUnlocks.GetMaxSlots()
    self.unlocked_slots = ProtocolSlotUnlocks.ClampUnlockedSlots(self.unlocked_slots)
    self:SyncUnlockedSlots()
    self:ApplyStatProgression()

    for slot = 1, max_slots do
        local current = inventory:GetItemInSlot(slot)

        if IsProtocolContainer(current) then
            self:ConfigureProtocolContainer(current, slot)
        else
            local displaced = current ~= nil and inventory:RemoveItem(current, true) or nil
            local container = SpawnPrefab("kei_protocol_container")
            if container ~= nil then
                self:ConfigureProtocolContainer(container, slot)
                inventory:GiveItem(container, slot)

                if displaced ~= nil then
                    if IsProtocol(displaced)
                        and slot <= self.unlocked_slots
                        and container.components.container ~= nil
                        and container.components.container:GetItemInSlot(1) == nil
                    then
                        container.components.container:GiveItem(displaced, 1)
                    else
                        ReturnItemToOwner(self.inst, displaced)
                    end
                end
            elseif displaced ~= nil then
                ReturnItemToOwner(self.inst, displaced)
            end
        end
    end

    for slot = max_slots + 1, ProtocolSlotUnlocks.GetHardMaxSlots() do
        local current = inventory:GetItemInSlot(slot)
        if IsProtocolContainer(current) then
            RemoveProtocolContainer(self.inst, inventory, current)
        end
    end

    self:SyncProtocolSlotVisuals()
    self:UpdateProtocolSlotSnapshot()
end

function KeiProtocolSlots:OnRemoveFromEntity()
    local tasks = {
        self._refresh_task,
        self._drain_task,
        self._life_growth_task,
        self._life_durability_task,
        self._scheduled_refresh_task,
        self._combat_status_sync_task,
        self._kei_virtual_staff_attack_cd_task,
    }
    for _, task in ipairs(tasks) do
        if task ~= nil then
            task:Cancel()
        end
    end
    self._refresh_task = nil
    self._drain_task = nil
    self._life_growth_task = nil
    self._life_durability_task = nil
    self._scheduled_refresh_task = nil
    self._combat_status_sync_task = nil
    self._kei_virtual_staff_attack_cd_task = nil
    self._kei_virtual_staff_attack_cooldown_until = nil

    local inventory = self.inst.components ~= nil and self.inst.components.inventory or nil
    if inventory ~= nil then
        for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
            local container = inventory:GetItemInSlot(slot)
            if IsProtocolContainer(container) and container._kei_protocol_slot_contents_fn ~= nil then
                container:RemoveEventCallback("itemget", container._kei_protocol_slot_contents_fn)
                container:RemoveEventCallback("itemlose", container._kei_protocol_slot_contents_fn)
                container._kei_protocol_slot_contents_fn = nil
            end
        end
    end

    if self._player_joined_refresh_fn ~= nil then
        self.inst:RemoveEventCallback("ms_playerjoined", self._player_joined_refresh_fn, TheWorld)
        self._player_joined_refresh_fn = nil
    end
    self:ClearModifiers()

    local combat = self.inst.components ~= nil and self.inst.components.combat or nil
    if combat ~= nil then
        if self._old_combat_getattacked ~= nil then
            combat.GetAttacked = self._old_combat_getattacked
        end
        if self._old_combat_calcdamage ~= nil then
            combat.CalcDamage = self._old_combat_calcdamage
        end
        if self._old_combat_doattack ~= nil then
            combat.DoAttack = self._old_combat_doattack
        end
    end
end

function KeiProtocolSlots:CanUnlockNextSlot()
    if self.unlocked_slots >= ProtocolSlotUnlocks.GetMaxSlots() then
        return false, "KEI_PROTOCOL_SLOTS_FULL"
    end
    return true
end

function KeiProtocolSlots:UnlockNextSlot()
    local can_unlock, reason = self:CanUnlockNextSlot()
    if not can_unlock then
        return false, reason
    end

    self.unlocked_slots = ProtocolSlotUnlocks.ClampUnlockedSlots(self.unlocked_slots + 1)
    self:SyncUnlockedSlots()
    self:ApplyStatProgression()
    if self.inst.components ~= nil and self.inst.components.kei_experience ~= nil then
        self.inst.components.kei_experience:RecalculateMax()
    end
    self:EnsureProtocolContainers()
    self:Refresh()
    self.inst:PushEvent("kei_protocol_slot_unlocked", { slot = self.unlocked_slots })
    return true
end

function KeiProtocolSlots:CanUnlockMiniAlicePage()
    local max_pages = math.clamp(tonumber(TUNING.KEI_MINI_ALICE_MAX_PAGES) or 7, 1, 7)
    if (self.mini_alice_pages or 1) >= max_pages then
        return false, "KEI_MINI_ALICE_PAGES_FULL"
    end
    return true
end

function KeiProtocolSlots:UnlockMiniAlicePage()
    local can_unlock, reason = self:CanUnlockMiniAlicePage()
    if not can_unlock then
        return false, reason
    end

    self.mini_alice_pages = (self.mini_alice_pages or 1) + 1
    self:SyncMiniAlicePages()
    self._protocol_state_dirty = true
    self.inst:PushEvent("kei_mini_alice_pages_unlocked", {
        pages = self.mini_alice_pages,
    })
    return true
end

function KeiProtocolSlots:GetFirstImplantableProtocol()
    local inventory = self.inst.components ~= nil and self.inst.components.inventory or nil
    if inventory == nil or self.unlocked_slots < ProtocolSlotUnlocks.GetMaxSlots() then
        return nil, nil
    end

    local container = inventory:GetItemInSlot(1)
    if not IsProtocolContainer(container) or container.components.container == nil then
        return nil, nil
    end

    local item = container.components.container:GetItemInSlot(1)
    local data = IsProtocol(item) and item.kei_protocol_data or nil
    if data == nil
        or (data.kind ~= "combat" and data.kind ~= "basic_attribute")
        or data.protocol == nil
    then
        return nil, nil
    end
    return item, data
end

function KeiProtocolSlots:CanDeepImplantFirst()
    local _, data = self:GetFirstImplantableProtocol()
    if data == nil then
        return false, "KEI_DEEP_IMPLANT_NO_PROTOCOL"
    end
    if data.kind == "combat" and self.implanted_combat_protocols[data.protocol] then
        return false, "KEI_DEEP_IMPLANT_ALREADY_IMPLANTED"
    end
    if data.kind == "basic_attribute" and type(data.attribute_value) ~= "number" then
        return false, "KEI_DEEP_IMPLANT_NO_PROTOCOL"
    end
    return true
end

function KeiProtocolSlots:DeepImplantFirst()
    local can_implant, reason = self:CanDeepImplantFirst()
    if not can_implant then
        return false, reason
    end

    local item, data = self:GetFirstImplantableProtocol()
    local inventory = self.inst.components.inventory
    local container = inventory:GetItemInSlot(1)
    local removed = container.components.container:RemoveItem(item, true)
    if removed == nil then
        return false, "KEI_DEEP_IMPLANT_NO_PROTOCOL"
    end

    if data.kind == "combat" then
        self.implanted_combat_protocols[data.protocol] = true
    else
        table.insert(self.implanted_basic_attributes, {
            kind = "basic_attribute",
            protocol = data.protocol,
            attribute = data.attribute,
            attribute_value = data.attribute_value,
        })
    end
    if self.inst.components.kei_taskbook ~= nil then
        self.inst.components.kei_taskbook:MarkImplanted(data, removed.prefab)
    end
    removed:Remove()
    self._protocol_state_dirty = true
    self._implanted_effects_dirty = true
    self:Refresh()
    return true
end

----------------------------------------------------------------
-- 状态查询
----------------------------------------------------------------

function KeiProtocolSlots:IsDisabledByHealth()
    local health = self.inst.components.health
    return self.inst:HasTag("playerghost")
        or (health ~= nil and (health:IsDead() or health.currenthealth <= 0))
end

function KeiProtocolSlots:IsFunctional()
    return not self:IsDisabledByHealth() and not self.inst:HasTag("kei_dormant")
end

function KeiProtocolSlots:HasProtocolInUnlockedSlots(protocol)
    if protocol == nil then return false end
    if self.implanted_combat_protocols[protocol] then
        return true
    end

    local inventory = self.inst.components.inventory
    if inventory == nil then return false end

    for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
        local container = inventory:GetItemInSlot(slot)
        if IsProtocolContainer(container) and container.components.container ~= nil and slot <= self.unlocked_slots then
            local item = container.components.container:GetItemInSlot(1)
            local data = IsProtocol(item) and item.kei_protocol_data or nil
            if data ~= nil and data.kind == "combat" and data.protocol == protocol then
                return true
            end
        end
    end
    return false
end

-- 深度植入是独立于协议槽 CD 的永久来源。
function KeiProtocolSlots:IsDeeplyImplanted(protocol)
    return protocol ~= nil and self.implanted_combat_protocols[protocol] == true
end

function KeiProtocolSlots:StalkerProtocolOverridesStability()
    return self:HasProtocolInUnlockedSlots("stalker_atrium") or self:HasProtocolInUnlockedSlots("stalker_atrium_basic")
end

function KeiProtocolSlots:AlterguardianProtocolOverridesPower()
    if not (self:HasProtocolInUnlockedSlots("alterguardian") or self:HasProtocolInUnlockedSlots("alterguardian_basic")) then
        return false
    end
    local sanity = self.inst.components.sanity
    return sanity == nil or sanity.current > 0 or self:StalkerProtocolOverridesStability()
end

function KeiProtocolSlots:SetProtocolContainersPowered(powered)
    local inventory = self.inst.components.inventory
    if inventory == nil then return end

    for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
        local container = inventory:GetItemInSlot(slot)
        if IsProtocolContainer(container) and container.components.container ~= nil then
            local enabled = powered and slot <= self.unlocked_slots
            if container.SetPowered ~= nil then
                container:SetPowered(enabled)
            else
                container.components.container.canbeopened = enabled
                if not enabled and container.components.container:IsOpen() then
                    container.components.container:Close()
                end
            end
        end
    end
end

function KeiProtocolSlots:CanRun(data)
    if not self:IsFunctional() then return false end
    if ProtocolNeedsPower(data)
        and self.inst.components.hunger ~= nil
        and self.inst.components.hunger.current <= 0
        and not self:AlterguardianProtocolOverridesPower()
    then
        return false
    end
    if ProtocolNeedsStability(data)
        and self.inst.components.sanity ~= nil
        and self.inst.components.sanity.current <= 0
        and data.protocol ~= "stalker_atrium" and data.protocol ~= "stalker_atrium_basic"
        and not self:StalkerProtocolOverridesStability()
    then
        return false
    end
    return true
end

function KeiProtocolSlots:GetProtocolSlotItems()
    local items = {}
    if not self:IsFunctional() then return items end
    local inventory = self.inst.components.inventory
    if inventory == nil then return items end

    -- 相同装备的解析协议只保留最先出现的一份。
    -- 协议槽按数字顺序遍历，因此第 1 格到第 N 格天然具有优先级。
    local analysis_sources = {}
    for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
        local container = inventory:GetItemInSlot(slot)
        if IsProtocolContainer(container) and container.components.container ~= nil then
            local item = container.components.container:GetItemInSlot(1)
            local data = IsProtocol(item) and item.kei_protocol_data or nil
            local duplicate_implant = data ~= nil
                and data.kind == "combat"
                and self:IsDeeplyImplanted(data.protocol)
                and not IsProtocolStackable(data)
            local duplicate_analysis = data ~= nil
                and data.kind == "analysis"
                and data.source ~= nil
                and analysis_sources[data.source] == true
            if data ~= nil
                and slot <= self.unlocked_slots
                and not duplicate_implant
                and not duplicate_analysis
                and self:CanRun(data)
            then
                if data.kind == "analysis" and data.source ~= nil then
                    analysis_sources[data.source] = true
                end
                table.insert(items, {
                    item = item,
                    slot = slot,
                    data = data,
                })
            end
        end
    end
    return items
end

function KeiProtocolSlots:SwapWithProtocolBinder(binder)
    if binder == nil
        or binder.components.container == nil
        or self.inst.components.inventory == nil
        or not self:IsFunctional()
    then
        return false
    end

    self:EnsureProtocolContainers()

    local swapped = false
    local inventory = self.inst.components.inventory
    local binder_container = binder.components.container
    local max_slots = math.min(ProtocolSlotUnlocks.GetMaxSlots(), binder_container.numslots or 0)

    for slot = 1, max_slots do
        if slot <= self.unlocked_slots then
            local protocol_container = inventory:GetItemInSlot(slot)
            if IsProtocolContainer(protocol_container) and protocol_container.components.container ~= nil then
                local slot_container = protocol_container.components.container
                local equipped_cd = slot_container:GetItemInSlot(1)
                local stored_cd = binder_container:GetItemInSlot(slot)

                if equipped_cd ~= nil or stored_cd ~= nil then
                    equipped_cd = equipped_cd ~= nil and slot_container:RemoveItemBySlot(1, true) or nil
                    stored_cd = stored_cd ~= nil and binder_container:RemoveItemBySlot(slot, true) or nil

                    local stored_ok = stored_cd == nil or slot_container:GiveItem(stored_cd, 1)
                    local equipped_ok = equipped_cd == nil or binder_container:GiveItem(equipped_cd, slot)

                    if not stored_ok and stored_cd ~= nil then
                        binder_container:GiveItem(stored_cd, slot)
                    end
                    if not equipped_ok and equipped_cd ~= nil then
                        slot_container:GiveItem(equipped_cd, 1)
                    end

                    swapped = swapped
                        or (stored_cd ~= nil and stored_ok)
                        or (equipped_cd ~= nil and equipped_ok)
                end
            end
        end
    end

    if swapped then
        -- 交换直接改动了协议容器内容，不一定触发 itemget/itemlose；强制重新读取并应用全部协议效果。
        self._protocol_state_dirty = true
        self:Refresh()
    end
    return swapped
end

----------------------------------------------------------------
-- 解析虚拟装备
----------------------------------------------------------------

function KeiProtocolSlots:RemoveVirtualEquip(slot)
    return ArmorAnalysisEquipment.Remove(self, slot)
end

function KeiProtocolSlots:ApplyVirtualEquip(entry)
    return ArmorAnalysisEquipment.Apply(self, entry)
end

function KeiProtocolSlots:ClearVirtualEquips(keep)
    return ArmorAnalysisEquipment.Clear(self, keep)
end

-- 解析护甲的唯一查询入口。虚拟护甲是协议组件的私有状态，不能再通过
-- Inventory:GetEquippedItem() 或遍历 inventory.equipslots 间接发现。
function KeiProtocolSlots:GetVirtualEquipment(slot)
    local item = self.virtual_equips ~= nil and self.virtual_equips[slot] or nil
    if item ~= nil and (not item:IsValid() or item.components == nil
        or item.components.equippable == nil
        or not item.components.equippable:IsEquipped())
    then
        return nil
    end
    return item
end

function KeiProtocolSlots:ForEachVirtualEquipment(fn, ...)
    if type(fn) ~= "function" then
        return
    end

    -- 查询回调可能触发协议刷新，刷新又可能替换 virtual_equips。先建立
    -- 快照，避免在回调中增删表项时跳过装备、重复调用或污染当前遍历。
    local snapshot = {}
    for slot, item in pairs(self.virtual_equips or {}) do
        if item ~= nil and item:IsValid()
            and item.components ~= nil
            and item.components.equippable ~= nil
            and item.components.equippable:IsEquipped()
        then
            snapshot[#snapshot + 1] = { slot = slot, item = item }
        end
    end

    for _, entry in ipairs(snapshot) do
        if entry.item:IsValid()
            and entry.item.components ~= nil
            and entry.item.components.equippable ~= nil
            and entry.item.components.equippable:IsEquipped()
        then
            fn(entry.item, entry.slot, ...)
        end
    end
end

function KeiProtocolSlots:GetVirtualArmorAbsorption(attacker, weapon)
    local absorption = 0
    self:ForEachVirtualEquipment(function(item)
        local armor = item.components ~= nil and item.components.armor or nil
        if armor ~= nil then
            local value = nil
            if armor.GetAbsorption ~= nil then
                local ok, result = pcall(armor.GetAbsorption, armor, attacker, weapon)
                if ok then
                    value = result
                end
            end
            value = value ~= nil and value or armor.absorb_percent
            absorption = math.max(absorption, tonumber(value) or 0)
        end
    end)
    return math.min(math.max(absorption, 0), 1)
end

-- 与原版 Inventory:ApplyDamage 相同，伤害类型抗性会对普通伤害和特殊
-- 伤害同时生效。解析装备不在 inventory.equipslots，因此由这里统一汇总
-- 虚拟装备上的 damagetyperesist 组件。
function KeiProtocolSlots:GetVirtualDamageTypeMultiplier(attacker, weapon)
    local multiplier = 1
    self:ForEachVirtualEquipment(function(item)
        local resist = item.components ~= nil and item.components.damagetyperesist or nil
        if resist ~= nil and resist.GetResist ~= nil then
            local ok, value = pcall(resist.GetResist, resist, attacker, weapon)
            if ok and type(value) == "number" then
                multiplier = multiplier * value
            end
        end
    end)
    return multiplier
end

-- Inventory:ApplyDamage 对每种特殊伤害把所有装备提供的防御值相加后
-- 扣除。虚拟装备没有公共装备槽，所以这里返回等价的总防御值；具体扣除
-- 在 inventory hook 中完成，再交回原版处理真实装备的部分。
function KeiProtocolSlots:GetVirtualSpDefenseForType(sptype)
    local defense = 0
    self:ForEachVirtualEquipment(function(item)
        local value = SpDamageUtil.GetSpDefenseForType(item, sptype)
        if type(value) == "number" and value > 0 then
            defense = defense + value
        end
    end)
    return defense
end

-- 原版 Inventory:ApplyDamage 会先检查装备上的 resistance 组件，再进行护甲
-- 吸收计算。解析护甲已经不在 inventory.equipslots 中，因此必须由协议组件
-- 显式执行同样的短路逻辑；否则 armorskeleton 的充能护盾永远不会拦截攻击。
function KeiProtocolSlots:TryResistDamage(damage, attacker, weapon)
    local resisted = false
    self:ForEachVirtualEquipment(function(item)
        if resisted then
            return
        end

        local resistance = item.components ~= nil and item.components.resistance or nil
        if resistance ~= nil
            and resistance.HasResistance ~= nil
            and resistance:HasResistance(attacker, weapon)
            and (resistance.ShouldResistDamage == nil or resistance:ShouldResistDamage())
        then
            if resistance.ResistDamage ~= nil then
                resistance:ResistDamage(damage, attacker)
            end
            resisted = true
        end
    end)
    return resisted
end

function KeiProtocolSlots:RemoveHandVirtualEquip()
    local result = VirtualHandEquipment.Remove(self)
    self:SyncVirtualStaffState()
    return result
end

function KeiProtocolSlots:ApplyHandVirtualEquip(entry)
    local result = VirtualHandEquipment.Apply(self, entry)
    self:SyncVirtualStaffState()
    return result
end

function KeiProtocolSlots:SyncVirtualStaffState()
    local inventory = self.inst.components ~= nil and self.inst.components.inventory or nil
    local equipped = inventory ~= nil and inventory:GetEquippedItem(EQUIPSLOTS.HANDS) or nil
    local is_virtual_staff = VirtualHandEquipment.IsVirtualStaff(equipped)
    if self.inst._kei_virtual_staff_equipped ~= nil then
        self.inst._kei_virtual_staff_equipped:set(is_virtual_staff)
    end
end

----------------------------------------------------------------
-- 修饰符清理
----------------------------------------------------------------

function KeiProtocolSlots:ClearModifiers()
    self:RemoveHandVirtualEquip()
    self:ClearVirtualEquips()
    HandAnalysisInheritance.Clear(self)
    for _, handler in pairs(LIFE_EFFECTS) do
        if handler.Disable then
            handler.Disable(self, self.inst)
        end
    end

    -- 调用所有战斗效果处理器的 Disable。
    for _, handler in pairs(EFFECT_HANDLERS) do
        if handler.Disable then
            handler.Disable(self, self.inst)
        end
    end

    if self.inst.components.health ~= nil then
        self.inst.components.health.externalabsorbmodifiers:RemoveModifier(self.inst, ANALYSIS_ARMOR_MODIFIER)
        -- 只清理龙蝇协议注册的 key，不能按 source 无条件清空其它 Mod
        -- 可能挂在同一个角色实例上的火焰伤害修饰器。
        self.inst.components.health.externalfiredamagemultipliers:RemoveModifier(
            self.inst,
            DRAGONFLY_FIRE_IMMUNITY_MODIFIER
        )
        if self.inst.components.health.deltamodifierfn == self._kei_basic_attribute_deltamodifierfn then
            self.inst.components.health.deltamodifierfn = self._old_health_deltamodifierfn
        end
    end
    self._combat_damage_reductions = {}
    self._combat_damage_multipliers = {}
    RefreshCombatDamageMultiplier(self)
    self:ApplyBasicAttributes({})
end

----------------------------------------------------------------
-- 持续效果查询 API
----------------------------------------------------------------

function KeiProtocolSlots:HasFreezeImmunity()
    return BeastCommon.HasAnySource(self._kei_deerclops_freeze_sources)
end

function KeiProtocolSlots:HasOverheatImmunity()
    return BeastCommon.HasAnySource(self._kei_dragonfly_sources)
end

function KeiProtocolSlots:HasStaggerImmunity()
    return BeastCommon.HasAnySource(self._kei_shared_immunity_sources)
end

function KeiProtocolSlots:HasControlImmunity()
    return BeastCommon.HasAnySource(self._kei_shared_immunity_sources)
end

function KeiProtocolSlots:HasMutatedBeargerAttackSpeed()
    return BeastCommon.HasAnySource(self._kei_mutatedbearger_sources)
end

function KeiProtocolSlots:HasVaultPillarGuardSpeed()
    return BeastCommon.HasAnySource(self._kei_vpg_speed_sources)
end

function KeiProtocolSlots:HasVaultPillarGuardSpin()
    return BeastCommon.HasAnySource(self._kei_vpg_spin_sources)
end

function KeiProtocolSlots:DisableAllProtocols()
    if self._protocols_disabled then
        return
    end
    self._protocols_disabled = true
    self.active = {}
    self.active_combat = {}
    self.active_life = {}
    self.active_basic_attributes = {}
    -- ClearModifiers removes effect-owned tags/modifiers. The next functional
    -- refresh must rebuild from slots and run Enable again for every protocol.
    -- This is especially important for vault_pillar_guard, whose effect is
    -- represented by tags consumed by the combat hooks.
    self._prev_active_combat = {}
    self._protocol_state_dirty = true
    self._implanted_effects_dirty = true
    self:SyncCombatProtocolFlags()
    self:SyncLifeProtocolFlags()
    self:SetProtocolContainersPowered(false)
    self:ClearModifiers()
end

----------------------------------------------------------------
-- 协议查询 API
----------------------------------------------------------------

function KeiProtocolSlots:HasCombatProtocol(protocol)
    return self:IsFunctional() and self.active_combat[protocol] == true
end

function KeiProtocolSlots:GetLifeProtocolCount(protocol)
    return self:IsFunctional() and (self.active_life[protocol] or 0) or 0
end

function KeiProtocolSlots:HasLifeProtocol(protocol)
    return self:GetLifeProtocolCount(protocol) > 0
end

function KeiProtocolSlots:IsLifeRecipeUnlocked(recipe)
    return self.permanent_life_recipes ~= nil
        and self.permanent_life_recipes[recipe] == true
end

function KeiProtocolSlots:ConsumeLifeProtocol(protocol)
    if protocol == nil or not self:IsFunctional() then
        return false
    end

    local inventory = self.inst.components ~= nil and self.inst.components.inventory or nil
    if inventory == nil then
        return false
    end

    for slot = 1, ProtocolSlotUnlocks.GetMaxSlots() do
        local protocol_container = inventory:GetItemInSlot(slot)
        local container = protocol_container ~= nil
            and IsProtocolContainer(protocol_container)
            and protocol_container.components ~= nil
            and protocol_container.components.container
            or nil
        local item = container ~= nil and container:GetItemInSlot(1) or nil
        local data = IsProtocol(item) and item.kei_protocol_data or nil

        if slot <= self.unlocked_slots
            and data ~= nil
            and data.kind == "life"
            and data.protocol == protocol
            and self:CanRun(data)
        then
            local consumed = container:RemoveItemBySlot(1, true)
            if consumed == nil then
                return false
            end

            if consumed:IsValid() then
                consumed:Remove()
            end

            self._protocol_state_dirty = true
            self:Refresh()
            return true
        end
    end

    return false
end

----------------------------------------------------------------
-- 网络同步
----------------------------------------------------------------

function KeiProtocolSlots:SyncLifeProtocolFlags()
    if self.inst._kei_map_teleport_protocol_active ~= nil then
        self.inst._kei_map_teleport_protocol_active:set(self:HasLifeProtocol("map_teleport"))
    end
    if self.inst._kei_water_walk_protocol_active ~= nil then
        self.inst._kei_water_walk_protocol_active:set(self:HasLifeProtocol("water_walk"))
    end
end

function KeiProtocolSlots:SyncCombatProtocolFlags()
    if self.inst._kei_eyeofterror_protocol_active ~= nil then
        self.inst._kei_eyeofterror_protocol_active:set(self:HasCombatProtocol("eyeofterror") or self:HasCombatProtocol("eyeofterror_basic"))
    end
    local daywalker_active = self:HasCombatProtocol("daywalker") or self:HasCombatProtocol("daywalker_basic")
    if self.inst._kei_daywalker_protocol_active ~= nil then
        self.inst._kei_daywalker_protocol_active:set(daywalker_active)
    end

    if self.inst._kei_mutatedwarg_protocol_active ~= nil then
        self.inst._kei_mutatedwarg_protocol_active:set(self:HasCombatProtocol("mutatedwarg"))
    end
    if self.inst._kei_rook_protocol_active ~= nil then
        self.inst._kei_rook_protocol_active:set(self:HasCombatProtocol("rook"))
    end
    if not daywalker_active then
        self.inst.kei_daywalker_aiming = nil
        if self.inst._kei_daywalker_aiming ~= nil then
            self.inst._kei_daywalker_aiming:set(false)
        end
    end
end

----------------------------------------------------------------
-- 效果分发
----------------------------------------------------------------

function KeiProtocolSlots:RefreshLifeEffects()
    LifeRecipeUnlocks.Sync(self.inst)
    for protocol, handler in pairs(LIFE_EFFECTS) do
        local stacks = self.active_life[protocol] or 0
        if stacks > 0 then
            if handler.Enable then
                handler.Enable(self, self.inst, stacks)
            end
        else
            if handler.Disable then
                handler.Disable(self, self.inst)
            end
        end
    end
end

function KeiProtocolSlots:RefreshEffects(force_enable)
    self:RefreshLifeEffects()
    local prev = self._prev_active_combat or {}
    local implanted_effects_dirty = self._implanted_effects_dirty == true
    self._prev_active_combat = {}


    for protocol, handler in pairs(EFFECT_HANDLERS) do
        local is_active = self.active_combat[protocol] == true
        self._prev_active_combat[protocol] = is_active
        local was_active = prev[protocol] == true

        -- 状态脏刷新时重新执行 Enable，校准读档、槽位变化或统一清理后
        -- 的实际标签/修饰器；深度植入也始终不依赖普通 CD 的资源状态。
        if is_active and (not was_active
            or force_enable == true
            or (implanted_effects_dirty and self:IsDeeplyImplanted(protocol)))
        then
            if handler.Enable then
                handler.Enable(self, self.inst)
            end
        elseif not is_active and was_active then
            if handler.Disable then
                handler.Disable(self, self.inst)
            end
        end
    end
    self._implanted_effects_dirty = nil
end

----------------------------------------------------------------
-- 核心刷新与消耗
----------------------------------------------------------------

function KeiProtocolSlots:Refresh()
    if not self:IsFunctional() then
        self:DisableAllProtocols()
        return
    end
    self._protocols_disabled = false
    self:SetProtocolContainersPowered(true)

    local state_dirty = self._protocol_state_dirty == true
    local implanted_effects_dirty = self._implanted_effects_dirty == true
    if not state_dirty and not implanted_effects_dirty then
        return
    end

    local items = state_dirty and self:GetProtocolSlotItems() or self.active
    self._protocol_state_dirty = nil
    local combat = {}
    local life = {}
    local basic_attributes = {}
    local hand_stats = HandAnalysisInheritance.NewStats()
    local desired_virtuals = {}
    local wants_hand_virtual = false

    self.active = items

    for _, entry in ipairs(items) do
        local data = entry.data
        if self.inst.components.kei_taskbook ~= nil then
            self.inst.components.kei_taskbook:RecordProtocolData(data, entry.item.prefab)
        end
        if data.kind == "combat" and data.protocol ~= nil then
            combat[data.protocol] = true
        elseif data.kind == "life" and data.protocol ~= nil then
            local definition = LIFE_PROTOCOLS[data.protocol]
            if definition ~= nil and definition.stackable == true then
                life[data.protocol] = (life[data.protocol] or 0) + 1
            else
                life[data.protocol] = 1
            end
        elseif data.kind == "basic_attribute" then
            AddBasicAttributeValue(basic_attributes, data)
        elseif data.kind == "analysis" then
            if data.slot == "head" or data.slot == "body" then
                desired_virtuals[entry.slot] = true
                self:ApplyVirtualEquip(entry)
            elseif data.slot == "hands" then
                if entry.slot == 1 then
                    -- 第一格是完整继承：虚拟手部装备无法生成时，第一格协议整体不生效。
                    if not self._kei_suppress_hand_virtual and self:ApplyHandVirtualEquip(entry) then
                        wants_hand_virtual = true
                    end
                else
                    -- 只有第二格及之后的手部协议才提供 2 类继承的面板伤害。
                    HandAnalysisInheritance.AddStats(hand_stats, data)
                end
            end
        end
    end

    self:ClearVirtualEquips(desired_virtuals)
    if not wants_hand_virtual then
        self:RemoveHandVirtualEquip()
    end
    -- 深度植入协议不进入 GetProtocolSlotItems，因此不会经过 CanRun 的
    -- 电量/稳定性检查，也不会出现在 DrainProtocols 的普通 CD 消耗列表中。
    for protocol, implanted in pairs(self.implanted_combat_protocols) do
        if implanted == true then
            combat[protocol] = true
        end
    end
    for _, data in ipairs(self.implanted_basic_attributes) do
        AddBasicAttributeValue(basic_attributes, data)
    end

    self.active_combat = combat
    self.active_life = life
    self.active_basic_attributes = basic_attributes
    self:ApplyBasicAttributes(basic_attributes)
    self:RefreshEffects(state_dirty)
    self:SyncLifeProtocolFlags()
    self:SyncCombatProtocolFlags()

    if self.inst.components.health ~= nil then
        self.inst.components.health.externalabsorbmodifiers:RemoveModifier(self.inst, ANALYSIS_ARMOR_MODIFIER)
    end
    HandAnalysisInheritance.Apply(self, hand_stats)
    self:SyncCombatStatusValues()
end

function KeiProtocolSlots:DrainProtocols()
    if not self:IsFunctional() then
        self:DisableAllProtocols()
        return
    end

    self:Refresh()

    if self.active_combat.alterguardian and self.inst.components.hunger ~= nil then
        self.inst.components.hunger:DoDelta(TUNING.KEI_ALTERGUARDIAN_POWER_REGEN or 10)
    end

    -- 果蝇王协议停止额外消耗，但不阻止天体英雄协议的回电。
    if self.active_combat.lordfruitfly then
        return
    end

    local power_cost = 0
    local stability_cost = 0
    local drain = GetProtocolDrainSettings()

    for _, entry in ipairs(self.active) do
        local data = entry.data
        if ProtocolNeedsPower(data) then
            power_cost = power_cost + drain.analysis_amount
        elseif ProtocolNeedsStability(data) then
            stability_cost = stability_cost + drain.combat_amount
        end
    end

    if self.active_combat.lordfruitfly_basic then
        power_cost = power_cost * 0.5
        stability_cost = stability_cost * 0.5
    end

    power_cost = math.min(power_cost, drain.cap)
    stability_cost = math.min(stability_cost, drain.cap)

    local silent_drain = not TUNING.KEI_PROTOCOL_DRAIN_SOUND
    if power_cost > 0 and self.inst.components.hunger ~= nil then
        self.inst.components.hunger:DoDelta(-power_cost * self:GetPowerDrainMultiplier(), silent_drain)
    end
    if stability_cost > 0 and self.inst.components.sanity ~= nil then
        self.inst.components.sanity:DoDelta(-stability_cost, silent_drain)
    end

    self:Refresh()
end

----------------------------------------------------------------
-- 事件分发
----------------------------------------------------------------

function KeiProtocolSlots:OnHitOther(data)
    if not self:IsFunctional() then return end
    local target = data and data.target
    if target == nil or not target:IsValid() then return end

    for protocol, handler in pairs(EFFECT_HANDLERS) do
        if self.active_combat[protocol] and handler.OnHitOther then
            handler.OnHitOther(self, self.inst, data)
        end
    end
end

function KeiProtocolSlots:OnAttacked(data)
    if not self:IsFunctional() then return end

    for protocol, handler in pairs(EFFECT_HANDLERS) do
        if self.active_combat[protocol] and handler.OnAttacked then
            handler.OnAttacked(self, self.inst, data)
        end
    end
end

----------------------------------------------------------------
-- 存档 / 读档
----------------------------------------------------------------

function KeiProtocolSlots:OnSave()
    return {
        unlocked_slots = self.unlocked_slots,
        mini_alice_pages = self.mini_alice_pages,
        implanted_combat_protocols = self.implanted_combat_protocols,
        implanted_basic_attributes = self.implanted_basic_attributes,
        permanent_life_recipes = self.permanent_life_recipes,
        analysis_armor_upgrade_level = self.analysis_armor_upgrade_level,
    }
end

function KeiProtocolSlots:OnLoad(data)
    if data ~= nil and data.unlocked_slots ~= nil then
        self.unlocked_slots = ProtocolSlotUnlocks.ClampUnlockedSlots(data.unlocked_slots)
    end
    self.mini_alice_pages = data ~= nil and data.mini_alice_pages or 1
    self.analysis_armor_upgrade_level = AnalysisArmorUpgrade.ClampLevel(
        data ~= nil and data.analysis_armor_upgrade_level or 0
    )
    if self.inst.components ~= nil and self.inst.components.kei_experience ~= nil then
        self.inst.components.kei_experience:RecalculateMax()
    end
    self.implanted_combat_protocols = data ~= nil and data.implanted_combat_protocols or {}
    self.implanted_basic_attributes = NormalizeImplantedBasicAttributes(
        data ~= nil and data.implanted_basic_attributes or {}
    )
    self._implanted_effects_dirty = true
    self.permanent_life_recipes = data ~= nil and data.permanent_life_recipes or {}
    self:SyncUnlockedSlots()
    self:SyncMiniAlicePages()
    self:SyncAnalysisArmorUpgrade()
    self:ApplyStatProgression()

    -- OnLoad can run after the constructor's first refresh. Mark the complete
    -- state dirty so inserted CDs and implanted protocols are rebuilt together.
    self:ScheduleRefresh()
end

function KeiProtocolSlots:LoadPostPass()
    -- Inventory/container contents are guaranteed to exist by LoadPostPass.
    -- Re-scan here as well because component OnLoad order is not deterministic.
    self._prev_active_combat = {}
    self._protocol_state_dirty = true
    self._implanted_effects_dirty = true
    self:EnsureProtocolContainers()
    self:Refresh()
    -- Some protocol container entities finish restoring their contents after
    -- this component's post-pass. Queue one final scan after the load stack.
    self:ScheduleRefresh()
end

return KeiProtocolSlots
