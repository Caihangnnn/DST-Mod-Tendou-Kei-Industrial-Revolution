require("prefabutil")

local Power = require("kei/power_system")

local DEVICE_VISUAL_SCALE = 2
local BATTERY_HAMMER_ANIM_SPEED = 3
local ELECTROBANK_CHARGE_TIME = 60
local ELECTROBANK_METER_BLOOM_SYMBOL = "charger_meter_bloom"
local ELECTROBANK_METER_BLOOM_LEVELS = 10
local ELECTROBANK_STOP_ANIMATION = "stop"
-- Completing a charge uses the post-working animation before entering the
-- charged idle state. Removing a battery goes directly to `off`.
local ELECTROBANK_COMPLETE_ANIMATION = "working_pst"
-- The charger consumes power continuously through the power-system tick and
-- updates the stepped loop symbols in five-second intervals.
local ELECTROBANK_CHARGE_TICK = 5
-- Nodes are small ground sprites, so their render bounds are too small for
-- comfortable mouse targeting.  This is only the invisible physics hit
-- radius; it does not scale the node animation.
local POWER_NODE_HIT_RADIUS = 1

local WIRE_ASSETS = {
    Asset("ANIM", "anim/kei_utilities_electric.zip"),
    Asset("ANIM", "anim/kei_utilities_electric_conduct.zip"),
    Asset("ANIM", "anim/kei_utilities_electric_conduct_hiwatt.zip"),
    Asset("ANIM", "anim/kei_logic_wires.zip"),
}

local function SetWireAnim(inst, animation)
    if inst == nil or inst.AnimState == nil then
        return
    end
    animation = animation or "None"
    inst.AnimState:PlayAnimation(animation, true)

    -- Keep every wire below characters.  The corner piece is drawn above
    -- straight pieces so its joint covers the straight-wire ends cleanly.
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    local is_one_way = animation == "L"
        or animation == "U"
        or animation == "D"
        or animation == "R"
    local is_corner = animation == "LD"
        or animation == "LU"
        or animation == "RD"
        or animation == "RU"
        or animation == "LR_UD_Bridge"
    inst.AnimState:SetSortOrder(is_one_way and -1 or (is_corner and 1 or 0))
end

local function SetWireScale(inst, animation, scale)
    scale = scale or 1
    if animation == "UD" then
        inst.AnimState:SetScale(1, scale)
    elseif animation == "LR" then
        inst.AnimState:SetScale(scale, 1)
    else
        inst.AnimState:SetScale(1, 1)
    end
end

local function SetWireBuild(inst, grade)
    if inst == nil or inst.AnimState == nil then
        return
    end
    inst.AnimState:SetBank(grade or "kei_utilities_electric")
    inst.AnimState:SetBuild(grade or "kei_utilities_electric")
end

local function SetWireKind(inst, kind)
    if inst == nil or inst.AnimState == nil then
        return
    end
    local build = inst.kei_power_wire_build
    if not inst.kei_power_is_node then
        build = kind == "signal"
            and "kei_logic_wires"
            or (inst.kei_power_grade or "kei_utilities_electric")
    end
    inst.AnimState:SetBank(build or "kei_utilities_electric")
    inst.AnimState:SetBuild(build or "kei_utilities_electric")
end

local function SetBatteryVisual(inst)
    if inst == nil or inst.AnimState == nil
        or inst.kei_power_battery_empty_animation == nil
    then
        return
    end
    local animation = (inst.kei_power_battery_level or 0) <= 0
        and inst.kei_power_battery_empty_animation
        or inst.kei_power_battery_full_animation
    if animation ~= nil then
        inst.AnimState:PlayAnimation(animation, true)
    end
end

local function SetDeviceAnimation(inst, powered)
    if inst.kei_power_is_charger then
        return
    end
    if (inst.kei_power_battery_capacity or 0) > 0 then
        SetBatteryVisual(inst)
        return
    end
    local animation = powered and inst.kei_power_work_animation
        or inst.kei_power_idle_animation
    if animation ~= nil then
        inst.AnimState:PlayAnimation(animation, true)
    end
end

local function GetChargerBattery(inst)
    local container = inst ~= nil and inst.components ~= nil
        and inst.components.container or nil
    return container ~= nil and container:GetItemInSlot(1) or nil
end

local function DisableChargerOpening(inst)
    local container = inst ~= nil and inst.components ~= nil
        and inst.components.container or nil
    if container == nil then
        return
    end

    -- The charger is operated through its dedicated interaction actions.
    -- Keep the internal container for server-side storage, but never expose
    -- its widget or allow the vanilla RUMMAGE/STORE actions to open it.
    container.canbeopened = false
end

local function IsEmptyElectrobank(item)
    return item ~= nil and item.prefab == "kei_emptyelectrobank"
end

local function IsFullElectrobank(item)
    return item ~= nil and item.prefab == "kei_electrobank"
end

local function SetChargerContentsState(inst, state)
    if inst ~= nil
        and inst._kei_charger_contents ~= nil
        and TheWorld ~= nil and TheWorld.ismastersim
    then
        inst._kei_charger_contents:set(state or 0)
    end
end

local function GetChargerContentsState(inst)
    local battery = GetChargerBattery(inst)
    return IsFullElectrobank(battery) and 2 or (IsEmptyElectrobank(battery) and 1 or 0)
end

