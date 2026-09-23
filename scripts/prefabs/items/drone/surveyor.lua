-- Kei 专属旋翼调查仪：旋翼测绘机的独立副本。

local easing = require("easing")
local RotorSurveyRegistry = require("kei/drone/registry")
local RotorUpgrades = require("kei/drone/upgrades")
local DroneAnimation = require("kei/drone/animation")

local assets =
{
    Asset("ANIM", "anim/kei_drone.zip"),
    Asset("ANIM", "anim/wx78_map_marker.zip"),
    Asset("ANIM", "anim/kei_halo_350.zip"),
}

local prefabs =
{
    "kei_rotor_surveyor_globalicon",
    "kei_rotor_surveyor_revealableicon",
}

-- Keep the decision cadence aligned with vanilla pet brains. Movement remains
-- frame-based only while the flying drone actually has ground to make up.
local FOLLOW_DECISION_PERIOD = .25
local FOLLOW_MOVE_PERIOD = FRAMES
local FOLLOW_DISTANCE = 3
local PILOT_INPUT_TIMEOUT = 0.75

local function GetDroneSide(inst, previous)
    return DroneAnimation.GetSide(inst, previous)
end

local function PlayDroneAnimation(inst, prefix, loop, side)
    return DroneAnimation.Play(inst, prefix, loop, side)
end

local function CreateDecal(skin_build, side)
    local inst = CreateEntity()

    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    inst.entity:SetCanSleep(TheWorld.ismastersim)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.AnimState:SetBank("kei_drone")
    inst.AnimState:SetBuild("kei_drone")
    inst._kei_drone_animation = true
    PlayDroneAnimation(inst, "idle_ground", true, side)
    inst.AnimState:SetLightOverride(0.15)
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)
    inst.AnimState:SetScale(4, 4)

    return inst
end

local function BeamPostUpdate(inst)
    local x, _, z = inst.Transform:GetWorldPosition()
    inst.decal.Transform:SetPosition(x, 0, z)

    local parent = inst.entity:GetParent()
    if parent ~= nil and parent:IsValid() then
        local side = GetDroneSide(parent, inst._kei_drone_side)
        if side ~= inst._kei_drone_side then
            inst._kei_drone_side = side
            PlayDroneAnimation(inst, "guang_loop", true, side)
            if inst.decal._kei_drone_animation then
                PlayDroneAnimation(inst.decal, "idle_ground", true, side)
            end
        end
    end
end

local function BeamOnRemoveEntity(inst)
    inst.decal:Remove()
end

local function CreateBeam(skin_build, side)
    local inst = CreateEntity()

    inst:AddTag("DECOR")
    inst:AddTag("NOCLICK")
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.AnimState:SetBank("kei_drone")
    inst.AnimState:SetBuild("kei_drone")
    inst._kei_drone_animation = true
    PlayDroneAnimation(inst, "guang_loop", true, side)
    inst.AnimState:SetFinalOffset(-1)
    inst.AnimState:SetLightOverride(0.15)

    inst.decal = CreateDecal(skin_build, side)
    inst._kei_drone_side = side

    inst:AddComponent("updatelooper")
    inst.components.updatelooper:AddPostUpdateFn(BeamPostUpdate)
    inst.OnRemoveEntity = BeamOnRemoveEntity

    return inst
end

local function OnScanningDirty(inst)
    if inst.scanning:value() then
        if inst.beam == nil then
            inst.beam = CreateBeam(inst.build:value(), GetDroneSide(inst))
            inst.beam.entity:SetParent(inst.entity)
        end
    elseif inst.beam ~= nil then
        inst.beam:Remove()
        inst.beam = nil
    end
end

