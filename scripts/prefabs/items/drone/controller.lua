-- 旋翼调查仪控制器：手部装备，右键打开无人机控制轮盘。
local RotorSurveyRegistry = require("kei/drone/registry")
local RotorSurveySkills = require("kei/drone/skills")

local DRONE_CONTROL_WHEEL_RADIUS = 100
local ROTOR_ICON_ATLAS = "images/inventoryimages/kei_items.xml"
local StopDroneFollow

local function RequireRotorSkill(doer, skill)
    if RotorSurveySkills.HasSkill(doer, skill) then
        return true
    end

    if TheWorld ~= nil
        and TheWorld.ismastersim
        and doer ~= nil
        and doer.components ~= nil
        and doer.components.talker ~= nil
    then
        doer.components.talker:Say(STRINGS.CHARACTERS.KEI.ANNOUNCE_KEI_ROTOR_SKILL_LOCKED)
    end
    return false
end

local function IsDroneBoundToOwner(drone, owner)
    return drone ~= nil
        and drone:IsValid()
        and owner ~= nil
        and (drone._kei_drone_owner == owner
            or (owner.userid ~= nil and drone._kei_drone_owner_userid == owner.userid))
end

local function IsDroneInState(drone, state_name)
    if drone == nil or not drone:IsValid() or drone.sg == nil then
        return false
    end
    local state = drone.sg.currentstate
    return state ~= nil and state.name == state_name
end

local function IsDroneAirborne(drone)
    return IsDroneInState(drone, "flight")
        or IsDroneInState(drone, "projection")
        or IsDroneInState(drone, "projection_loop")
        or IsDroneInState(drone, "projection_pst")
end

local function OnControlWheelClose(inst)
    if TheWorld.ismastersim or inst._kei_rotor_skill_casting then
        inst._kei_rotor_skill_casting = nil
        return
    end

    -- 驾驶无人机时，关闭轮盘只代表结束选项选择，不应退出驾驶状态。
    if ThePlayer ~= nil and ThePlayer.sg ~= nil then
        local state = ThePlayer.sg.currentstate
        local state_name = state ~= nil and state.name or nil
        if state_name == "kei_rotor_drone_pilot"
            or state_name == "kei_rotor_drone_pilot_wheel"
            or state_name == "kei_rotor_drone_pilot_action"
        then
            return
        end
    end

    if MOD_RPC ~= nil
        and MOD_RPC.TendouKei ~= nil
        and MOD_RPC.TendouKei.StopRotorControl ~= nil
    then
        SendModRPCToServer(MOD_RPC.TendouKei.StopRotorControl)
    end
end

local function FindBoundDrone(inst, owner)
    if IsDroneBoundToOwner(inst.linked_drone, owner) then
        return inst.linked_drone
    end

    if owner == nil or owner.userid == nil then
        return nil
    end

    local drone = RotorSurveyRegistry.Find(owner.userid, function(candidate)
        return IsDroneBoundToOwner(candidate, owner)
    end)
    if drone ~= nil then
        inst.linked_drone = drone
        if inst._kei_linked_drone_net ~= nil then
            inst._kei_linked_drone_net:set(drone)
        end
        return drone
    end

    return nil
end

local function SetFollowActive(inst, active)
    active = active == true
    if inst._kei_follow_active_net ~= nil then
        inst._kei_follow_active_net:set(active)
    end
    if inst.components ~= nil and inst.components["drone/power"] ~= nil then
        inst.components["drone/power"]:SetFollowDrain(
            active and (TUNING.KEI_ROTOR_FOLLOW_DRAIN_RATE or 2) or 0
        )
    end
end