local function SetChargerMeter(inst, progress)
    progress = math.max(0, math.min(1, progress or 0))
    inst.kei_electrobank_charge_progress = progress
    if inst._kei_charger_progress ~= nil
        and TheWorld ~= nil and TheWorld.ismastersim
    then
        inst._kei_charger_progress:set(progress)
    end

    if inst == nil or inst.AnimState == nil then
        return
    end

    -- Match wx78_drone_zap_overlay: the progress symbols belong to the
    -- current AnimState, so change only their visibility. Do not play the
    -- separate animation or create a second entity; either would reset the
    -- working_loop symbols and can make the bar appear full immediately.
    inst.AnimState:Hide(ELECTROBANK_METER_BLOOM_SYMBOL)
    for level = 1, ELECTROBANK_METER_BLOOM_LEVELS do
        inst.AnimState:Hide(ELECTROBANK_METER_BLOOM_SYMBOL .. "_" .. level)
    end

    -- Ten equal intervals: below 10% is empty, 10%~<20% is _1, ...,
    -- 90%~<100% is _9, and exactly 100% is _10.
    local level = progress >= 1 and ELECTROBANK_METER_BLOOM_LEVELS
        or math.floor(progress * ELECTROBANK_METER_BLOOM_LEVELS)
    if level > 0 then
        inst.AnimState:Show(ELECTROBANK_METER_BLOOM_SYMBOL .. "_" .. level)
    end
end

local function RefreshChargerMeter(inst)
    if inst == nil or inst._kei_charger_progress == nil then
        return
    end
    SetChargerMeter(inst, inst._kei_charger_progress:value())
end

local function ApplyChargerAnimation(inst, animation)
    if inst == nil or inst.AnimState == nil or animation == nil then
        return
    end

    inst.kei_electrobank_animation = animation
    if animation == "working_loop"
        and inst.AnimState:IsCurrentAnimation("working_loop")
    then
        inst.AnimState:Resume()
    else
        inst.AnimState:PlayAnimation(animation, animation == "working_loop"
            or animation == "off" or animation == "on"
            or animation == ELECTROBANK_STOP_ANIMATION)
    end

    -- Changing the charger's main animation can rebuild the shared KAnim
    -- symbol state. Re-apply the loop symbols after entering the loop so they
    -- cannot fall back to the last/full frame when a battery is
    -- inserted.
    if animation == "working_loop" then
        SetChargerMeter(inst, inst.kei_electrobank_charge_progress or 0)
    end
end

local function QueueChargerAnimationSync(inst)
    if inst == nil or inst._kei_charger_animation_sync_task ~= nil then
        return
    end

    -- The animation string, powered bool, and net events can be delivered in
    -- different dirty-event callbacks during the same simulation tick.  Wait
    -- one tick, then reconcile from the current net values so a late state
    -- event cannot leave the charger in the wrong animation.
    inst._kei_charger_animation_sync_task = inst:DoTaskInTime(0, function(entity)
        entity._kei_charger_animation_sync_task = nil
        if not entity:IsValid() or entity.AnimState == nil
            or entity._kei_charger_animation == nil
        then
            return
        end

        local animation = entity._kei_charger_animation:value()
        -- `_kei_powered` is the authoritative circuit result.  The animation
        -- net string and the power net bool can arrive in separate dirty
        -- events; do not let an older `stop` value prevent a powered charger
        -- from resuming its working loop.
        if entity._kei_powered ~= nil and entity._kei_powered:value() then
            if not entity.AnimState:IsCurrentAnimation("working_loop") then
                ApplyChargerAnimation(entity, "working_loop")
            else
                entity.AnimState:Resume()
            end
        elseif animation == "working_loop" then
            if not entity.AnimState:IsCurrentAnimation(ELECTROBANK_STOP_ANIMATION) then
                ApplyChargerAnimation(entity, ELECTROBANK_STOP_ANIMATION)
            end
        end
    end)
end

local function ReconcileChargerAnimation(inst)
    if inst == nil or not inst:IsValid() or inst.AnimState == nil
        or inst._kei_charger_animation == nil
    then
        return
    end

    -- The animation name can remain `working_loop` while only the powered
    -- state changes.  In that case no animation-string dirty event is
    -- generated, so explicitly reconcile the state animation as well.
    local animation = inst._kei_charger_animation:value()
    if inst._kei_powered ~= nil and inst._kei_powered:value() then
        if not inst.AnimState:IsCurrentAnimation("working_loop") then
            ApplyChargerAnimation(inst, "working_loop")
        else
            inst.AnimState:Resume()
        end
    elseif animation == "working_loop" then
        if not inst.AnimState:IsCurrentAnimation(ELECTROBANK_STOP_ANIMATION) then
            ApplyChargerAnimation(inst, ELECTROBANK_STOP_ANIMATION)
        end
    end
end

local function OnChargerAnimationDirty(inst)
    local animation = inst._kei_charger_animation:value()
    if animation ~= nil and animation ~= "" then
        if animation == "working_loop"
            or animation == ELECTROBANK_STOP_ANIMATION
        then
            QueueChargerAnimationSync(inst)
        else
            ApplyChargerAnimation(inst, animation)
        end
    end
end

local function OnChargerPauseDirty(inst)
    if inst ~= nil and inst.AnimState ~= nil then
        -- The server keeps the authoritative animation state. The client
        -- receives this legacy event and reconciles to the authoritative
        -- working/stop state instead of freezing a working-loop frame.
        QueueChargerAnimationSync(inst)
    end