local function CreateHaloPart(animation, onground, side)
    local inst = CreateEntity()

    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst._kei_drone_animation = not onground
    local animation_name = animation
    if onground then
        inst.AnimState:SetBank("kei_halo_350")
        inst.AnimState:SetBuild("kei_halo_350")
    else
        -- The new drone build supplies the shared airborne beam animation.
        -- Skill-specific ground halos remain on kei_halo_350 for now.
        inst.AnimState:SetBank("kei_drone")
        inst.AnimState:SetBuild("kei_drone")
        animation_name = "guang_loop_" .. (side or "upside")
    end
    inst.AnimState:PlayAnimation(animation_name, true)
    inst.AnimState:SetLightOverride(0.15)

    if onground then
        inst.AnimState:SetMultColour(1, 1, 1, 0.5)
        inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
        inst.AnimState:SetLayer(LAYER_BACKGROUND)
        inst.AnimState:SetSortOrder(3)
        inst.Transform:SetScale(2.5, 2.5, 2.5)
    else
        inst.AnimState:SetFinalOffset(-1)
    end

    return inst
end

local function HaloPostUpdate(inst)
    local x, _, z = inst.Transform:GetWorldPosition()
    inst.decal.Transform:SetPosition(x, 0, z)

    local parent = inst.entity:GetParent()
    if parent ~= nil and parent:IsValid() and inst.beam ~= nil then
        local side = GetDroneSide(parent, inst._kei_drone_side)
        if side ~= inst._kei_drone_side then
            inst._kei_drone_side = side
            PlayDroneAnimation(inst.beam, "guang_loop", true, side)
        end
    end
end

local function HaloOnRemoveEntity(inst)
    if inst.decal ~= nil and inst.decal:IsValid() then
        inst.decal:Remove()
    end
end

local function CreateHaloBeam(animation)
    local inst = CreateEntity()

    inst:AddTag("DECOR")
    inst:AddTag("NOCLICK")
    inst.persists = false

    inst.entity:AddTransform()
    inst.beam = CreateHaloPart(animation, false, "upside")
    inst.beam.entity:SetParent(inst.entity)
    inst.decal = CreateHaloPart(animation, true)
    inst._kei_drone_side = "upside"

    inst:AddComponent("updatelooper")
    inst.components.updatelooper:AddPostUpdateFn(HaloPostUpdate)
    inst.OnRemoveEntity = HaloOnRemoveEntity

    return inst
end

local function RemoveSkillBeam(inst)
    if inst.skill_beam ~= nil then
        if inst.skill_beam:IsValid() then
            inst.skill_beam:Remove()
        end
        inst.skill_beam = nil
    end
end

local function StartStrengthenGroundFlicker(inst)
    local elapsed = 0
    local period = 0.8

    inst._kei_ground_flicker_task = inst:DoPeriodicTask(FRAMES, function(fx)
        if fx.decal == nil or not fx.decal:IsValid() then
            return
        end

        elapsed = (elapsed + FRAMES) % period
        local alpha = 0.15 + 0.55 * (0.5 + 0.5 * math.sin(elapsed / period * 2 * PI))
        fx.decal.AnimState:SetMultColour(1, 1, 1, alpha)
    end)

    local old_on_remove = inst.OnRemoveEntity
    inst.OnRemoveEntity = function(fx)
        if fx._kei_ground_flicker_task ~= nil then
            fx._kei_ground_flicker_task:Cancel()
            fx._kei_ground_flicker_task = nil
        end
        old_on_remove(fx)
    end
end

local function CreateSkillBeam(inst, beam_name)
    if beam_name == "survey" then
        return CreateBeam(0, GetDroneSide(inst))
    end

    if beam_name == "collect" then
        local beam = CreateBeam(0, GetDroneSide(inst))
        if beam.decal ~= nil and beam.decal:IsValid() then
            beam.decal:Remove()
        end
        beam.decal = CreateHaloPart("kei_halo_collect", true)
        return beam
    end

    if beam_name == "resurrection"
        or beam_name == "heal"
        or beam_name == "strengthen"
        or beam_name == "confinement"
        or beam_name == "dead"
        or beam_name == "teleport"
        or beam_name == "collect"
        or beam_name == "fishing"
        or beam_name == "nature"
        or beam_name == "friendly"
    then
        -- 光束沿用旋翼测绘机的投影动画，地面纹理使用新的光环动画。
        local beam = CreateBeam(0, GetDroneSide(inst))
        if beam.decal ~= nil and beam.decal:IsValid() then
            beam.decal:Remove()
        end
        local ground_animation
        if beam_name == "teleport" then
            ground_animation = "kei_halo_transmit"
        elseif beam_name == "friendly" then
            ground_animation = "kei_halo_friendly"
        else
            ground_animation = "kei_halo_" .. beam_name
        end
        beam.decal = CreateHaloPart(ground_animation, true)
        if beam_name == "strengthen" then
            StartStrengthenGroundFlicker(beam)
        end
        return beam
    end