local function SetBoundDrone(inst, drone, owner)
    local previous_drone = inst.linked_drone
    if previous_drone ~= nil and previous_drone ~= drone then
        if inst.components ~= nil and inst.components["drone/beam"] ~= nil then
            inst.components["drone/beam"]:Stop()
        end
        if previous_drone.StopFollowing ~= nil then
            previous_drone:StopFollowing()
        end
        SetFollowActive(inst, false)
        if previous_drone._kei_detach_owner_callbacks ~= nil then
            previous_drone._kei_detach_owner_callbacks(previous_drone)
        end
        RotorSurveyRegistry.Unregister(previous_drone)
        previous_drone._kei_drone_owner = nil
        previous_drone._kei_drone_owner_userid = nil
        if previous_drone._kei_drone_owner_userid_net ~= nil then
            previous_drone._kei_drone_owner_userid_net:set("")
        end
    end

        inst.linked_drone = drone
    if inst._kei_linked_drone_net ~= nil then
        inst._kei_linked_drone_net:set(drone)
    end
    inst.drone_owner_userid = owner ~= nil and owner.userid or inst._kei_controller_owner_userid

    if drone ~= nil then
        drone._kei_drone_owner = owner
        drone._kei_drone_owner_userid = inst.drone_owner_userid
        if drone._kei_drone_owner_userid_net ~= nil then
            drone._kei_drone_owner_userid_net:set(inst.drone_owner_userid or "")
        end
        drone._kei_drone_controller = inst
        RotorSurveyRegistry.Register(drone, inst.drone_owner_userid)
        drone.persists = false
        if owner ~= nil and drone.components ~= nil then
            -- These callbacks use owner/TheWorld as the event source, so their
            -- first argument is the source entity rather than the drone.
            local function RemoveDroneForOwnerLeave(_source, data)
                local player = data ~= nil and data.player or data or owner
                if player == owner and drone:IsValid() then
                    drone:Remove()
                end
            end

            local function RemoveDroneForOwnerRemove()
                if drone:IsValid() then
                    drone:Remove()
                end
            end

            drone._kei_owner_leave_fn = RemoveDroneForOwnerLeave
            drone._kei_owner_remove_fn = RemoveDroneForOwnerRemove
            drone._kei_detach_owner_callbacks = function(drone_inst)
                if owner ~= nil then
                    drone_inst:RemoveEventCallback("onremove", RemoveDroneForOwnerRemove, owner)
                    drone_inst:RemoveEventCallback("player_despawn", RemoveDroneForOwnerLeave, owner)
                end
                if TheWorld ~= nil then
                    drone_inst:RemoveEventCallback("ms_playerdespawn", RemoveDroneForOwnerLeave, TheWorld)
                    drone_inst:RemoveEventCallback("ms_playerdespawnanddelete", RemoveDroneForOwnerLeave, TheWorld)
                    drone_inst:RemoveEventCallback("ms_playerdespawnandmigrate", RemoveDroneForOwnerLeave, TheWorld)
                end
                drone_inst._kei_owner_leave_fn = nil
                drone_inst._kei_owner_remove_fn = nil
                drone_inst._kei_detach_owner_callbacks = nil
            end

            drone:ListenForEvent("onremove", RemoveDroneForOwnerRemove, owner)
            -- The player event fires before the player entity is removed,
            -- including shard migration. This is earlier and more reliable
            -- than relying only on the world migration event.
            drone:ListenForEvent("player_despawn", RemoveDroneForOwnerLeave, owner)
            if TheWorld ~= nil then
                drone:ListenForEvent("ms_playerdespawn", RemoveDroneForOwnerLeave, TheWorld)
                drone:ListenForEvent("ms_playerdespawnanddelete", RemoveDroneForOwnerLeave, TheWorld)
                drone:ListenForEvent("ms_playerdespawnandmigrate", RemoveDroneForOwnerLeave, TheWorld)
            end

            if drone.components.globaltrackingicon ~= nil then
                drone.components.globaltrackingicon:StartTracking(owner, "kei_rotor_surveyor")
            end
            if drone.components.maprevealer ~= nil then
                drone.components.maprevealer:SetPrivateOwner(owner)
            end
        end
    end
end

local function GetOwnerUserId(inst)
    if inst._kei_controller_owner_userid ~= nil then
        return inst._kei_controller_owner_userid
    end
    if inst._kei_controller_owner_userid_net ~= nil then
        return inst._kei_controller_owner_userid_net:value()
    end
end

local function IsStoredByOwner(inst, owner)
    if inst == nil or owner == nil or owner.userid == nil or GetOwnerUserId(inst) ~= owner.userid then
        return false
    end

    local inventoryitem = inst.components ~= nil and inst.components.inventoryitem or nil
    local holder = inventoryitem ~= nil and inventoryitem.owner or nil
    if holder == owner then
        return true
    end
    return false
