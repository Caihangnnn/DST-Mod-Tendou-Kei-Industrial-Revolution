-- 天体宝珠协议：环绕宝珠 AOE 伤害。

local BeastCommon = require("kei/protocols/combat/effects/beast/_beast_common")
local KeiEffectManager = require("kei/effect_manager")
local CELESTIAL_ORB_FOLLOW_PERIOD = FRAMES
local CELESTIAL_ORB_TARGET_MUST_TAGS = { "_combat", "_health" }
local CELESTIAL_ORB_TARGET_EXCLUDE_TAGS = { "INLIMBO", "FX", "NOCLICK", "DECOR", "player", "playerghost", "companion" }

local CelestialOrbEffect = {}

-- ---------- 辅助函数 ----------

local function IsValidTarget(owner, target)
    return owner ~= nil
        and owner:IsValid()
        and owner.components.combat ~= nil
        and target ~= nil
        and target:IsValid()
        and target.entity:IsVisible()
        and target.components.combat ~= nil
        and target.components.health ~= nil
        and not target.components.health:IsDead()
        and owner.components.combat:CanTarget(target)
        and not owner.components.combat:IsAlly(target)
end

-- ---------- 宝珠生命周期 ----------

local function SpawnOrb(slots, index)
    local orb = SpawnPrefab("kei_celestial_orb_fx")
    if orb == nil then
        return nil
    end
    orb.persists = false
    slots._kei_celestial_orbs[index] = orb
    KeiEffectManager.Register(slots.inst, orb, "celestial_orb_" .. tostring(index), function()
        if slots._kei_celestial_orbs ~= nil then
            slots._kei_celestial_orbs[index] = nil
        end
    end)
    return orb
end

local function EnsureOrbs(slots, inst)
    local count = TUNING.KEI_CELESTIAL_ORB_COUNT or 5
    slots._kei_celestial_orbs = slots._kei_celestial_orbs or {}
    slots._kei_celestial_orb_angles = slots._kei_celestial_orb_angles or {}

    for index = 1, count do
        local orb = slots._kei_celestial_orbs[index]
        if orb == nil or not orb:IsValid() then
            orb = SpawnOrb(slots, index)
        end
        if slots._kei_celestial_orb_angles[index] == nil then
            slots._kei_celestial_orb_angles[index] = (index - 1) * TWOPI / count
        end
    end

    for index = count + 1, #(slots._kei_celestial_orbs or {}) do
        local orb = slots._kei_celestial_orbs[index]
        if orb ~= nil and orb:IsValid() then
            orb:Remove()
        end
        KeiEffectManager.Remove(slots.inst, "celestial_orb_" .. tostring(index), "orb_count_changed")
        slots._kei_celestial_orbs[index] = nil
        slots._kei_celestial_orb_angles[index] = nil
    end
end

local function DealDamageAtPoint(slots, inst, orb_index, x, y, z)
    local damage = slots._kei_celestial_orb_damage or 0
    if slots._doing_celestial_orb_damage or damage <= 0 then
        return
    end

    local now = GetTime()
    local hit_radius = TUNING.KEI_CELESTIAL_ORB_HIT_RADIUS or 1.35
    local targets = TheSim:FindEntities(
        x, y, z, hit_radius,
        CELESTIAL_ORB_TARGET_MUST_TAGS,
        CELESTIAL_ORB_TARGET_EXCLUDE_TAGS
    )

    for _, target in ipairs(targets) do
        local target_hits = slots._kei_celestial_orb_hit_times[target]
        if target_hits == nil then
            target_hits = {}
            slots._kei_celestial_orb_hit_times[target] = target_hits
        end

        if IsValidTarget(inst, target) and (target_hits[orb_index] or 0) <= now then
            target_hits[orb_index] = slots._kei_celestial_orb_accel_until or now
            slots._doing_celestial_orb_damage = true
            target.components.combat:GetAttacked(inst, damage, slots._kei_celestial_orb_weapon)
            slots._doing_celestial_orb_damage = nil
        end
    end
end