end

local function OnSkillBeamDirty(inst)
    RemoveSkillBeam(inst)

    local beam_name = inst.skill_beam_name:value()
    if beam_name == nil or beam_name == "" then
        return
    end

    inst.skill_beam = CreateSkillBeam(inst, beam_name)
    if inst.skill_beam ~= nil then
        inst.skill_beam.entity:SetParent(inst.entity)
    end
end

local function SetSkillBeam(inst, beam_name)
    beam_name = beam_name or ""
    inst.skill_beam_name:set(beam_name)
    if not TheNet:IsDedicated() then
        OnSkillBeamDirty(inst)
    end
end

local function GetSkillBeam(inst)
    local beam_name = inst.skill_beam_name:value()
    return beam_name ~= "" and beam_name or nil
end

local function SetScanning(inst, scanning)
    inst.scanning:set(scanning)
    if not TheNet:IsDedicated() then
        OnScanningDirty(inst)
    end
end

local function CalcDeliveryTime(inst, dest, doer)
    local x, _, z = inst.Transform:GetWorldPosition()
    local dist = math.sqrt(math2d.DistSq(x, z, dest.x, dest.z))
    local speed = RotorUpgrades.GetDroneSpeed(inst._kei_drone_owner)
    local accel_and_decel_dist = speed
    return dist <= accel_and_decel_dist and 2 or 2 + (dist - accel_and_decel_dist) / speed
end

local function OnStartDelivery(inst, dest, doer)
    local _
    inst._x, _, inst._z = inst.Transform:GetWorldPosition()
    if dest.x ~= inst._x or dest.z ~= inst._z then
        DroneAnimation.SetFacingRotation(
            inst,
            math.atan2(inst._z - dest.z, dest.x - inst._x) / DEGREES
        )
        SetScanning(inst, true)
    end
    return true
end

local function CalcProgress(t, length, dx, dz, speed)
    if length <= 2 then
        return easing.inOutQuad(t, 0, 1, length)
    end

    local distance = math.sqrt(dx * dx + dz * dz)
    local accel_and_decel_dist = speed or RotorUpgrades.GetDroneSpeed(nil)
    local accel_part = accel_and_decel_dist / 2 / distance
    if t <= 1 then
        return easing.inQuad(t, 0, accel_part, 1)
    elseif t < length - 1 then
        return easing.linear(t - 1, accel_part, 1 - 2 * accel_part, length - 2)
    end
    return easing.outQuad(t - length + 1, 1 - accel_part, accel_part, 1)
end