end

local function SetControllerOwner(inst, owner)
    local userid = owner ~= nil and owner.userid or nil
    local power = inst.components ~= nil and inst.components["drone/power"] or nil
    local loaded_power = power ~= nil and power.GetLoadedPower ~= nil
        and power:GetLoadedPower()
        or nil
    local inherited_power = loaded_power
        or (owner ~= nil and owner._kei_rotor_controller_power or nil)

    if inherited_power == nil and userid ~= nil then
        local previous = RotorSurveyRegistry.FindController(userid)
        local previous_power = previous ~= nil
            and previous ~= inst
            and previous.components ~= nil
            and previous.components["drone/power"]
            or nil
        if previous_power ~= nil and previous_power.GetPower ~= nil then
            inherited_power = previous_power:GetPower()
        end
    end

    inst._kei_controller_owner = owner
    inst._kei_controller_owner_userid = userid
    if inst._kei_controller_owner_userid_net ~= nil then
        inst._kei_controller_owner_userid_net:set(userid or "")
    end
    RotorSurveyRegistry.RegisterController(inst, userid)
    if power ~= nil then
        power:RefreshMaxPower(owner)
        if loaded_power ~= nil
            and power.GetMaxPower ~= nil
            and loaded_power > power:GetMaxPower()
        then
            -- The owner may still be loading the upgrade component. Keep the
            -- serialized value pending so the next power tick can retry after
            -- the expanded capacity becomes available.
            return
        end
        if inherited_power ~= nil then
            power:SetPower(inherited_power)
            if loaded_power ~= nil and power.ClearLoadedPower ~= nil then
                power:ClearLoadedPower()
            end
        elseif owner ~= nil then
            owner._kei_rotor_controller_power = power:GetPower()
        end
    end
end

local function OnBuilt(inst, data)
    local builder = data ~= nil and data.builder or nil
    if builder ~= nil and builder:HasTag("kei") then
        SetControllerOwner(inst, builder)
    end
end

local function OnSave(inst, data)
    if data == nil then
        return
    end

    data.kei_controller_owner_userid = inst._kei_controller_owner_userid
end

local function OnLoad(inst, data)
    inst._kei_controller_owner_userid = data ~= nil and data.kei_controller_owner_userid or nil
    if inst._kei_controller_owner_userid_net ~= nil then
        inst._kei_controller_owner_userid_net:set(inst._kei_controller_owner_userid or "")
    end
    RotorSurveyRegistry.RegisterController(inst, inst._kei_controller_owner_userid)
end

local function OnRemove(inst)
    if inst.components ~= nil and inst.components["drone/beam"] ~= nil then
        inst.components["drone/beam"]:Stop()
    end
    StopDroneFollow(inst, inst._kei_controller_owner)
    local drone = inst.linked_drone
    if drone ~= nil and drone:IsValid() and drone.StopFollowing ~= nil then
        drone:StopFollowing()
    end
    if drone ~= nil and drone._kei_drone_pilot ~= nil then
        local pilot = drone._kei_drone_pilot
        if pilot:IsValid() and pilot.sg ~= nil then
            pilot.sg:GoToState("kei_rotor_drone_pilot_stop", true)
        end
    end
    if drone ~= nil and drone:IsValid() then
        if drone._kei_detach_owner_callbacks ~= nil then
            drone._kei_detach_owner_callbacks(drone)
        end
        drone:Remove()
    end
    RotorSurveyRegistry.UnregisterController(inst)
end

local function StopPilotForOwner(inst, owner)
    local drone = inst.linked_drone
    if drone == nil or not drone:IsValid() then
        return
    end

    local was_piloting = drone._kei_drone_pilot == owner
        or (owner ~= nil and owner._kei_rotor_pilot_drone == drone)

    -- 电量耗尽可能发生在驾驶状态清理之后，此时无人机仍可能保留上一次的
    -- 自动驾驶速度。卸下控制器时始终清除速度，避免无人机继续移动。
    if drone.StopRotorMovement ~= nil then
        drone:StopRotorMovement()
    elseif drone.Physics ~= nil then
        local _, vy, _ = drone.Physics:GetMotorVel()
        drone.Physics:SetMotorVel(0, vy, 0)
    end

    drone._kei_drone_pilot = nil
    if inst._kei_pilot_active_net ~= nil then
        inst._kei_pilot_active_net:set(false)
    end
    if owner ~= nil then
        owner._kei_rotor_pilot_drone = nil
    end

    if not was_piloting then
        return
    end

    if owner ~= nil and owner.sg ~= nil then
        owner.sg:GoToState("kei_rotor_drone_pilot_stop", true)
    end