local function UpdateOrbs(slots, inst)
    if not BeastCommon.HasProtocol(slots, "alterguardian_phase4_lunarrift") then
        CelestialOrbEffect.Disable(slots, inst)
        return
    end

    EnsureOrbs(slots, inst)

    local count = TUNING.KEI_CELESTIAL_ORB_COUNT or 5
    local radius = TUNING.KEI_CELESTIAL_ORB_RADIUS or 2.7
    local height = TUNING.KEI_CELESTIAL_ORB_HEIGHT or 1
    local now = GetTime()
    local accelerated = (slots._kei_celestial_orb_accel_until or 0) > now
    local speed = accelerated
        and (TUNING.KEI_CELESTIAL_ORB_ATTACK_SPEED or 0.22)
        or (TUNING.KEI_CELESTIAL_ORB_IDLE_SPEED or 0.012)
    local x, y, z = inst.Transform:GetWorldPosition()

    for index = 1, count do
        local angle = (slots._kei_celestial_orb_angles[index] or ((index - 1) * TWOPI / count))
            + speed * CELESTIAL_ORB_FOLLOW_PERIOD * 60
        slots._kei_celestial_orb_angles[index] = angle

        local orb = slots._kei_celestial_orbs[index]
        if orb ~= nil and orb:IsValid() then
            local orb_x = x + math.cos(angle) * radius
            local orb_z = z + math.sin(angle) * radius
            orb.Transform:SetPosition(orb_x, y + height, orb_z)
            if accelerated then
                DealDamageAtPoint(slots, inst, index, orb_x, y, orb_z)
            end
        end
    end
end

-- ---------- 接口方法 ----------

function CelestialOrbEffect.Enable(slots, inst)
    EnsureOrbs(slots, inst)
    UpdateOrbs(slots, inst)

    if slots._kei_celestial_orb_task == nil then
        slots._kei_celestial_orb_task = inst:DoPeriodicTask(CELESTIAL_ORB_FOLLOW_PERIOD, function()
            UpdateOrbs(slots, inst)
        end)
        KeiEffectManager.RegisterTask(inst, slots._kei_celestial_orb_task, "celestial_orb_follow", function()
            slots._kei_celestial_orb_task = nil
        end)
    end
end

-- 关闭协议效果，并清理启用时注册的持续能力。
function CelestialOrbEffect.Disable(slots, inst)
    if slots._kei_celestial_orb_task ~= nil then
        slots._kei_celestial_orb_task:Cancel()
        slots._kei_celestial_orb_task = nil
    end

    for index, orb in pairs(slots._kei_celestial_orbs or {}) do
        if orb ~= nil and orb:IsValid() then
            orb:Remove()
        end
        KeiEffectManager.Remove(slots.inst, "celestial_orb_" .. tostring(index), "protocol_disable")
        slots._kei_celestial_orbs[index] = nil
    end

    slots._kei_celestial_orb_angles = {}
    slots._kei_celestial_orb_accel_until = nil
    slots._kei_celestial_orb_damage = nil
    slots._kei_celestial_orb_weapon = nil
    slots._kei_celestial_orb_hit_times = setmetatable({}, { __mode = "k" })
end

-- 处理攻击命中事件，根据协议等级触发附加战斗效果。
function CelestialOrbEffect.OnHitOther(slots, inst, data)
    local target = data and data.target
    local damage = data and (data.damageresolved or 0)
    local weapon = data and data.weapon

    if slots._doing_celestial_orb_damage
        or (damage or 0) <= 0
        or not IsValidTarget(inst, target)
    then
        return
    end

    local orb_damage = damage * (TUNING.KEI_CELESTIAL_ORB_DAMAGE_MULT or 0.2)
    if orb_damage <= 0 then
        return
    end

    slots._kei_celestial_orb_accel_until = math.max(
        slots._kei_celestial_orb_accel_until or 0,
        GetTime() + (TUNING.KEI_CELESTIAL_ORB_ACCEL_DURATION or 1.25)
    )
    slots._kei_celestial_orb_damage = orb_damage
    slots._kei_celestial_orb_weapon = weapon
    slots._kei_celestial_orb_hit_times = setmetatable({}, { __mode = "k" })
end

return CelestialOrbEffect