end

local function OnChargerResumeDirty(inst)
    if inst == nil or inst.AnimState == nil then
        return
    end

    QueueChargerAnimationSync(inst)
end

local function OnChargerProgressDirty(inst)
    RefreshChargerMeter(inst)
end

local function StopChargerTask(inst)
    if inst.kei_electrobank_charge_task ~= nil then
        inst.kei_electrobank_charge_task:Cancel()
        inst.kei_electrobank_charge_task = nil
    end
end

local function StopChargerPostTask(inst)
    if inst.kei_electrobank_post_task ~= nil then
        inst.kei_electrobank_post_task:Cancel()
        inst.kei_electrobank_post_task = nil
    end
end

local SetChargerAnimation

local function StopChargerAnimation(inst)
    if inst == nil or inst.AnimState == nil then
        return
    end

    SetChargerAnimation(inst, ELECTROBANK_STOP_ANIMATION)
end

local function PlayChargerCompleteAnimation(inst)
    if inst == nil or not inst:IsValid() then
        return
    end

    StopChargerPostTask(inst)
    SetChargerAnimation(inst, ELECTROBANK_COMPLETE_ANIMATION)
    inst.kei_electrobank_post_task = inst:DoTaskInTime(
        math.max(FRAMES, inst.AnimState:GetCurrentAnimationLength()),
        function(entity)
            entity.kei_electrobank_post_task = nil
            if not entity:IsValid() then
                return
            end

            -- The converted full battery remains in the charger while this
            -- animation plays. If it was removed or the charger was reset,
            -- the item-loss path has already selected `off`.
            if IsFullElectrobank(GetChargerBattery(entity))
            then
                SetChargerAnimation(entity, "on")
            end
        end
    )
end

SetChargerAnimation = function(inst, animation)
    ApplyChargerAnimation(inst, animation)
    if inst._kei_charger_animation ~= nil
        and TheWorld ~= nil and TheWorld.ismastersim
    then
        inst._kei_charger_animation:set(animation)
    end
    if animation == "on" then
        SetChargerMeter(inst, 1)
    end
end

local function ResumeChargerAnimation(inst)
    if inst == nil or inst.AnimState == nil then
        return
    end

    if not inst.AnimState:IsCurrentAnimation("working_loop") then
        SetChargerAnimation(inst, "working_loop")
    else
        inst.AnimState:Resume()
        if inst._kei_charger_resume ~= nil
            and TheWorld ~= nil and TheWorld.ismastersim
        then
            inst._kei_charger_resume:push()
        end
    end
end

local function UpdateChargerPowerDemand(inst)
    local battery = GetChargerBattery(inst)
    inst.kei_power_consumption = IsEmptyElectrobank(battery)
        and inst.kei_electrobank_pre_done
        and (inst.kei_electrobank_power or Power.ELECTROBANK_CHARGER_POWER)
        or 0
end

local function StartElectrobankCharging(inst)
    if not IsEmptyElectrobank(GetChargerBattery(inst))
        or not inst.kei_electrobank_pre_done
        or not inst.kei_electrobank_powered
    then
        return
    end

    if inst.kei_electrobank_charge_task == nil then
        if inst.AnimState:IsCurrentAnimation("working_loop") then
            ResumeChargerAnimation(inst)
        else
            SetChargerAnimation(inst, "working_loop")
        end
        inst.kei_electrobank_charge_task = inst:DoPeriodicTask(
            ELECTROBANK_CHARGE_TICK,
            function(entity)
                if not entity:IsValid() then
                    return
                end
                if not entity.kei_electrobank_powered
                    or not IsEmptyElectrobank(GetChargerBattery(entity))
                then
                    return
                end

                -- DoPeriodicTask callbacks receive the entity and the extra
                -- arguments supplied at registration, not a frame delta.
                -- The power system itself ticks at the same fixed interval.
                SetChargerMeter(
                    entity,
                    (entity.kei_electrobank_charge_progress or 0)
                        + ELECTROBANK_CHARGE_TICK / ELECTROBANK_CHARGE_TIME
                )
                if entity.kei_electrobank_charge_progress >= 1 then
                    StopChargerTask(entity)
                    local container = entity.components.container
                    -- Replacing the internal empty battery with the charged
                    -- output is one atomic machine operation.  Suppress the
                    -- normal player insert/remove animation callbacks while
                    -- the container emits its item events.
                    entity.kei_electrobank_converting = true
                    local empty = container ~= nil
                        and container:RemoveItemBySlot(1) or nil
                    if empty ~= nil then
                        empty:Remove()
                    end

                    local full = SpawnPrefab("kei_electrobank")
                    local stored = false
                    if full ~= nil and container ~= nil then
                        entity.kei_electrobank_inserting_output = true
                        stored = container:GiveItem(full, 1, nil, false)
                        entity.kei_electrobank_inserting_output = nil
                        if not stored and full:IsValid() then
                            full.Transform:SetPosition(entity.Transform:GetWorldPosition())
                            full.components.inventoryitem:OnDropped(true, 0.5)
                        end
                    end
                    SetChargerContentsState(entity, stored and 2 or 0)
                    entity.kei_electrobank_converting = nil

                    entity.kei_electrobank_pre_done = false
                    entity.kei_electrobank_powered = false
                    entity.kei_power_consumption = 0
                    DisableChargerOpening(entity)
                    -- A completed charge transitions through working_pst;
                    -- after it finishes, PlayChargerCompleteAnimation moves
                    -- the charger into its charged `on` state.
                    PlayChargerCompleteAnimation(entity)
                    Power.RefreshAll(0)
                end
            end,
            ELECTROBANK_CHARGE_TICK
        )
    else
        -- The task can survive a transient power-state refresh while the
        -- delayed power-loss callback is pending. Explicitly resume the
        -- animation when power is available again.
        ResumeChargerAnimation(inst)
    end