end

local function IsControllerOwnedBy(inst, owner)
    if owner ~= nil and inst._kei_controller_owner == owner then
        return true
    end

    local owned = owner ~= nil
        and owner.userid ~= nil
        and GetOwnerUserId(inst) == owner.userid
    if owned then
        -- Loaded controllers do not have the live player reference until the
        -- player has rejoined. Refresh it as soon as the bound player equips it.
        inst._kei_controller_owner = owner
    end
    return owned
end

local function ApplyEquipVisuals(inst, owner)
    if owner == nil or owner.AnimState == nil then
        return
    end

    owner.AnimState:OverrideSymbol(
        "swap_object",
        "kei_drone_zap_remote",
        "swap_drone_zap_remote"
    )
    owner.AnimState:OverrideSymbol(
        "drone_zap_remote_parts",
        "kei_drone_zap_remote",
        "drone_zap_remote_parts"
    )
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
    inst.components.inventoryitem:ChangeImageName("kei_drone_zap_remote_open")
end

local function IsEquippedBy(inst, owner)
    return owner ~= nil
        and owner.components ~= nil
        and owner.components.inventory ~= nil
        and owner.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS) == inst
end

local function VerifyControllerEquip(inst, owner, attempt)
    if inst == nil or not inst:IsValid() or owner == nil or not owner:IsValid() then
        return
    end

    -- An equip callback can run while the active item is moving toward the
    -- hand slot. Wait briefly for the slot update, but never remove an item
    -- that remains only in the active-item cursor.
    if not IsEquippedBy(inst, owner) then
        if (attempt or 0) < 10 then
            inst:DoTaskInTime(0.1, function(controller)
                VerifyControllerEquip(controller, owner, (attempt or 0) + 1)
            end)
        end
        return
    end

    if IsControllerOwnedBy(inst, owner) then
        ApplyEquipVisuals(inst, owner)
        return
    end

    -- The owner id can arrive one simulation tick after the equip callback for
    -- a freshly crafted or loaded item. Give that synchronization a short,
    -- bounded window before treating the equip as unauthorized.
    local owner_userid = GetOwnerUserId(inst)
    if (owner_userid == nil or owner_userid == "") and (attempt or 0) < 10 then
        inst:DoTaskInTime(0.1, function(controller)
            VerifyControllerEquip(controller, owner, (attempt or 0) + 1)
        end)
        return
    end

    inst:Remove()
end

local function OnEquip(inst, owner)
    VerifyControllerEquip(inst, owner, 0)
end

local function OnUnequip(inst, owner)
    StopPilotForOwner(inst, owner)
    if owner ~= nil and owner.AnimState ~= nil then
        owner.AnimState:ClearOverrideSymbol("drone_zap_remote_parts")
        owner.AnimState:ClearOverrideSymbol("swap_object")
        owner.AnimState:Hide("ARM_carry")
        owner.AnimState:Show("ARM_normal")
    end
    inst.components.inventoryitem:ChangeImageName("kei_drone_zap_remote_close")
end

local function ToggleBoundDrone(inst, doer)
    if not TheWorld.ismastersim or inst == nil or doer == nil then
        return false
    end

    local drone = FindBoundDrone(inst, doer)
    if drone ~= nil then
        local state = drone.sg ~= nil and drone.sg.currentstate or nil
        local state_name = state ~= nil and state.name or nil
        if state_name == "dormant" then
            drone.sg:GoToState("takeoff")
            return true
        elseif state_name == "flight"
            or state_name == "projection"
            or state_name == "projection_loop"
            or state_name == "projection_pst"
        then
            if inst.components ~= nil and inst.components["drone/beam"] ~= nil then
                inst.components["drone/beam"]:Stop()
            end
            if drone.components ~= nil and drone.components.mapdeliverable ~= nil then
                drone.components.mapdeliverable:Stop()
            end
            drone.sg:GoToState("landing")
            return true
        end
        return false
    end

    local x, _, z = doer.Transform:GetWorldPosition()
    drone = SpawnPrefab("kei_rotor_surveyor")
    if drone == nil then
        return false
    end

    drone.Physics:Teleport(x, 0.01, z)
    SetBoundDrone(inst, drone, doer)
    drone.sg:GoToState("takeoff")
    return true