local function OnDeliveryProgress(inst, t, length, origin, dest)
    local dx = dest.x - origin.x
    local dz = dest.z - origin.z
    local speed = RotorUpgrades.GetDroneSpeed(inst._kei_drone_owner)
    local k = CalcProgress(t, length, dx, dz, speed)
    local k1 = math.min(1, CalcProgress(t + FRAMES, length, dx, dz, speed))

    local x, y, z = inst.Transform:GetWorldPosition()
    x = origin.x + k * dx
    z = origin.z + k * dz
    inst.Transform:SetPosition(x, y, z)

    local _, vy, _ = inst.Physics:GetMotorVel()
    if k1 > k then
        local speed = (k1 - k) * math.sqrt(dx * dx + dz * dz) * 30
        local direction = math.atan2(-dz, dx) / DEGREES
        local relative_angle = (direction - inst.Transform:GetRotation()) * DEGREES
        inst.Physics:SetMotorVel(
            speed * math.cos(relative_angle),
            vy,
            -speed * math.sin(relative_angle)
        )
    else
        inst.Physics:SetMotorVel(0, vy, 0)
    end

    local is_scanning = inst.scanning:value()
    if IsFlyingPermittedFromPoint(x, y, z) then
        if not is_scanning then
            SetScanning(inst, true)
            inst:Show()
            if not (inst.SoundEmitter:PlayingSound("idle") or inst:IsAsleep()) then
                inst.SoundEmitter:PlaySound("rifts5/wagdrone_flying/idle", "idle")
            end
        end

        local owner = inst.components.globaltrackingicon.owner
        if owner ~= nil and owner.player_classified ~= nil then
            if owner._PostActivateHandshakeState_Server ~= POSTACTIVATEHANDSHAKE.READY then
                return
            end
            if math2d.DistSq(x, z, inst._x, inst._z) >= 16 then
                inst._x, inst._z = x, z
                owner.player_classified.MapExplorer:RevealArea(x, 0, z)
                inst.components.maprevealer:RestartPrivateRevealCooldown()
            end
        end
    elseif is_scanning then
        SetScanning(inst, false)
        -- The drone is now a persistent takeoff/landing entity. Do not hide
        -- it when a map-delivery route leaves the permitted scan area; the
        -- stategraph owns visibility for the drone itself.
        inst.SoundEmitter:KillSound("idle")
    end
end

local function OnStopDelivery(inst, dest)
    inst._x, inst._z = nil, nil
    local _, vy, _ = inst.Physics:GetMotorVel()
    inst.Physics:SetMotorVel(0, vy, 0)
    SetScanning(inst, false)
end

local function OnTracked(inst, tracker)
    inst.persists = false
    inst.components.globaltrackingicon:StartTracking(tracker, "kei_rotor_surveyor")
    inst.components.maprevealer:SetPrivateOwner(tracker)
    if inst.sg:HasStateTag("idle") then
        inst.components.spawnfader:FadeIn()
    end
end

local function OnUntracked(inst, tracker)
    inst.persists = false
    inst.components.globaltrackingicon:StopTracking()
    inst.components.maprevealer:SetPrivateOwner(inst)
end

local function OnTrackerDespawn(inst, tracker)
    inst.components.spawnfader:FadeOut()
    inst:ListenForEvent("spawnfaderout", inst.Remove)
end

local function OnEntityWake(inst)
    if not inst.SoundEmitter:PlayingSound("idle") then
        inst.SoundEmitter:PlaySound("rifts5/wagdrone_flying/idle", "idle")
    end
end

local function OnEntitySleep(inst)
    inst.SoundEmitter:KillSound("idle")
end

local function OnBuildDirty(inst)
    if inst.beam ~= nil then
        if inst.build:value() == 0 then
            inst.beam.AnimState:SetBuild("kei_drone")
            inst.beam.decal.AnimState:SetBuild("kei_drone")
        else
            inst.beam.AnimState:SetBuild("kei_drone")
            inst.beam.decal.AnimState:SetBuild("kei_drone")
        end
    end
end

local function OnDroneRemoved(inst)
    local follow_controller = inst._kei_drone_controller
    if follow_controller ~= nil
        and follow_controller:IsValid()
        and follow_controller.StopDroneFollow ~= nil
    then
        follow_controller:StopDroneFollow(inst._kei_drone_owner)
    end
    if inst.StopFollowing ~= nil then
        inst:StopFollowing()
    end
    local beam_controller = inst._kei_rotor_beam_controller
    if beam_controller ~= nil
        and beam_controller:IsValid()
        and beam_controller.components ~= nil
        and beam_controller.components["drone/beam"] ~= nil
    then
        beam_controller.components["drone/beam"]:Stop()
    end
    RemoveSkillBeam(inst)
    local pilot = inst._kei_drone_pilot
    if pilot ~= nil and pilot:IsValid() and pilot.sg ~= nil then
        pilot._kei_rotor_pilot_drone = nil
        pilot.sg:GoToState("kei_rotor_drone_pilot_stop", true)
    end
    RotorSurveyRegistry.Unregister(inst)
