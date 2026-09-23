-- 旋翼调查仪复用 WX-78 旋翼测绘机的地图选中、航线和 mapdeliverable 流程。

local function IsKeiSurveyor(drone, doer)
    if drone == nil
        or not drone:IsValid()
        or not drone:HasTag("kei_rotor_surveyor")
        or doer == nil
        or doer.userid == nil
    then
        return false
    end

    local userid = drone._kei_drone_owner_userid
    if drone._kei_drone_owner_userid_net ~= nil then
        userid = drone._kei_drone_owner_userid_net:value()
    end
    return userid ~= nil and userid ~= "" and userid == doer.userid
end

local function IsMapControllableSurveyor(drone)
    if drone == nil or not drone:IsValid() or drone.sg == nil then
        return false
    end
    local state = drone.sg.currentstate
    return state ~= nil and state.name == "flight"
end

local function GetSurveyorFromMapIcon(mapent)
    if mapent ~= nil and mapent:HasTag("globalmapicon") then
        return mapent._target
    end
    return mapent
end

local old_select_check = ACTIONS.MAPSCOUTSELECT_MAP.maponly_checkvalidpos_fn
local old_move_check = ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn

-- 右键无人机的原版地图图标，进入原版的 SetNewMapTarget 选点模式。
ACTIONS.MAPSCOUTSELECT_MAP.maponly_checkvalidpos_fn = function(act)
    if act ~= nil and act.doer ~= nil and act.doer:HasTag("kei") then
        local act_pos = act:GetActionPoint()
        if act_pos == nil then
            return false
        end

        local x, y, z = act_pos:Get()
        local mapent = FindClosestMapIconInRange(
            "kei_rotor_surveyor",
            x,
            y,
            z,
            TUNING.KEI_ROTOR_MAP_SELECT_DETECTION_RADIUS or 10,
            act.doer
        )
        -- FindClosestMapIconInRange 使用自定义登记名时只会返回 Kei 的
        -- global icon；航程方法再作为第二层类型校验，避免误选其他图标。
        if mapent == nil or mapent.GetDroneRange == nil then
            return false, "NOTARGET"
        end
        local drone = GetSurveyorFromMapIcon(mapent)
        if drone ~= nil
            and (not IsKeiSurveyor(drone, act.doer)
                or not IsMapControllableSurveyor(drone))
        then
            return false, "NOTARGET"
        end
        return true, nil, x, z, mapent
    end

    return old_select_check(act)
end

-- 选中无人机后，复用原版地图界面的目标状态，而不是只改变合法性检查。
ACTIONS.MAPSCOUTSELECT_MAP.pre_action_cb = function(act)
    if act ~= nil and act.doer ~= nil
        and act.doer.HUD ~= nil
        and act.doer.HUD:IsMapScreenOpen()
    then
        local valid, _, _, _, mapent = ACTIONS.MAPSCOUTSELECT_MAP.maponly_checkvalidpos_fn(act)
        if valid then
            local mapscreen = TheFrontEnd:GetActiveScreen()
            if mapscreen ~= nil then
                mapscreen:SetNewMapTarget(mapent, ACTIONS.MAPSCOUT_MAP)
            end
        end
    end
end

ACTIONS.MAPSCOUTSELECT_MAP.fn = function(act)
    return true
end

-- 选中后的左键沿用原版距离限制和 MAPSCOUT_MAP 的视觉航线。
ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn = function(act)
    if act ~= nil and act.doer ~= nil and act.doer:HasTag("kei") then
        local mapent = act.target
        local drone = GetSurveyorFromMapIcon(mapent)
        if mapent == nil
            or mapent.GetDroneRange == nil
            or (drone ~= nil
                and (not IsKeiSurveyor(drone, act.doer)
                    or not IsMapControllableSurveyor(drone)))
        then
            return false
        end

        local act_pos = act:GetActionPoint()
        if act_pos == nil then
            return false
        end

        local x, _, z = act_pos:Get()
        local x1, _, z1 = act.doer.Transform:GetWorldPosition()
        local range = mapent:GetDroneRange(act.doer)
        local dx, dz = x - x1, z - z1
        local distance = math.sqrt(dx * dx + dz * dz)
        local limited_distance = math.min(distance, range)
        if distance > 0 then
            dx, dz = dx / distance, dz / distance
        end
        return true, nil, dx * limited_distance + x1, dz * limited_distance + z1, mapent
    end

    return old_move_check(act)
end

ACTIONS.MAPSCOUT_MAP_TOOFAR.maponly_checkvalidpos_fn = ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn

-- 发送航向前清理地图的选中状态，并将目标点交给 mapdeliverable。
ACTIONS.MAPSCOUT_MAP.pre_action_cb = function(act)
    if act ~= nil and act.doer ~= nil
        and act.doer.HUD ~= nil
        and act.doer.HUD:IsMapScreenOpen()
    then
        local mapscreen = TheFrontEnd:GetActiveScreen()
        if mapscreen ~= nil then
            mapscreen:SetNewMapTarget(nil, nil)
        end
    end
end

ACTIONS.MAPSCOUT_MAP.fn = function(act)
    local valid, reason, act_posx, act_posz, mapent =
        ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn(act)
    if not valid then
        return valid, reason
    end

    local target = mapent
    if target ~= nil and target:HasTag("globalmapicon") then
        target = target._target
    end

    if target ~= nil and target.components ~= nil
        and target.components.mapdeliverable ~= nil
    then
        target.components.mapdeliverable:Stop()
        return target.components.mapdeliverable:SendToPoint(
            Vector3(act_posx, 0, act_posz),
            act.doer
        )
    end

    return false
end