end

local function EnsureBoundDrone(inst, doer)
    -- Non takeoff/landing skills may only operate on the already deployed
    -- drone. In particular, dormant drones must not be respawned or woken by
    -- follow, pilot, or beam actions.
    return FindBoundDrone(inst, doer)
end

StopDroneFollow = function(inst, owner)
    local drone = inst.linked_drone
    if drone == nil or not drone:IsValid() then
        drone = FindBoundDrone(inst, owner)
    end
    if drone ~= nil and drone.StopFollowing ~= nil then
        drone:StopFollowing()
    end
    SetFollowActive(inst, false)
end

local function RecallBoundDrone(inst, owner)
    if not TheWorld.ismastersim or inst == nil or owner == nil then
        return false
    end

    local drone = FindBoundDrone(inst, owner)
    if drone == nil then
        return false
    end

    StopPilotForOwner(inst, owner)
    StopDroneFollow(inst, owner)
    SetBoundDrone(inst, nil, owner)
    if drone:IsValid() then
        drone:Remove()
    end
    return true
end

local function ToggleDroneFollow(inst, doer)
    if not TheWorld.ismastersim or inst == nil or doer == nil then
        return false
    end
    if not RequireRotorSkill(doer, "follow") then
        return false
    end

    local drone = EnsureBoundDrone(inst, doer)
    if drone == nil or not IsDroneAirborne(drone) then
        return false
    end

    if drone._kei_rotor_follow_owner == doer then
        StopDroneFollow(inst, doer)
        return true
    end

    if drone._kei_drone_pilot == doer then
        StopPilotForOwner(inst, doer)
    elseif drone._kei_drone_pilot ~= nil
        and drone._kei_drone_pilot:IsValid()
    then
        return false
    end

    if drone.StartFollowing == nil or not drone:StartFollowing(doer) then
        return false
    end
    SetFollowActive(inst, true)
    return true
end

local function ToggleDronePilot(inst, doer)
    if not TheWorld.ismastersim or inst == nil or doer == nil then
        return false
    end
    if not RequireRotorSkill(doer, "pilot") then
        return false
    end

    local drone = FindBoundDrone(inst, doer)
    if drone == nil or not IsDroneAirborne(drone) then
        return false
    end

    if drone._kei_rotor_follow_owner == doer then
        StopDroneFollow(inst, doer)
    end

    if drone._kei_drone_pilot == doer or doer._kei_rotor_pilot_drone == drone then
        if drone.StopRotorMovement ~= nil then
            drone:StopRotorMovement()
        else
            drone:PushEventImmediate("locomote")
        end
        drone._kei_drone_pilot = nil
        doer._kei_rotor_pilot_drone = nil
        if inst._kei_pilot_active_net ~= nil then
            inst._kei_pilot_active_net:set(false)
        end
        if doer.sg ~= nil then
            doer.sg:GoToState("kei_rotor_drone_pilot_stop", true)
        end
        return true
    end

    local previous_pilot = drone._kei_drone_pilot
    if previous_pilot ~= nil and previous_pilot ~= doer and previous_pilot:IsValid() then
        return false
    end

    drone._kei_drone_pilot = doer
    doer._kei_rotor_pilot_drone = drone
    if inst._kei_pilot_active_net ~= nil then
        inst._kei_pilot_active_net:set(true)
    end
    if doer.sg ~= nil then
        doer.sg:GoToState("kei_rotor_drone_pilot", drone)
    end
    return true
end

local function CastControllerSpell(inst)
    inst._kei_rotor_skill_casting = true
    if ThePlayer ~= nil and ThePlayer.replica.inventory ~= nil then
        ThePlayer.replica.inventory:CastSpellBookFromInv(inst)
    end
    inst:DoTaskInTime(0, function()
        if inst:IsValid() then
            inst._kei_rotor_skill_casting = nil
        end
    end)