end

local function RecallForOwner(inst, owner)
    local controller = inst._kei_drone_controller
    if controller == nil
        or not controller:IsValid()
        or controller.RecallBoundDrone == nil
    then
        return false
    end
    return controller:RecallBoundDrone(owner)
end

local function StopFollowMovement(inst)
    if inst._kei_rotor_follow_move_task ~= nil then
        inst._kei_rotor_follow_move_task:Cancel()
        inst._kei_rotor_follow_move_task = nil
    end

    inst:StopRotorMovement()
end

local function GetFollowOwner(inst)
    local follower = inst.components.follower
    return follower ~= nil and follower:GetLeader() or nil
end

local function UpdateFollowMotion(inst)
    local owner = GetFollowOwner(inst)
    if owner == nil or not owner:IsValid() or owner:HasTag("playerghost") then
        StopFollowMovement(inst)
        return
    end

    if inst._kei_drone_pilot ~= nil then
        StopFollowMovement(inst)
        return
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    local ox, _, oz = owner.Transform:GetWorldPosition()
    local dx, dz = ox - x, oz - z
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance <= FOLLOW_DISTANCE then
        StopFollowMovement(inst)
        return
    end

    local speed = RotorUpgrades.GetDroneSpeed(owner)
    local step = math.min(distance - FOLLOW_DISTANCE, speed * FOLLOW_MOVE_PERIOD)
    local next_x = x + dx / distance * step
    local next_z = z + dz / distance * step

    -- Flying drones intentionally move in world space: unlike ground pets,
    -- they do not need locomotor pathfinding or obstacle avoidance.
    DroneAnimation.SetFacingRotation(inst, math.atan2(-dz, dx) / DEGREES)
    inst.Transform:SetPosition(next_x, y, next_z)
    if inst.Physics ~= nil then
        local _, vy, _ = inst.Physics:GetMotorVel()
        inst.Physics:SetMotorVel(0, vy, 0)
    end
end

local function StartFollowMovement(inst)
    if inst._kei_rotor_follow_move_task == nil then
        inst._kei_rotor_follow_move_task = inst:DoPeriodicTask(FOLLOW_MOVE_PERIOD, UpdateFollowMotion)
    end
    UpdateFollowMotion(inst)
end

local function UpdateFollow(inst)
    local owner = GetFollowOwner(inst)
    if owner == nil or not owner:IsValid() or owner:HasTag("playerghost") then
        local controller = inst._kei_drone_controller
        if controller ~= nil
            and controller:IsValid()
            and controller.StopDroneFollow ~= nil
        then
            controller:StopDroneFollow(owner)
        elseif inst.StopFollowing ~= nil then
            inst:StopFollowing()
        end
        return
    end

    if inst._kei_drone_pilot ~= nil then
        StopFollowMovement(inst)
        return
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    local ox, _, oz = owner.Transform:GetWorldPosition()
    local dx, dz = ox - x, oz - z
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance <= FOLLOW_DISTANCE then
        StopFollowMovement(inst)
        return
    end

    StartFollowMovement(inst)
end

local function StartFollowing(inst, owner)
    if TheWorld == nil or not TheWorld.ismastersim or inst == nil or owner == nil then
        return false
    end

    if inst._kei_drone_pilot ~= nil then
        return false
    end

    inst._kei_rotor_follow_owner = owner
    if inst.components.follower ~= nil then
        inst.components.follower:SetLeader(owner)
    end
    if inst._kei_rotor_follow_task == nil then
        inst._kei_rotor_follow_task = inst:DoPeriodicTask(FOLLOW_DECISION_PERIOD, UpdateFollow)
    end
    UpdateFollow(inst)
    return true
end