end

-- The battery insertion and power-system callbacks are independent events.
-- Keep the actual work/stop decision in one place so either event can
-- re-evaluate the charger, including a charger that is already showing stop
-- when its power node becomes available again.
local function ReevaluateChargerWorkState(inst)
    if inst == nil or not inst:IsValid() then
        return false
    end

    local battery = GetChargerBattery(inst)
    if not IsEmptyElectrobank(battery) or not inst.kei_electrobank_pre_done then
        return false
    end

    UpdateChargerPowerDemand(inst)
    if inst.kei_electrobank_powered then
        StartElectrobankCharging(inst)
        return true
    end

    -- A charger can enter stop before a charge task has ever been created
    -- (for example, when a battery is inserted into an unpowered circuit).
    -- Always clear any stale task and make the stop state authoritative.
    StopChargerTask(inst)
    if not inst.AnimState:IsCurrentAnimation(ELECTROBANK_STOP_ANIMATION) then
        StopChargerAnimation(inst)
    end
    return false
end

local function OnChargerPreDone(inst)
    inst.kei_electrobank_pre_task = nil
    if not inst:IsValid() or not IsEmptyElectrobank(GetChargerBattery(inst)) then
        return
    end
    inst.kei_electrobank_pre_done = true
    UpdateChargerPowerDemand(inst)
    Power.RefreshAll(0)
    ReevaluateChargerWorkState(inst)
end

local function OnChargerItemGet(inst, data)
    if inst.kei_electrobank_converting then
        return
    end
    local item = data ~= nil and data.item or nil
    if not IsEmptyElectrobank(item) then
        return
    end

    SetChargerContentsState(inst, 1)

    StopChargerPostTask(inst)
    -- Once a battery is accepted, close and lock the machine. The slot stays
    -- unavailable until the charger has produced the full battery.
    DisableChargerOpening(inst)
    if inst.components.container ~= nil and inst.components.container:IsOpen() then
        inst.components.container:Close()
    end
    StopChargerTask(inst)
    if inst.kei_electrobank_pre_task ~= nil then
        inst.kei_electrobank_pre_task:Cancel()
        inst.kei_electrobank_pre_task = nil
    end
    if not inst.kei_electrobank_loading then
        SetChargerMeter(inst, 0)
    end
    -- Insertion enters the working loop immediately. There is no separate
    -- working_pre phase: the loop is either allowed to run by the power
    -- system or switches to the authored stop state when power is unavailable.
    inst.kei_electrobank_pre_done = true
    inst.kei_electrobank_powered = false
    UpdateChargerPowerDemand(inst)
    SetChargerAnimation(inst, "working_loop")
    Power.RefreshAll(0)
    ReevaluateChargerWorkState(inst)
end

local function OnChargerItemLose(inst, data)
    if inst.kei_electrobank_converting then
        return
    end
    -- Container:itemlose uses `prev_item` (unlike itemget, which uses
    -- `item`). Accept both names so taking a battery always tears down the
    -- charging state.
    local item = data ~= nil and (data.item or data.prev_item) or nil
    if not IsEmptyElectrobank(item) and not IsFullElectrobank(item) then
        return
    end

    SetChargerContentsState(inst, 0)

    StopChargerPostTask(inst)
    StopChargerTask(inst)
    if inst.kei_electrobank_pre_task ~= nil then
        inst.kei_electrobank_pre_task:Cancel()
        inst.kei_electrobank_pre_task = nil
    end
    if not inst.kei_electrobank_loading then
        SetChargerMeter(inst, 0)
    end
    inst.kei_electrobank_pre_done = false
    inst.kei_electrobank_powered = false
    inst.kei_power_consumption = 0
    -- A completed battery may be removed, after which the empty charger is
    -- available for the next battery. Removal has no separate animation.
    DisableChargerOpening(inst)
    SetChargerAnimation(inst, "off")
    Power.RefreshAll(0)
end

local function SetChargerPowered(inst, powered)
    powered = powered == true
    inst._kei_powered:set(powered)
    inst.kei_electrobank_powered = powered
    if powered then
        if inst.kei_electrobank_power_loss_task ~= nil then
            inst.kei_electrobank_power_loss_task:Cancel()
            inst.kei_electrobank_power_loss_task = nil
        end
        -- Do not require an existing charge task here.  The normal recovery
        -- path is stop -> node powered -> start a fresh task and working loop.
        ReevaluateChargerWorkState(inst)
    else
        -- RefreshCircuit may update several endpoints in one pass. Defer the
        -- final stop check by one tick so a charger that is immediately
        -- powered again is not left in stop by an intermediate state.
        if inst.kei_electrobank_power_loss_task == nil then
            inst.kei_electrobank_power_loss_task = inst:DoTaskInTime(0, function(entity)
                entity.kei_electrobank_power_loss_task = nil
                if entity:IsValid() and not entity.kei_electrobank_powered then
                    ReevaluateChargerWorkState(entity)
                end
            end)
        end
    end