end

local function CastToggleDrone(inst)
    CastControllerSpell(inst)
end

local function CastDronePilot(inst)
    CastControllerSpell(inst)
end

local function CastDroneFollow(inst)
    CastControllerSpell(inst)
end

local function CastRotorBeam(inst)
    CastControllerSpell(inst)
end

local function ActivateRotorBeam(inst, doer, beam_name)
    if not TheWorld.ismastersim or inst == nil or doer == nil then
        return false
    end
    if not RequireRotorSkill(doer, beam_name) then
        return false
    end

    local drone = EnsureBoundDrone(inst, doer)
    if drone == nil or not IsDroneAirborne(drone) or drone.SetSkillBeam == nil then
        return false
    end

    if drone.GetSkillBeam ~= nil and drone:GetSkillBeam() == beam_name then
        drone:SetSkillBeam(nil)
        if inst.components["drone/beam"] ~= nil then
            inst.components["drone/beam"]:Stop()
        end
    else
        if inst.components["drone/beam"] == nil
            or not inst.components["drone/beam"]:Start(beam_name, drone, doer)
        then
            return false
        end
        drone:SetSkillBeam(beam_name)
        if IsDroneInState(drone, "flight") then
            drone.sg:GoToState("projection")
        end
    end
    return true
end

local function IsRotorSkillUnlocked(owner, skill)
    return skill == nil or RotorSurveySkills.HasSkill(owner, skill)
end

local function MakeRotorSkillAnim(icon, skill, loop)
    return function(owner)
        if not IsRotorSkillUnlocked(owner, skill) then
            return { anim = icon.."_disable" }
        end
        return {
            anim = loop and icon.."_foucs" or icon,
            loop = loop,
        }
    end
end

local function MakeDroneControlSpell(label, icon, pilot, skill)
    local spell = {
        label = label,
        bank = "drone_icons_kei",
        build = "drone_icons_kei",
        anims = {
            idle = MakeRotorSkillAnim(icon, skill),
            focus = MakeRotorSkillAnim(icon, skill, true),
            down = { anim = icon.."_pressed" },
            disabled = { anim = icon.."_disable" },
        },
        execute = pilot and CastDronePilot or function() return true end,
        kei_skill = skill,
        kei_rotor_ring = 1,
        widget_scale = 0.4,
    }
    if pilot then
        spell.onselect = function(inst)
            inst.components.spellbook:SetSpellAction(ACTIONS.KEI_ROTOR_PILOT)
            if TheWorld.ismastersim then
                inst.components.spellbook:SetSpellFn(inst.ToggleDronePilot)
            end
        end
    end
    return spell
end

local function MakeRotorBeamSpell(label, beam_name, ring)
    local spell = MakeDroneControlSpell(label, "icon_"..beam_name, false, beam_name)
    if ring ~= nil then
        spell.kei_rotor_ring = ring
    end
    spell.execute = CastRotorBeam
    spell.onselect = function(inst)
        inst.components.spellbook:SetSpellAction(ACTIONS.KEI_ROTOR_BEAM)
        if TheWorld.ismastersim then
            inst.components.spellbook:SetSpellFn(function(controller, doer)
                return ActivateRotorBeam(controller, doer, beam_name)
            end)
        end
    end
    return spell
end

local DRONE_CONTROL_WHEEL_ITEMS = {
    {
        label = "起飞/降落",
        onselect = function(inst)
            inst.components.spellbook:SetSpellAction(ACTIONS.KEI_ROTOR_CONTROL)
            if TheWorld.ismastersim then
                inst.components.spellbook:SetSpellFn(ToggleBoundDrone)
            end
        end,
        execute = CastToggleDrone,
        bank = "drone_icons_kei",
        build = "drone_icons_kei",
        anims = {
            idle = MakeRotorSkillAnim("icon_enble_drone", "enable_drone"),
            focus = MakeRotorSkillAnim("icon_enble_drone", "enable_drone", true),
            down = { anim = "icon_enble_drone_pressed" },
            disabled = { anim = "icon_enble_drone_disable" },
        },
        widget_scale = 0.4,
        kei_skill = "enable_drone",
        kei_rotor_ring = 1,
    },
    MakeDroneControlSpell("驾驶", "icon_pilot", true, "pilot"),
    MakeRotorBeamSpell("苏生光束", "resurrection"),
    MakeRotorBeamSpell("治愈光束", "heal"),
    MakeRotorBeamSpell("强化光束", "strengthen"),
    MakeRotorBeamSpell("禁锢光束", "confinement"),
    MakeRotorBeamSpell("死亡光束", "dead"),
    MakeRotorBeamSpell("调查光束", "survey"),
}