local function StopFollowing(inst)
    if inst == nil then
        return
    end

    local x, y, z = inst.Transform:GetWorldPosition()

    if inst._kei_rotor_follow_task ~= nil then
        inst._kei_rotor_follow_task:Cancel()
        inst._kei_rotor_follow_task = nil
    end
    StopFollowMovement(inst)
    inst._kei_rotor_follow_owner = nil
    if inst.components.follower ~= nil then
        inst.components.follower:SetLeader(nil)
    end
    inst.entity:SetParent(nil)
    inst.Transform:SetPosition(x, y, z)

end

local function OnPilotLocomote(inst, data)
    if TheWorld == nil or not TheWorld.ismastersim then
        return
    end

    local dir = data ~= nil and data.dir or nil
    if dir == nil then
        inst._kei_rotor_auto_drive = false
        inst._kei_rotor_move_deadline = nil
        local _, vy, _ = inst.Physics:GetMotorVel()
        inst.Physics:SetMotorVel(0, vy, 0)
        return
    end

    local speed = RotorUpgrades.GetDroneSpeed(inst._kei_drone_owner)
    inst._kei_rotor_auto_drive = data ~= nil and data.auto_drive == true
    if inst._kei_rotor_auto_drive then
        inst._kei_rotor_move_deadline = nil
    else
        -- 普通控制需要客户端持续发送心跳。客户端存在其他高负载逻辑时，
        -- 允许短暂延迟，避免无人机因一次丢帧而提前停止；明确的空输入仍
        -- 会在上面的分支立即停止。
        inst._kei_rotor_move_deadline = GetTime()
            + (tonumber(TUNING.KEI_ROTOR_PILOT_INPUT_TIMEOUT) or PILOT_INPUT_TIMEOUT)
    end
    -- dir 与 fishing 的 RunInDirection 参数一致，单位为角度；只有三角
    -- 函数计算边界方向时才转换为弧度。
    local angle = dir * DEGREES
    local owner = inst._kei_drone_pilot
    if owner ~= nil and owner:IsValid() then
        local ox, _, oz = owner.Transform:GetWorldPosition()
        local x, y, z = inst.Transform:GetWorldPosition()
        local dx, dz = x - ox, z - oz
        local distance = math.sqrt(dx * dx + dz * dz)
        local range = RotorUpgrades.GetControlRange(owner)
        if distance >= range then
            local outward = dx * math.cos(angle) - dz * math.sin(angle)
            if outward > 0 then
                local _, vy, _ = inst.Physics:GetMotorVel()
                inst.Physics:SetMotorVel(0, vy, 0)
                return
            end
        end
    end

    local facing_rotation = DroneAnimation.SetFacingRotation(inst, dir)
    local _, vy, _ = inst.Physics:GetMotorVel()
    local relative_angle = (dir - facing_rotation) * DEGREES
    inst.Physics:SetMotorVel(
        speed * math.cos(relative_angle),
        vy,
        -speed * math.sin(relative_angle)
    )
end

local function StopRotorMovement(inst)
    if TheWorld == nil or not TheWorld.ismastersim or inst == nil or not inst:IsValid() then
        return
    end

    inst._kei_rotor_auto_drive = false
    inst._kei_rotor_move_deadline = nil
    if inst.Physics ~= nil then
        local _, vy, _ = inst.Physics:GetMotorVel()
        inst.Physics:SetMotorVel(0, vy, 0)
    end
end

local function OnPilotMoveWatchdog(inst)
    if inst._kei_drone_pilot == nil
        or inst._kei_rotor_auto_drive
        or inst._kei_rotor_move_deadline == nil
        or GetTime() <= inst._kei_rotor_move_deadline
    then
        return
    end

    inst._kei_rotor_move_deadline = nil
    local _, vy, _ = inst.Physics:GetMotorVel()
    inst.Physics:SetMotorVel(0, vy, 0)
end