end

local function OnBatteryLevelDirty(inst)
    inst.kei_power_battery_level = inst._kei_battery_level:value()
    SetBatteryVisual(inst)
end

local function OnPowerStateDirty(inst)
    if inst.kei_power_is_charger then
        QueueChargerAnimationSync(inst)
        return
    end
    if inst._kei_powered:value() then
        SetDeviceAnimation(inst, true)
    else
        SetDeviceAnimation(inst, false)
    end
end

local function DeviceOnSave(inst, data)
    data.powered = inst._kei_powered:value()
    if (inst.kei_power_battery_capacity or 0) > 0 then
        data.battery_level = inst.kei_power_battery_level or 0
    end
    Power.SaveConnections(inst, data)
end

local function DeviceOnLoad(inst, data)
    if data ~= nil and data.battery_level ~= nil then
        inst.kei_power_battery_level = math.max(0, math.min(
            inst.kei_power_battery_capacity or 0, data.battery_level))
        if inst._kei_battery_level ~= nil then
            inst._kei_battery_level:set(inst.kei_power_battery_level)
        end
        SetBatteryVisual(inst)
    end
    if data ~= nil and data.powered then
        inst:DoTaskInTime(0, function(entity)
            if entity:IsValid() then
                entity:SetPowerState(true)
            end
        end)
    end
end

local function RestoreConnections(inst, newents, data)
    Power.LoadConnections(inst, newents, data)
end

local function OnDeviceHammered(inst)
    -- Remove every logical connection and all of its generated visual pieces
    -- before handling the device's own contents or deleting the entity.
    -- This applies to generators, ordinary consumers, and the charger.
    Power.DisconnectAll(inst)
    if inst.kei_power_is_charger then
        StopChargerTask(inst)
        StopChargerPostTask(inst)
        if inst.kei_electrobank_pre_task ~= nil then
            inst.kei_electrobank_pre_task:Cancel()
            inst.kei_electrobank_pre_task = nil
        end
        if inst.components.container ~= nil then
            inst.components.container:DropEverything()
        end
    end
    inst:Remove()
end

local function PlayBatteryHammerAnimation(inst)
    -- Use the battery's dedicated hit animation, then restore the current
    -- power-state loop after the one-shot animation finishes.
    if inst._kei_hammer_speed_task ~= nil then
        inst._kei_hammer_speed_task:Cancel()
        inst._kei_hammer_speed_task = nil
    end

    inst.AnimState:SetDeltaTimeMultiplier(BATTERY_HAMMER_ANIM_SPEED)
    inst.AnimState:PlayAnimation("on_pre", false)
    inst.AnimState:PushAnimation(
        inst._kei_powered:value() and inst.kei_power_work_animation
            or inst.kei_power_idle_animation,
        true
    )

    local duration = inst.AnimState:GetCurrentAnimationLength()
    inst._kei_hammer_speed_task = inst:DoTaskInTime(
        math.max(FRAMES, duration / BATTERY_HAMMER_ANIM_SPEED),
        function(entity)
            entity._kei_hammer_speed_task = nil
            if entity:IsValid() then
                entity.AnimState:SetDeltaTimeMultiplier(1)
            end
        end
    )
end

local function OnBatteryWorked(inst)
    PlayBatteryHammerAnimation(inst)
    if inst._kei_work_event ~= nil then
        inst._kei_work_event:push()
    end
end

