require("bufferedaction")
local DeerclopsCommon = require("kei/protocols/combat/effects/beast/_deerclops_common")
local DragonflyCommon = require("kei/protocols/combat/effects/beast/_dragonfly_common")
local old_BufferedAction_Do = BufferedAction.Do

local function HasKeiDeerclopsFreezeImmunity(inst)
    local slots = inst ~= nil
        and inst.components ~= nil
        and inst.components.kei_protocolslots
        or nil
    if slots ~= nil and slots.HasFreezeImmunity ~= nil then
        return slots:HasFreezeImmunity()
    end
    return DeerclopsCommon.HasFreezeImmunity(slots)
end

local function HasKeiDragonflyOverheatImmunity(inst)
    local slots = inst ~= nil
        and inst.components ~= nil
        and inst.components.kei_protocolslots
        or nil
    if slots ~= nil and slots.HasOverheatImmunity ~= nil then
        return slots:HasOverheatImmunity()
    end
    return DragonflyCommon.HasOverheatImmunity(slots)
end

function BufferedAction:Do(...)
    if self.target ~= nil
        and self.invobject ~= nil
        and self.target:HasTag("kei_virtual_equipment")
    then
        self:Fail()
        return false
    end

    if self.doer ~= nil
        and self.doer:HasTag("kei_dormant")
        and self.action ~= ACTIONS.KEI_WAKE
    then
        self:Fail()
        return false, "KEI_DORMANT"
    end

    return old_BufferedAction_Do(self, ...)
end

AddComponentPostInit("temperature", function(self)
    local old_SetTemperature = self.SetTemperature
    local old_DoDelta = self.DoDelta
    local old_GetInsulation = self.GetInsulation

    -- Temperature:GetInsulation() 原版只遍历 inventory.equipslots。解析的
    -- 蓝晶帽仍保留 insulator 组件，但由 Kei 私有协议槽持有，因此需要把
    -- 其保温值补入原版结果。
    function self:GetInsulation(...)
        local winter_insulation, summer_insulation = old_GetInsulation(self, ...)
        local slots = self.inst.components ~= nil
            and self.inst.components.kei_protocolslots
            or nil
        if slots == nil or slots.ForEachVirtualEquipment == nil then
            return winter_insulation, summer_insulation
        end

        slots:ForEachVirtualEquipment(function(item)
            local insulator = item.components ~= nil and item.components.insulator or nil
            if insulator ~= nil and insulator.GetInsulation ~= nil then
                local value, insulation_type = insulator:GetInsulation()
                value = math.max(0, tonumber(value) or 0)
                if insulation_type == SEASONS.WINTER then
                    winter_insulation = winter_insulation + value
                elseif insulation_type == SEASONS.SUMMER then
                    summer_insulation = summer_insulation + value
                end
            end
        end)

        return math.max(0, winter_insulation), math.max(0, summer_insulation)
    end

    function self:SetTemperature(value, ...)
        if type(value) == "number" and HasKeiDragonflyOverheatImmunity(self.inst) then
            value = math.min(value, TUNING.KEI_DRAGONFLY_MAX_TEMPERATURE)
        end
        if type(value) == "number" and HasKeiDeerclopsFreezeImmunity(self.inst) then
            local safe_temperature = DeerclopsCommon.GetSafeTemperature(self.inst)
            if safe_temperature ~= nil then
                value = math.max(value, safe_temperature)
            end
        end

        return old_SetTemperature(self, value, ...)
    end

    -- DoDelta normally delegates to SetTemperature, but keeping the guard at
    -- this entry point also covers mods which replace or cache SetTemperature.
    function self:DoDelta(delta, ...)
        if type(delta) == "number" and HasKeiDeerclopsFreezeImmunity(self.inst) then
            local safe_temperature = DeerclopsCommon.GetSafeTemperature(self.inst)
            if safe_temperature ~= nil then
                local current = self:GetCurrent()
                if current + delta < safe_temperature then
                    delta = safe_temperature - current
                end
            end
        end
        return old_DoDelta(self, delta, ...)
    end
end)

-- Keep the vanilla freezable component intact and block only the Freeze call
-- while the Deerclops protocol still provides freeze immunity.
AddComponentPostInit("freezable", function(self)
    local old_Freeze = self.Freeze
    local old_AddColdness = self.AddColdness

    function self:Freeze(...)
        if HasKeiDeerclopsFreezeImmunity(self.inst) then
            -- A direct Freeze call does not pass through AddColdness. Clear any
            -- residual coldness as well, otherwise the frozen tint can remain
            -- even though the actual freeze was blocked.
            self.coldness = 0
            if self.UpdateTint ~= nil then
                self:UpdateTint()
            end
            return
        end
        if old_Freeze ~= nil then
            return old_Freeze(self, ...)
        end
    end

    function self:AddColdness(coldness, ...)
        if HasKeiDeerclopsFreezeImmunity(self.inst) then
            self.coldness = 0
            if self.UpdateTint ~= nil then
                self:UpdateTint()
            end
            return
        end
        if old_AddColdness ~= nil then
            return old_AddColdness(self, coldness, ...)
        end
    end
end)