local function MakeRotorPlaceholderSpell(label, skill)
    return {
        label = label,
        bank = "drone_icons_kei",
        build = "drone_icons_kei",
        anims = {
            idle = MakeRotorSkillAnim("icon_disable", skill),
            focus = { anim = "icon_disable", loop = true },
            down = { anim = "icon_disable" },
            disabled = { anim = "icon_disable" },
        },
        onselect = function(inst)
            inst.components.spellbook:SetSpellAction(ACTIONS.KEI_ROTOR_CONTROL)
            if TheWorld.ismastersim then
                inst.components.spellbook:SetSpellFn(function(controller, doer)
                    if not RequireRotorSkill(doer, skill) then
                        return false
                    end
                    return true
                end)
            end
        end,
        execute = CastControllerSpell,
        kei_skill = skill,
        kei_rotor_ring = 2,
        widget_scale = 0.4,
    }
end

local function MakeRotorFollowSpell()
    return {
        label = "跟随",
        bank = "drone_icons_kei",
        build = "drone_icons_kei",
        anims = {
            idle = MakeRotorSkillAnim("icon_follow", "follow"),
            focus = MakeRotorSkillAnim("icon_follow", "follow", true),
            down = { anim = "icon_follow_pressed" },
            disabled = { anim = "icon_follow_disable" },
        },
        onselect = function(inst)
            inst.components.spellbook:SetSpellAction(ACTIONS.KEI_ROTOR_CONTROL)
            if TheWorld.ismastersim then
                inst.components.spellbook:SetSpellFn(ToggleDroneFollow)
            end
        end,
        execute = CastDroneFollow,
        kei_skill = "follow",
        kei_rotor_ring = 2,
        widget_scale = 0.4,
    }
end