local function MakePowerDevice(prefab, bank, build, tags, config, on_work)
    config = config or {}
    local assets = { Asset("ANIM", "anim/" .. build .. ".zip") }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeObstaclePhysics(inst, 0.42)
        inst.Physics:SetDontRemoveOnSleep(true)
        inst:SetDeploySmartRadius(0.5)
        inst.Transform:SetEightFaced()

        inst.AnimState:SetBank(bank)
        inst.AnimState:SetBuild(build)
        inst.kei_power_idle_animation = config.idle_animation or "off"
        inst.kei_power_work_animation = config.work_animation
            or inst.kei_power_idle_animation
        inst.kei_power_battery_full_animation = config.battery_full_animation
        inst.kei_power_battery_empty_animation = config.battery_empty_animation
        inst.kei_power_set_battery_visual = SetBatteryVisual
        inst.AnimState:PlayAnimation(inst.kei_power_idle_animation, true)
        -- Enlarge only the rendered device.  Physics remains the same
        -- alchemy-engine-sized obstacle created above.
        inst.AnimState:SetScale(DEVICE_VISUAL_SCALE, DEVICE_VISUAL_SCALE)

        inst:AddTag("structure")
        inst:AddTag("kei_power_device")
        inst:AddTag("kei_power_node")
        inst.kei_power_node_type = "device"
        for _, tag in ipairs(tags) do
            inst:AddTag(tag)
        end

        inst.kei_power_device = inst
        inst.kei_power_generation = config.power_generation or 0
        inst.kei_power_consumption = config.power_consumption or 0
        inst.kei_power_battery_capacity = config.battery_capacity or 0
        inst.kei_power_battery_level = config.battery_initial
            or inst.kei_power_battery_capacity
        inst.kei_power_fuel_type = config.fuel_type
        inst.kei_power_fuel_rate = config.fuel_rate or 0
        inst.kei_power_work_signal = config.default_work_signal ~= false
        inst.kei_power_battery_full_build = config.battery_full_build
        inst.kei_power_battery_empty_build = config.battery_empty_build
        inst.kei_power_is_charger = config.is_charger == true
        if inst.kei_power_is_charger then
            inst.kei_power_idle_animation = "off"
            inst.kei_power_work_animation = "working_loop"
            -- An empty charger must not draw power.  Demand is enabled only
            -- after an empty mobile battery has finished the insert animation.
            inst.kei_power_consumption = 0
        end
        if inst.kei_power_is_charger then
            inst.kei_electrobank_power = config.power_consumption
                or Power.ELECTROBANK_CHARGER_POWER
            inst.kei_electrobank_charge_progress = 0
            inst.kei_electrobank_pre_done = false
            inst.kei_electrobank_powered = false
            inst._kei_charger_animation = net_string(
                inst.GUID,
                prefab .. "._charger_animation",
                "keichargeranimationdirty"
            )
            inst._kei_charger_progress = net_float(
                inst.GUID,
                prefab .. "._charger_progress",
                "keichargerprogressdirty"
            )
            inst._kei_charger_pause = net_event(
                inst.GUID,
                prefab .. "._charger_pause",
                "keichargerpausedirty"
            )
            inst._kei_charger_resume = net_event(
                inst.GUID,
                prefab .. "._charger_resume",
                "keichargerresumeddirty"
            )
            inst._kei_charger_progress:set(0)
            inst._kei_charger_contents = net_tinybyte(
                inst.GUID,
                prefab .. "._contents",
                "keichargercontentsdirty"
            )
            inst._kei_charger_contents:set(0)
        end
        inst._kei_powered = net_bool(inst.GUID, prefab .. "._powered", "keipowerstatedirty")
        if (config.battery_capacity or 0) > 0 then
            inst._kei_battery_level = net_float(inst.GUID, prefab .. "._battery_level", "keibatteryleveldirty")
            inst._kei_battery_level:set(inst.kei_power_battery_level)
        end
        if on_work ~= nil then
            inst._kei_work_event = net_event(inst.GUID, prefab .. "._work")
        end
        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            inst:ListenForEvent("keipowerstatedirty", OnPowerStateDirty)
            if inst.kei_power_is_charger then
                inst:ListenForEvent("keichargeranimationdirty", OnChargerAnimationDirty)
                inst:ListenForEvent("keichargerprogressdirty", OnChargerProgressDirty)
                inst:ListenForEvent("keichargerpausedirty", OnChargerPauseDirty)
                inst:ListenForEvent("keichargerresumeddirty", OnChargerResumeDirty)
                -- Net variables may already contain the server value before
                -- the dirty listeners are installed. Apply that value
                -- immediately instead of relying on a later dirty event.
                RefreshChargerMeter(inst)
                -- A charger can change from paused to powered without its
                -- animation name changing, so do not rely solely on dirty
                -- events to resume `working_loop`.
                inst._kei_charger_animation_reconcile_task = inst:DoPeriodicTask(
                    0.1,
                    ReconcileChargerAnimation
                )
                -- The initial net value may already be present before the
                -- dirty listener is installed. Refresh once on the next
                -- simulation tick as well, so a newly created client charger
                -- cannot retain an authored/full frame.
                inst:DoTaskInTime(0, RefreshChargerMeter)
            end
            if inst._kei_battery_level ~= nil then
                inst:ListenForEvent("keibatteryleveldirty", OnBatteryLevelDirty)
            end
            if on_work ~= nil then
                inst:ListenForEvent(prefab .. "._work", PlayBatteryHammerAnimation)
            end
            return inst
        end

        inst:AddComponent("inspectable")
        if inst.kei_power_is_charger then
            inst:AddComponent("container")
            inst.components.container:WidgetSetup("kei_electrobank_charger_small")
            DisableChargerOpening(inst)
            inst.components.container.onopenfn = function(entity)
                entity:PushEvent("kei_charger_opened")
            end
            inst.components.container.onclosefn = function(entity)
                entity:PushEvent("kei_charger_closed")
            end
            inst:ListenForEvent("itemget", OnChargerItemGet)
            inst:ListenForEvent("itemlose", OnChargerItemLose)
        end
        if (config.fuel_capacity or 0) > 0 then
            inst:AddComponent("fueled")
            inst.components.fueled.fueltype = config.fuel_type or FUELTYPE.BURNABLE
            inst.components.fueled.accepting = true
            inst.components.fueled:InitializeFuelLevel(config.initial_fuel
                or config.fuel_capacity)
            inst.components.fueled:SetDepletedFn(function(entity)
                Power.RefreshAll(0)
            end)
        end
        Power.RegisterDevice(inst)
        inst:DoTaskInTime(0, function(entity)
            if entity:IsValid() then
                -- Devices no longer inherit connections from nodes on the
                -- same tile.  All device-to-node connections must be made
                -- explicitly with the wire interaction.
                Power.RefreshAll(0)
            end
        end)
        inst:AddComponent("workable")
        inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
        inst.components.workable:SetWorkLeft(3)
        if on_work ~= nil then
            inst.components.workable:SetOnWorkCallback(on_work)
        end
        inst.components.workable:SetOnFinishCallback(OnDeviceHammered)

        inst.SetPowerState = function(entity, powered)
            entity._kei_powered:set(powered == true)
            if entity.kei_power_is_charger then
                SetChargerPowered(entity, powered == true)
            else
                SetDeviceAnimation(entity, powered == true)
            end
        end
        inst.OnSave = DeviceOnSave
        inst.OnLoad = DeviceOnLoad
        inst.OnLoadPostPass = RestoreConnections
        if inst.kei_power_is_charger then
            inst.OnSave = function(entity, data)
                DeviceOnSave(entity, data)
                data.charger_progress = entity.kei_electrobank_charge_progress or 0
                data.charger_pre_done = entity.kei_electrobank_pre_done == true
            end
            inst.OnLoad = function(entity, data)
                DeviceOnLoad(entity, data)
                entity.kei_electrobank_loading = true
                if data ~= nil then
                    entity.kei_electrobank_charge_progress = math.max(0, math.min(
                        1,
                        data.charger_progress or 0
                    ))
                    entity.kei_electrobank_pre_done = data.charger_pre_done == true
                    if entity._kei_charger_progress ~= nil then
                        entity._kei_charger_progress:set(entity.kei_electrobank_charge_progress)
                    end
                end
            end
            inst.OnLoadPostPass = function(entity, newents, data)
                RestoreConnections(entity, newents, data)
                entity:DoTaskInTime(0, function(charger)
                    if not charger:IsValid() then
                        return
                    end
                    if charger.kei_electrobank_pre_task ~= nil then
                        charger.kei_electrobank_pre_task:Cancel()
                        charger.kei_electrobank_pre_task = nil
                    end
                    local battery = GetChargerBattery(charger)
                    SetChargerContentsState(charger, GetChargerContentsState(charger))
                    if IsFullElectrobank(battery) then
                        charger.kei_electrobank_pre_done = false
                        charger.kei_power_consumption = 0
                        DisableChargerOpening(charger)
                        SetChargerAnimation(charger, "on")
                    elseif IsEmptyElectrobank(battery) then
                        DisableChargerOpening(charger)
                        -- A loaded empty battery follows the same state as a
                        -- newly inserted one: start at working_loop, then
                        -- switch to stop if the circuit cannot currently power it.
                        charger.kei_electrobank_pre_done = true
                        SetChargerAnimation(charger, "working_loop")
                        UpdateChargerPowerDemand(charger)
                    else
                        -- A charger without a battery must always show the
                        -- empty loop state, even if an old save contained
                        -- partial charging progress.
                        SetChargerMeter(charger, 0)
                        DisableChargerOpening(charger)
                        SetChargerAnimation(charger, "off")
                    end
                    charger.kei_electrobank_loading = nil
                    Power.RefreshAll(0)
                    if IsEmptyElectrobank(GetChargerBattery(charger)) then
                        ReevaluateChargerWorkState(charger)
                    end
                end)
            end
        end
        return inst
    end

    return Prefab(prefab, fn, assets)
