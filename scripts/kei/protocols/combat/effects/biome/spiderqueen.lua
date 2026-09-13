-- 蜘蛛女王协议：角色周围始终视为蜘蛛网区域，减速非友方地面单位，并避免蜘蛛主动仇恨。

local SPIDER_QUEEN_WEB_KEY = "kei_spiderqueen_web"
local SPIDER_QUEEN_MUST_TAGS = { "_combat", "_health" }
local SPIDER_QUEEN_EXCLUDE_TAGS = { "INLIMBO", "FX", "NOCLICK", "DECOR", "player", "playerghost", "flying", "companion" }

local SlowSources = require("kei/slow_sources")
local KeiEffectManager = require("kei/effect_manager")

local SpiderQueenEffect = {}

local function HasSpiderHatEquipped(inst)
    local inventory = inst.components.inventory
    if inventory == nil then
        return false
    end

    local hat = inventory:GetEquippedItem(EQUIPSLOTS.HEAD)
    return hat ~= nil and hat.prefab == "spiderhat"
end

-- 添加原版蜘蛛索敌会识别的伪装 tag，但不附带韦伯的蜘蛛互动能力。
local function EnableSpiderDisguise(slots, inst)
    if inst:HasTag("spiderwhisperer") or inst:HasTag("spiderdisguise") then
        slots._kei_spider_queen_added_spiderdisguise = nil
        return
    end

    inst:AddTag("spiderdisguise")
    slots._kei_spider_queen_added_spiderdisguise = true
end

-- 只移除本协议添加的伪装 tag，避免覆盖蜘蛛帽等其它来源。
local function DisableSpiderDisguise(slots, inst)
    if slots._kei_spider_queen_added_spiderdisguise then
        if not HasSpiderHatEquipped(inst) then
            inst:RemoveTag("spiderdisguise")
        end
        slots._kei_spider_queen_added_spiderdisguise = nil
    end
end

local function IsValidTarget(owner, target)
    if target == nil
        or target == owner
        or not target:IsValid()
        or target:IsInLimbo()
        or target.components.health == nil
        or target.components.health:IsDead()
        or target.components.combat == nil
    then
        return false
    end
    local combat = owner.components.combat
    return combat == nil or not combat:IsAlly(target)
end

local function SpawnWebFx(slots, inst)
    local radius = TUNING.KEI_SPIDERQUEEN_WEB_RADIUS or 6
    local fx = slots._kei_spider_queen_web_fx
    if fx ~= nil and fx:IsValid() then
        fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
        if fx.SetRadius ~= nil then
            fx:SetRadius(radius)
        end
        return
    end

    fx = SpawnPrefab("kei_spiderqueen_web_fx")
    if fx == nil then
        return
    end

    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    if fx.SetRadius ~= nil then
        fx:SetRadius(radius)
    end

    slots._kei_spider_queen_web_fx = fx
    KeiEffectManager.Register(inst, fx, "spiderqueen_web", function()
        slots._kei_spider_queen_web_fx = nil
        slots._kei_spider_queen_follow_task = nil
    end)

    if slots._kei_spider_queen_follow_task == nil then
        slots._kei_spider_queen_follow_task = inst:DoPeriodicTask(FRAMES, function()
            local web_fx = slots._kei_spider_queen_web_fx
            if web_fx ~= nil and web_fx:IsValid() then
                web_fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
            end
        end)
        KeiEffectManager.SetTask(inst, "spiderqueen_web", slots._kei_spider_queen_follow_task)
    end
end

local function SyncWebFxScale(slots, inst)
    local fx = slots._kei_spider_queen_web_fx
    if fx == nil or not fx:IsValid() then
        return
    end
    if fx.SetRadius ~= nil then
        fx:SetRadius(TUNING.KEI_SPIDERQUEEN_WEB_RADIUS or 6)
    end
end

local function RemoveWebFx(slots)
    if slots._kei_spider_queen_web_fx ~= nil then
        if slots._kei_spider_queen_web_fx:IsValid() then
            slots._kei_spider_queen_web_fx:Remove()
        end
        slots._kei_spider_queen_web_fx = nil
    end
end

local function ApplySlow(slots, inst, target)
    if slots._kei_spider_queen_slowed[target] ~= nil then
        return
    end

    local slow = TUNING.KEI_SPIDERQUEEN_WEB_SLOW or 0.5
    if not SlowSources.TryApply(target, SPIDER_QUEEN_WEB_KEY, inst, slow) then
        return
    end

    local data = {}
    data.onremove = function()
        slots._kei_spider_queen_slowed[target] = nil
    end
    inst:ListenForEvent("onremove", data.onremove, target)
    slots._kei_spider_queen_slowed[target] = data

end

local function ClearSlow(slots, inst, target)
    local data = slots._kei_spider_queen_slowed[target]
    if data == nil then
        return
    end

    slots._kei_spider_queen_slowed[target] = nil
    inst:RemoveEventCallback("onremove", data.onremove, target)

    SlowSources.Release(target, SPIDER_QUEEN_WEB_KEY, inst)
end

local function ClearAllSlows(slots, inst)
    local targets = {}
    for target in pairs(slots._kei_spider_queen_slowed or {}) do
        table.insert(targets, target)
    end
    for _, target in ipairs(targets) do
        ClearSlow(slots, inst, target)
    end
end

local function ScanWeb(slots, inst)
    local fx = slots._kei_spider_queen_web_fx
    if fx == nil or not fx:IsValid() then
        slots._kei_spider_queen_web_fx = nil
        SpawnWebFx(slots, inst)
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    local radius = TUNING.KEI_SPIDERQUEEN_WEB_RADIUS or 6
    local in_range = {}
    for _, target in ipairs(TheSim:FindEntities(x, y, z, radius,
        SPIDER_QUEEN_MUST_TAGS, SPIDER_QUEEN_EXCLUDE_TAGS)) do
        if IsValidTarget(inst, target) then
            in_range[target] = true
            ApplySlow(slots, inst, target)
        end
    end
    for target in pairs(slots._kei_spider_queen_slowed or {}) do
        if not in_range[target] then
            ClearSlow(slots, inst, target)
        end
    end
end

function SpiderQueenEffect.Enable(slots, inst)
    EnableSpiderDisguise(slots, inst)
    slots._kei_spider_queen_slowed = slots._kei_spider_queen_slowed or {}
    SpawnWebFx(slots, inst)
    SyncWebFxScale(slots, inst)

    if slots._kei_spider_queen_task == nil then
        slots._kei_spider_queen_task = inst:DoPeriodicTask(
            TUNING.KEI_SPIDERQUEEN_WEB_SCAN_PERIOD or 0.25,
            function() ScanWeb(slots, inst) end)
    end
end

function SpiderQueenEffect.Disable(slots, inst)
    if slots._kei_spider_queen_task ~= nil then
        slots._kei_spider_queen_task:Cancel()
        slots._kei_spider_queen_task = nil
    end
    if slots._kei_spider_queen_follow_task ~= nil then
        slots._kei_spider_queen_follow_task:Cancel()
        slots._kei_spider_queen_follow_task = nil
    end
    RemoveWebFx(slots)
    if not KeiEffectManager.Remove(inst, "spiderqueen_web", "protocol_disable") then
        slots._kei_spider_queen_web_fx = nil
    end
    ClearAllSlows(slots, inst)
    DisableSpiderDisguise(slots, inst)
end

return SpiderQueenEffect
