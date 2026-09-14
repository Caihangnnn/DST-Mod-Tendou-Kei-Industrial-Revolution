-- Dynamic modifiers shared by every boss summoned through a data recorder.
-- Values are sampled from the living players inside the recorder arena.

local RecorderBoss = {}

local DAMAGE_MODIFIER = "kei_recorder_boss_dynamic_damage"
local ABSORB_MODIFIER = "kei_recorder_boss_dynamic_absorb"
local MAX_DAMAGE_REDUCTION = 0.8

local function Clamp01(value)
    return math.min(1, math.max(0, tonumber(value) or 0))
end

local function GetArmorAbsorption(player)
    local inventory = player ~= nil and player.components ~= nil and player.components.inventory or nil
    local protocolslots = player ~= nil and player.components ~= nil and player.components.kei_protocolslots or nil

    local absorption = 0
    if inventory ~= nil then
        for _, item in pairs(inventory.equipslots or {}) do
            local armor = item ~= nil and item.components ~= nil and item.components.armor or nil
            if armor ~= nil then
                local value = nil
                if armor.GetAbsorption ~= nil then
                    local ok, result = pcall(armor.GetAbsorption, armor, nil, nil)
                    if ok then
                        value = result
                    end
                end
                value = value ~= nil and value or armor.absorb_percent
                absorption = math.max(absorption, Clamp01(value))
            end
        end
    end

    -- Kei 的解析护甲是协议组件管理的私有装备，不在原版 equipslots 中。
    if protocolslots ~= nil and protocolslots.GetVirtualArmorAbsorption ~= nil then
        absorption = math.max(absorption, Clamp01(protocolslots:GetVirtualArmorAbsorption(nil, nil)))
    end
    return absorption
end

local function GetAttackMultiplier(player)
    local combat = player ~= nil and player.components ~= nil and player.components.combat or nil
    if combat == nil then
        return 1
    end

    local base_multiplier = math.max(0, tonumber(combat.damagemultiplier) or 1)
    local external_multiplier = 1
    if combat.externaldamagemultipliers ~= nil then
        external_multiplier = math.max(0, tonumber(combat.externaldamagemultipliers:Get()) or 1)
    end
    return base_multiplier * external_multiplier
end

local function GetDamageReduction(player)
    local health = player ~= nil and player.components ~= nil and player.components.health or nil
    if health == nil then
        return 0
    end

    local external_absorb = 0
    if health.externalabsorbmodifiers ~= nil then
        external_absorb = Clamp01(health.externalabsorbmodifiers:Get())
    end

    local combat_reduction = 0
    local slots = player.components.kei_protocolslots
    if slots ~= nil and slots.GetCombatDamageReduction ~= nil then
        combat_reduction = Clamp01(slots:GetCombatDamageReduction())
    end

    local basic_reduction = 0
    if slots ~= nil then
        local modifiers = slots.basic_attribute_modifiers or {}
        basic_reduction = math.min(
            TUNING.KEI_BASIC_ATTRIBUTE_MAX_DAMAGE_REDUCTION or 90,
            math.max(0, tonumber(modifiers.percent_damage_reduction) or 0)
        ) / 100
    end

    local remaining_damage = (1 - GetArmorAbsorption(player))
        * (1 - external_absorb)
        * (1 - combat_reduction)
        * (1 - basic_reduction)
    return math.min(MAX_DAMAGE_REDUCTION, Clamp01(1 - remaining_damage))
end

local function IsLivingPlayer(player)
    return player ~= nil
        and player:IsValid()
        and player:HasTag("player")
        and not player:HasTag("playerghost")
        and player.components ~= nil
        and player.components.health ~= nil
        and not player.components.health:IsDead()
end