end

local function WireOnHammered(inst)
    if inst:HasTag("kei_power_node") then
        -- A node owns the saved connection table.  Remove its visual
        -- segments before removing the node so no orphaned wire remains.
        Power.DisconnectAll(inst)
        inst:Remove()
        return
    end

    -- Every straight piece and corner belongs to one logical route.  A
    -- hammer hit on any visible piece therefore disconnects and removes the
    -- complete wire between its two endpoint nodes.
    if inst.kei_power_route ~= nil
        and Power.DisconnectRoute(inst.kei_power_route)
    then
        return
    end

    inst:Remove()
end

local function MakeWire(prefab, is_node, wire_kind, visual_build, default_animation, node_type)
    local function fn()
        local inst = CreateEntity()
        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        if is_node then
            -- Use a physics shape as the mouse hit area, while keeping it out
            -- of gameplay collision.  The ground-only mask prevents the
            -- node from blocking characters, items, or other obstacles.
            local physics = inst.entity:AddPhysics()
            physics:SetMass(0)
            physics:SetCollisionGroup(COLLISION.OBSTACLES)
            physics:ClearCollisionMask()
            physics:SetCollisionMask(COLLISION.GROUND)
            physics:SetSphere(POWER_NODE_HIT_RADIUS)
            physics:SetDontRemoveOnSleep(true)
        end

        local default_kind = wire_kind or "power"
        local default_build = visual_build or (default_kind == "signal"
            and "kei_logic_wires"
            or "kei_utilities_electric")
        inst.AnimState:SetBank(default_build)
        inst.AnimState:SetBuild(default_build)
        inst.AnimState:PlayAnimation("None", true)
        inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
        inst.AnimState:SetLayer(LAYER_BACKGROUND)
        inst.AnimState:SetSortOrder(0)
        inst.kei_power_grade = default_build
        inst.kei_power_wire_kind = default_kind
        inst.kei_power_wire_build = default_build
        inst.kei_power_is_node = is_node == true
        inst.kei_power_node_type = is_node and (node_type or default_kind) or nil

        inst:AddTag("kei_power_wire")
        if is_node then
            inst:AddTag("kei_power_node")
            inst:AddTag("inspectable")
        end
        inst._kei_power_grade = net_hash(inst.GUID, prefab .. "._grade", "keipowergradedirty")
        inst._kei_wire_animation = net_hash(inst.GUID, prefab .. "._animation", "keiwiregeometrydirty")
        inst._kei_wire_length = net_float(inst.GUID, prefab .. "._length", "keiwiregeometrydirty")
        inst._kei_wire_rotation = net_float(inst.GUID, prefab .. "._rotation", "keiwiregeometrydirty")
        inst._kei_wire_kind = net_hash(inst.GUID, prefab .. "._kind", "keiwiregeometrydirty")
        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            inst:ListenForEvent("keipowergradedirty", function(entity)
                local grade = entity._kei_power_grade:value()
                if grade ~= nil and grade ~= "" then
                    SetWireKind(entity, entity.kei_power_wire_kind)
                end
            end)
            inst:ListenForEvent("keiwiregeometrydirty", function(entity)
                local animation = entity._kei_wire_animation:value()
                local length = entity._kei_wire_length:value()
                local rotation = entity._kei_wire_rotation:value()
                local kind = entity._kei_wire_kind:value()
                if animation ~= nil and animation ~= "" then
                    SetWireKind(entity, kind)
                    SetWireAnim(entity, animation)
                    -- A connection is made from repeated fixed-size pieces;
                    -- `length` carries the per-grade visual scale.
                    SetWireScale(entity, animation, length)
                    entity.Transform:SetRotation(rotation or 0)
                end
            end)
            return inst
        end

        inst.SetPowerGrade = function(entity, grade)
            entity.kei_power_grade = grade or "kei_utilities_electric"
            entity._kei_power_grade:set(grade or "kei_utilities_electric")
            SetWireKind(entity, entity.kei_power_wire_kind)
        end

        inst.SetWireKind = function(entity, kind)
            entity.kei_power_wire_kind = kind or "power"
            entity._kei_wire_kind:set(kind or "power")
            SetWireKind(entity, kind)
        end

        inst.SetWireGeometry = function(entity, animation, length, rotation)
            SetWireAnim(entity, animation or "LR")
            -- `length` is the per-piece visual scale.  It is not the total
            -- route length; long routes are split into repeated pieces.
            local scale = length or 1
            SetWireScale(entity, animation, scale)
            entity.Transform:SetRotation(rotation or 0)
            entity._kei_wire_animation:set(animation or "None")
            entity._kei_wire_length:set(scale)
            entity._kei_wire_rotation:set(rotation or 0)
            entity.kei_power_wire_animation = animation
            entity.kei_power_wire_length = scale
        end

        inst:SetPowerGrade(default_build)
        inst:SetWireKind(default_kind)
        inst:SetWireGeometry(default_animation or "None", 1)
        inst.OnSave = function(entity, data)
            data.grade = entity.kei_power_grade
        end
        inst.OnLoad = function(entity, data)
            if data ~= nil and data.grade ~= nil then
                entity:SetPowerGrade(data.grade)
            end
            if data ~= nil and data.wire_kind ~= nil then
                entity:SetWireKind(data.wire_kind)
            end
        end

        inst:AddComponent("workable")
        inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
        inst.components.workable:SetWorkLeft(1)
        inst.components.workable:SetOnFinishCallback(WireOnHammered)
        if not is_node then
            inst.persists = false
        else
            inst.OnSave = function(entity, data)
                data.grade = entity.kei_power_grade
                data.wire_kind = entity.kei_power_wire_kind
                Power.SaveConnections(entity, data)
            end
            inst.OnLoadPostPass = RestoreConnections
        end
        return inst
    end

    return Prefab(prefab, fn, WIRE_ASSETS)