DRONE_CONTROL_WHEEL_ITEMS[#DRONE_CONTROL_WHEEL_ITEMS + 1] = MakeRotorFollowSpell()
DRONE_CONTROL_WHEEL_ITEMS[#DRONE_CONTROL_WHEEL_ITEMS + 1] = MakeRotorBeamSpell("传送光束", "teleport", 2)
DRONE_CONTROL_WHEEL_ITEMS[#DRONE_CONTROL_WHEEL_ITEMS + 1] = MakeRotorBeamSpell("收集光束", "collect", 2)
DRONE_CONTROL_WHEEL_ITEMS[#DRONE_CONTROL_WHEEL_ITEMS + 1] = MakeRotorBeamSpell("捕捞光束", "fishing", 2)
DRONE_CONTROL_WHEEL_ITEMS[#DRONE_CONTROL_WHEEL_ITEMS + 1] = MakeRotorBeamSpell("自然光束", "nature", 2)
DRONE_CONTROL_WHEEL_ITEMS[#DRONE_CONTROL_WHEEL_ITEMS + 1] = MakeRotorBeamSpell("友善光束", "friendly", 2)

local function CanOpenDroneControlWheel(inst, user)
    if inst == nil or user == nil or not user:HasTag("kei") or user:HasTag("playerghost") then
        return false
    end

    local inventory = user.components ~= nil and user.components.inventory or nil
    if inventory == nil and user.replica ~= nil then
        inventory = user.replica.inventory
    end
    if inventory ~= nil and inventory.GetEquippedItem ~= nil then
        return inventory:GetEquippedItem(EQUIPSLOTS.HANDS) == inst
    end

    return false
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("kei_drone_zap_remote")
    inst.AnimState:SetBuild("kei_drone_zap_remote")
    inst.AnimState:PlayAnimation("ground")

    MakeInventoryFloatable(inst, "med", 0.27, { 0.85, 1, 1 })

    inst:AddTag("kei_rotor_survey_controller")
    inst:AddTag("donotautopick")
    inst:AddTag("nosteal")
    inst._kei_controller_owner_userid_net = net_string(inst.GUID, "kei_rotor_survey_controller.owner_userid")
    inst._kei_linked_drone_net = net_entity(inst.GUID, "kei_rotor_survey_controller.linked_drone")
    inst._kei_pilot_active_net = net_bool(inst.GUID, "kei_rotor_survey_controller.pilot_active")
    inst._kei_follow_active_net = net_bool(inst.GUID, "kei_rotor_survey_controller.follow_active")

    -- 复用 Willow 的 spellbook -> USESPELLBOOK -> HUD 技能轮盘流程。
    inst:AddComponent("spellbook")
    inst.components.spellbook:SetRadius(DRONE_CONTROL_WHEEL_RADIUS)
    inst.components.spellbook:SetFocusRadius(DRONE_CONTROL_WHEEL_RADIUS + 2)
    inst.components.spellbook:SetItems(DRONE_CONTROL_WHEEL_ITEMS)
    inst.components.spellbook:SetCanUseFn(CanOpenDroneControlWheel)
    inst.components.spellbook:SetSpellAction(ACTIONS.KEI_ROTOR_CONTROL)
    inst.components.spellbook:SetOnCloseFn(OnControlWheelClose)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem.atlasname = ROTOR_ICON_ATLAS
    inst.components.inventoryitem:ChangeImageName("kei_drone_zap_remote_close")
    -- cangoincontainer 必须保持开启，否则 DST 的 SetActiveItem 会直接
    -- 丢弃控制器，导致鼠标拿起、右键装备流程中的物品消失。普通容器仍
    -- 由 kei/drone/hooks/containers.lua 拦截。
    inst.components.inventoryitem.canbepickedup = true
    inst.components.inventoryitem.cangoincontainer = true
    inst.components.inventoryitem.canonlygoinpocketorpocketcontainers = true
    inst.components.inventoryitem.keepondeath = true

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.KEI_ROTOR_CONTROLLER_MAX_POWER or 240)

    inst:AddComponent("drone/power")
    inst:AddComponent("drone/beam")

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.HANDS
    inst.components.equippable.restrictedtag = "kei"
    inst.components.equippable:SetOnEquip(OnEquip)
    inst.components.equippable:SetOnUnequip(OnUnequip)

    inst.components.spellbook:SetSpellFn(ToggleBoundDrone)

    inst.SetBoundDrone = SetBoundDrone
    inst.SetControllerOwner = SetControllerOwner
    inst.IsStoredByOwner = IsStoredByOwner
    inst.GetControllerOwnerUserId = GetOwnerUserId
    inst.FindBoundDrone = FindBoundDrone
    inst.ToggleBoundDrone = ToggleBoundDrone
    inst.RecallBoundDrone = RecallBoundDrone
    inst.ToggleDronePilot = ToggleDronePilot
    inst.ToggleDroneFollow = ToggleDroneFollow
    inst.StopDroneFollow = StopDroneFollow
    inst.StopPilotForOwner = StopPilotForOwner
    inst.onPreBuilt = function(item, builder)
        if builder ~= nil and builder:HasTag("kei") then
            SetControllerOwner(item, builder)
        end
    end
    inst.OnSave = OnSave
    inst.OnLoad = OnLoad
    inst:ListenForEvent("onbuilt", OnBuilt)
    inst:ListenForEvent("onremove", OnRemove)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("kei_rotor_survey_controller", fn, {
    Asset("ANIM", "anim/kei_drone_zap_remote.zip"),
    -- 原版角色状态机使用的遥控动作：
    -- drone_zap_remote_use_pre / loop / pst。
    -- 这些动作依赖原版 wx78_drone_zap build，单独作为资源包加载，
    -- 不与自定义地面和手持遥控器 build 合并，避免破坏 KAnim 索引。
    Asset("ANIM", "anim/kei_drone_zap_remote_actions.zip"),
    Asset("ANIM", "anim/drone_icons_kei.zip"),
    Asset("ATLAS", ROTOR_ICON_ATLAS),
    Asset("IMAGE", ROTOR_ICON_ATLAS:gsub("%.xml$", ".tex")),
})