local function IsPointInArena(source, px, pz)
    if WAGPUNK_ARENA_COLLISION_DATA == nil or #WAGPUNK_ARENA_COLLISION_DATA < 3 then
        local radius = TUNING.KEI_RECORDER_RANGE or 35
        return source:GetDistanceSqToPoint(px, 0, pz) <= radius * radius
    end

    local cx, _, cz = source.Transform:GetWorldPosition()
    local x = px - cx
    local z = pz - cz
    local inside = false
    local previous = WAGPUNK_ARENA_COLLISION_DATA[#WAGPUNK_ARENA_COLLISION_DATA]
    for _, current in ipairs(WAGPUNK_ARENA_COLLISION_DATA) do
        local x1, z1 = previous[1], previous[2]
        local x2, z2 = current[1], current[2]
        if (z1 > z) ~= (z2 > z) and x < (x2 - x1) * (z - z1) / (z2 - z1) + x1 then
            inside = not inside
        end
        previous = current
    end
    return inside
end

function RecorderBoss.GetArenaPlayers(source)
    local players = {}
    if source == nil or not source:IsValid() then
        return players
    end

    for _, player in ipairs(AllPlayers or {}) do
        if IsLivingPlayer(player) then
            local px, _, pz = player.Transform:GetWorldPosition()
            if IsPointInArena(source, px, pz) then
                table.insert(players, player)
            end
        end
    end
    return players
end

function RecorderBoss.GetRandomArenaPoint(source)
    if source == nil or not source:IsValid() then
        return nil
    end

    local cx, _, cz = source.Transform:GetWorldPosition()
    if WAGPUNK_ARENA_COLLISION_DATA == nil or #WAGPUNK_ARENA_COLLISION_DATA < 3 then
        local radius = TUNING.KEI_RECORDER_RANGE or 35
        local angle = math.random() * TWOPI
        local distance = math.sqrt(math.random()) * radius
        return cx + math.cos(angle) * distance, cz + math.sin(angle) * distance
    end

    local min_x, max_x = math.huge, -math.huge
    local min_z, max_z = math.huge, -math.huge
    for _, point in ipairs(WAGPUNK_ARENA_COLLISION_DATA) do
        min_x = math.min(min_x, point[1])
        max_x = math.max(max_x, point[1])
        min_z = math.min(min_z, point[2])
        max_z = math.max(max_z, point[2])
    end

    for _ = 1, 24 do
        local x = cx + min_x + math.random() * (max_x - min_x)
        local z = cz + min_z + math.random() * (max_z - min_z)
        if IsPointInArena(source, x, z) then
            return x, z
        end
    end

    return cx, cz
end

local function GetArenaValues(source)
    local attack_multiplier = 1
    local damage_reduction = 0
    if source == nil or not source:IsValid() then
        return attack_multiplier, damage_reduction
    end

    for _, player in ipairs(RecorderBoss.GetArenaPlayers(source)) do
        attack_multiplier = math.max(attack_multiplier, GetAttackMultiplier(player))
        damage_reduction = math.max(damage_reduction, GetDamageReduction(player))
    end
    return attack_multiplier, damage_reduction
end

local function Update(target)
    if target == nil or not target:IsValid() then
        return false
    end

    local source = target.kei_recorder_source
    if source == nil or not source:IsValid() then
        return false
    end

    local attack_multiplier, damage_reduction = GetArenaValues(source)
    local combat = target.components ~= nil and target.components.combat or nil
    if combat ~= nil and combat.externaldamagemultipliers ~= nil then
        combat.externaldamagemultipliers:RemoveModifier(target, DAMAGE_MODIFIER)
        if attack_multiplier ~= 1 then
            combat.externaldamagemultipliers:SetModifier(target, attack_multiplier, DAMAGE_MODIFIER)
        end
    end

    local health = target.components ~= nil and target.components.health or nil
    if health ~= nil and health.externalabsorbmodifiers ~= nil then
        health.externalabsorbmodifiers:RemoveModifier(target, ABSORB_MODIFIER)
        if damage_reduction > 0 then
            health.externalabsorbmodifiers:SetModifier(target, damage_reduction, ABSORB_MODIFIER)
        end
    end

    target.kei_recorder_dynamic_attack_multiplier = attack_multiplier
    target.kei_recorder_dynamic_damage_reduction = damage_reduction
    return true
end

function RecorderBoss.Apply(target, source)
    if target == nil or not target:IsValid() then
        return false
    end

    RecorderBoss.Remove(target)
    target.kei_recorder_source = source
    Update(target)
    target.kei_recorder_dynamic_update_task = target:DoPeriodicTask(
        TUNING.KEI_RECORDER_BOSS_DYNAMIC_UPDATE_PERIOD or 3,
        function(inst)
            if not Update(inst) and inst.kei_recorder_dynamic_update_task ~= nil then
                inst.kei_recorder_dynamic_update_task:Cancel()
                inst.kei_recorder_dynamic_update_task = nil
            end
        end
    )
    return true
end

function RecorderBoss.Remove(target)
    if target == nil then
        return
    end

    if target.kei_recorder_dynamic_update_task ~= nil then
        target.kei_recorder_dynamic_update_task:Cancel()
        target.kei_recorder_dynamic_update_task = nil
    end

    local combat = target.components ~= nil and target.components.combat or nil
    if combat ~= nil and combat.externaldamagemultipliers ~= nil then
        combat.externaldamagemultipliers:RemoveModifier(target, DAMAGE_MODIFIER)
    end

    local health = target.components ~= nil and target.components.health or nil
    if health ~= nil and health.externalabsorbmodifiers ~= nil then
        health.externalabsorbmodifiers:RemoveModifier(target, ABSORB_MODIFIER)
    end

    target.kei_recorder_dynamic_attack_multiplier = nil
    target.kei_recorder_dynamic_damage_reduction = nil
end

return RecorderBoss