end

local prefabs = {
    MakePowerDevice(
        "kei_dev_generator",
        "kei_dev_generator",
        "kei_dev_generator",
        { "kei_power_source" },
        {
            power_generation = Power.TEST_GENERATOR_POWER,
            idle_animation = "off",
            work_animation = "working_loop",
        }
    ),
    MakePowerDevice(
        "kei_batterysm",
        "kei_batterySm",
        "kei_batterysm",
        { "kei_power_consumer" },
        {
            power_consumption = 480,
            idle_animation = "off",
            work_animation = "working_loop",
        },
        OnBatteryWorked
    ),
    MakePowerDevice(
        "kei_electrobank_charger_small",
        "kei_electrobank_charger_small",
        "kei_electrobank_charger_small",
        { "kei_power_consumer" },
        {
            power_consumption = Power.ELECTROBANK_CHARGER_POWER,
            is_charger = true,
            idle_animation = "off",
            work_animation = "working_loop",
        }
    ),
    -- Each ordinary wire grade has its own node prefab and visual build.
    MakeWire("kei_power_wire_node", true, "power", "kei_utilities_electric", "None", "kei_utilities_electric"),
    MakeWire("kei_power_conduct_wire_node", true, "power", "kei_utilities_electric_conduct", "None", "kei_utilities_electric_conduct"),
    MakeWire("kei_power_hiwatt_wire_node", true, "power", "kei_utilities_electric_conduct_hiwatt", "None", "kei_utilities_electric_conduct_hiwatt"),
    MakeWire("kei_power_wire_segment", false),
    MakeWire(
        "kei_logic_wire_node",
        true,
        "signal",
        "kei_logic_wires",
        "None",
        "signal"
    ),
    MakeWire("kei_logic_wire_segment", false, "signal"),
}

return unpack(prefabs)