local function OnSurveyorSkinChanged(inst, skin_build)
    inst.build:set(skin_build or 0)
    OnBuildDirty(inst)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()
    inst.Transform:SetEightFaced()
    DroneAnimation.SetFacingRotation(inst, 0)
    -- 驾驶时无人机必须在远离角色后继续运行并保持可同步，不能进入实体休眠。
    inst.entity:SetCanSleep(false)

    MakeFlyingCharacterPhysics(inst, 50, 0.4)
    inst.Physics:SetCollisionMask(COLLISION.GROUND)

    inst.AnimState:SetBank("kei_drone")
    inst.AnimState:SetBuild("kei_drone")
    PlayDroneAnimation(inst, "idle_ground", true, GetDroneSide(inst))

    inst:AddTag("flying")
    inst:AddTag("mapscout")
    inst:AddTag("kei_rotor_surveyor")
    inst:AddTag("staysthroughvirtualrooms")

    inst.scanning = net_bool(inst.GUID, "kei_rotor_surveyor.scanning", "scanningdirty")
    inst.build = net_hash(inst.GUID, "kei_rotor_surveyor.build", "builddirty")
    inst.skill_beam_name = net_string(inst.GUID, "kei_rotor_surveyor.skill_beam", "skillbeamdirty")
    inst._kei_drone_owner_userid_net = net_string(inst.GUID, "kei_rotor_surveyor.owner_userid")
    inst:AddComponent("spawnfader")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        inst:ListenForEvent("scanningdirty", OnScanningDirty)
        inst:ListenForEvent("builddirty", OnBuildDirty)
        inst:ListenForEvent("skillbeamdirty", OnSkillBeamDirty)
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("mapdeliverable")
    inst.components.mapdeliverable:SetDeliveryTimeFn(CalcDeliveryTime)
    inst.components.mapdeliverable:SetOnStartDeliveryFn(OnStartDelivery)
    inst.components.mapdeliverable:SetOnDeliveryProgressFn(OnDeliveryProgress)
    inst.components.mapdeliverable:SetOnStopDeliveryFn(OnStopDelivery)

    inst:AddComponent("globaltrackingicon")
    -- 使用自定义图标登记名；图标贴图仍由 icondata 复用 WX-78 资源。
    -- 无人机只有被控制器召唤后才有所有者，此处不创建无主图标。

    inst:AddComponent("maprevealer")
    inst.components.maprevealer:SetPrivateOwner(inst)

    -- Use vanilla follower ownership and cleanup, but disable its ground-pet
    -- leashing behaviour because this drone deliberately flies in straight lines.
    inst:AddComponent("follower")
    inst.components.follower:DisableLeashing()

    inst:SetStateGraph("SGkei_rotor_surveyor")

    inst:ListenForEvent("onremove", OnDroneRemoved)
    inst:ListenForEvent("locomote", OnPilotLocomote)
    inst:DoPeriodicTask(FRAMES, OnPilotMoveWatchdog)

    inst.OnEntityWake = OnEntityWake
    inst.OnEntitySleep = OnEntitySleep
    inst.OnDroneScoutSkinChanged = OnSurveyorSkinChanged
    inst.SetSkillBeam = SetSkillBeam
    inst.GetSkillBeam = GetSkillBeam
    inst.RecallForOwner = RecallForOwner
    inst.StartFollowing = StartFollowing
    inst.StopFollowing = StopFollowing
    inst.StopRotorMovement = StopRotorMovement
    inst.persists = false

    return inst
end

local function GetSurveyorRange(inst, owner)
    return RotorUpgrades.GetControlRange(owner or inst._kei_drone_owner)
end

local globalicon, revealableicon = MakeGlobalTrackingIcons("kei_rotor_surveyor", {
    icondata = {
        icon = "wx78_drone_scout",
        priority = 21,
        globalicon = "wx78_drone_scout_global",
        selectedicon = "wx78_drone_scout_selected",
        selectedpriority = MINIMAP_DECORATION_PRIORITY,
        fogrevealer = true,
    },
    global_common_postinit = function(inst)
        inst:SetPrefabNameOverride("kei_rotor_surveyor")
        inst.GetDroneRange = GetSurveyorRange
    end,
})

return Prefab("kei_rotor_surveyor", fn, assets, prefabs), globalicon, revealableicon
