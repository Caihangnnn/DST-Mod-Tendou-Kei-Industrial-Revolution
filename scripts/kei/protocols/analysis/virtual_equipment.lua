local VirtualEquipment = {}

local VIRTUAL_VIEW_STATE = "_kei_virtual_equipment_view_state"
local VIRTUAL_EVENT_WRAPPERS = "_kei_virtual_event_wrappers"
local VIRTUAL_CONTEXT_STACK = {}

local function IsVirtualEquipment(item)
    return item ~= nil
        and item.HasTag ~= nil
        and item:HasTag("kei_virtual_equipment")
end

local function GetVirtualEquipmentOwner(item)
    local inventoryitem = item ~= nil and item.components ~= nil and item.components.inventoryitem or nil
    return inventoryitem ~= nil and inventoryitem.owner or nil
end

local function IsUsableVirtualEquipment(item, force)
    if item == nil or item.IsValid == nil or not item:IsValid() then
        return false
    end

    local equippable = item.components ~= nil and item.components.equippable or nil
    return equippable ~= nil and (force or equippable:IsEquipped())
end

local function BuildVirtualEquipmentView(owner, focus)
    local view = {}

    local function Add(item, force)
        if not IsUsableVirtualEquipment(item, force) then
            return
        end

        local equipslot = item.components.equippable.equipslot
        if equipslot ~= nil then
            view[equipslot] = item
        end
    end

    Add(focus, true)

    local slots = owner ~= nil and owner.components ~= nil
        and owner.components.kei_protocolslots or nil
    if slots ~= nil then
        Add(slots.virtual_hand_equip, false)
        for _, item in pairs(slots.virtual_equips or {}) do
            Add(item, false)
        end
    end

    return view
end

local function PushVirtualEquipmentView(owner, focus)
    local inventory = owner ~= nil and owner.components ~= nil and owner.components.inventory or nil
    if inventory == nil then
        return nil
    end

    local state = rawget(inventory, VIRTUAL_VIEW_STATE)
    if state == nil then
        state = {
            stack = {},
            original_method = rawget(inventory, "GetEquippedItem"),
            base_method = inventory.GetEquippedItem,
        }
        rawset(inventory, VIRTUAL_VIEW_STATE, state)

        local base_method = state.base_method
        inventory.GetEquippedItem = function(inv, equipslot, ...)
            local current = rawget(inv, VIRTUAL_VIEW_STATE)
            if current ~= nil then
                for index = #current.stack, 1, -1 do
                    local item = current.stack[index][equipslot]
                    if IsUsableVirtualEquipment(item, false)
                        or IsUsableVirtualEquipment(item, true)
                    then
                        return item
                    end
                end
            end
            return base_method(inv, equipslot, ...)
        end
    end

    table.insert(state.stack, BuildVirtualEquipmentView(owner, focus))
    return inventory
end

local function PopVirtualEquipmentView(inventory)
    if inventory == nil then
        return
    end

    local state = rawget(inventory, VIRTUAL_VIEW_STATE)
    if state == nil then
        return
    end

    table.remove(state.stack)
    if #state.stack == 0 then
        if state.original_method == nil then
            inventory.GetEquippedItem = nil
        else
            inventory.GetEquippedItem = state.original_method
        end
        rawset(inventory, VIRTUAL_VIEW_STATE, nil)
    end
end

function VirtualEquipment.WithTemporaryEquipmentView(owner, focus, callback, ...)
    if type(callback) ~= "function" then
        return
    end

    local args = { ... }
    local inventory = PushVirtualEquipmentView(owner, focus)
    table.insert(VIRTUAL_CONTEXT_STACK, { owner = owner, item = focus })
    local results = { pcall(callback, unpack(args)) }

    table.remove(VIRTUAL_CONTEXT_STACK)
    PopVirtualEquipmentView(inventory)

    if not results[1] then
        error(results[2])
    end
    return unpack(results, 2)
end

local function GetActiveVirtualContext()
    return VIRTUAL_CONTEXT_STACK[#VIRTUAL_CONTEXT_STACK]
end

local function AddVirtualEventWrapper(listener, event, callback, source, owner, item, wrapper)
    local wrappers = rawget(listener, VIRTUAL_EVENT_WRAPPERS)
    if wrappers == nil then
        wrappers = {}
        rawset(listener, VIRTUAL_EVENT_WRAPPERS, wrappers)
    end
    wrappers[#wrappers + 1] = {
        event = event,
        callback = callback,
        source = source,
        wrapper = wrapper,
    }
end

local function InstallVirtualEventHooks()
    if EntityScript == nil or EntityScript._kei_virtual_equipment_event_hooks_installed then
        return
    end
    EntityScript._kei_virtual_equipment_event_hooks_installed = true

    local old_listen = EntityScript.ListenForEvent
    EntityScript.ListenForEvent = function(self, event, callback, source)
        local actual_source = source or self
        local owner = nil
        local item = nil

        if IsVirtualEquipment(self) then
            owner = GetVirtualEquipmentOwner(self)
            if owner ~= nil and actual_source == owner then
                item = self
            end
        else
            local context = GetActiveVirtualContext()
            if context ~= nil and self == context.owner and actual_source == context.owner then
                owner = context.owner
                item = context.item
            end
        end

        if item ~= nil and type(callback) == "function" then
            local original = callback
            local wrapper = function(event_source, data)
                return VirtualEquipment.WithTemporaryEquipmentView(
                    owner,
                    item,
                    original,
                    event_source,
                    data
                )
            end
            AddVirtualEventWrapper(self, event, original, actual_source, owner, item, wrapper)
            return old_listen(self, event, wrapper, source)
        end

        return old_listen(self, event, callback, source)
    end

    local old_remove = EntityScript.RemoveEventCallback
    EntityScript.RemoveEventCallback = function(self, event, callback, source)
        local actual_source = source or self
        local wrappers = rawget(self, VIRTUAL_EVENT_WRAPPERS)
        local removed = false

        if wrappers ~= nil then
            for index = #wrappers, 1, -1 do
                local record = wrappers[index]
                if record.event == event
                    and record.callback == callback
                    and record.source == actual_source
                then
                    old_remove(self, event, record.wrapper, source)
                    table.remove(wrappers, index)
                    removed = true
                end
            end
            if #wrappers == 0 then
                rawset(self, VIRTUAL_EVENT_WRAPPERS, nil)
            end
        end

        if not removed then
            return old_remove(self, event, callback, source)
        end
    end

    local old_remove_all = EntityScript.RemoveAllEventCallbacks
    EntityScript.RemoveAllEventCallbacks = function(self, ...)
        local result = { old_remove_all(self, ...) }
        rawset(self, VIRTUAL_EVENT_WRAPPERS, nil)
        return unpack(result)
    end
end

InstallVirtualEventHooks()

local function GetAddSetter()
    local addsetterfn = addsetter
    if addsetterfn == nil and GLOBAL ~= nil then
        addsetterfn = GLOBAL.addsetter
    end
    return addsetterfn
end

local function RestoreLockedValue(component, field, value)
    local properties = rawget(component, "_")
    local property = properties ~= nil and properties[field] or nil
    if property ~= nil then
        property[1] = value
    else
        rawset(component, field, value)
    end
end

local function LockProperty(component, field, value)
    local addsetterfn = GetAddSetter()
    if addsetterfn ~= nil then
        local properties = rawget(component, "_")
        local property = properties ~= nil and properties[field] or nil
        local oldsetter = property ~= nil and property[2] or nil
        addsetterfn(component, field, function(current_component)
            RestoreLockedValue(current_component, field, value)
            -- Re-run the original setter with the restored value so vanilla
            -- tags and repairability state remain consistent after a blocked
            -- direct assignment.
            if oldsetter ~= nil then
                oldsetter(current_component, value, value)
            end
        end)
    end
end

-- Keep the source durability component available for equipment callbacks (for
-- example, greenamulet consumes a finiteuses charge after crafting), but make
-- the virtual copy's durability immutable.  Some prefabs write through the
-- component methods while others assign current/total directly, so protect
-- both paths here instead of duplicating the workaround in each virtual
-- equipment implementation.
function VirtualEquipment.LockFiniteUses(item)
    if item == nil or item.components == nil then
        return
    end

    local finiteuses = item.components.finiteuses
    if finiteuses == nil or finiteuses.kei_virtual_durability_locked then
        return
    end

    finiteuses.kei_virtual_durability_locked = true

    local locked_current = finiteuses.current
    local locked_total = finiteuses.total

    -- finiteuses is a Class instance with property setters for current/total.
    -- Restore the backing values if another mod writes to either property.
    LockProperty(finiteuses, "current", locked_current)
    LockProperty(finiteuses, "total", locked_total)

    -- Keep the public finiteuses API present, but make every durability
    -- changing operation a no-op.  SetUses is the common path used by Use,
    -- Repair, SetPercent, and OnUsedAsItem; wrapping all of them also covers
    -- mods that call those methods directly or replace the call chain.
    finiteuses.SetUses = function(component)
        RestoreLockedValue(component, "current", locked_current)
    end
    finiteuses.Use = function(component)
        RestoreLockedValue(component, "current", locked_current)
    end
    finiteuses.Repair = function(component)
        RestoreLockedValue(component, "current", locked_current)
    end
    finiteuses.SetPercent = function(component)
        RestoreLockedValue(component, "current", locked_current)
    end
    finiteuses.SetMaxUses = function(component)
        RestoreLockedValue(component, "total", locked_total)
    end
end

-- Keep fuel available to source callbacks, but prevent both active consumption
-- and external fuel changes on virtual equipment.  This also prevents a
-- virtual item accepting fuel only to destroy the offered fuel item without
-- changing its own fuel level.
function VirtualEquipment.LockFueled(item)
    if item == nil or item.components == nil then
        return
    end

    local fueled = item.components.fueled
    if fueled == nil or fueled.kei_virtual_fuel_locked then
        return
    end

    fueled.kei_virtual_fuel_locked = true

    local locked_currentfuel = fueled.currentfuel
    local locked_maxfuel = fueled.maxfuel

    if fueled.StopConsuming ~= nil then
        fueled:StopConsuming()
    end

    LockProperty(fueled, "currentfuel", locked_currentfuel)
    LockProperty(fueled, "maxfuel", locked_maxfuel)

    fueled.MakeEmpty = function(component)
        RestoreLockedValue(component, "currentfuel", locked_currentfuel)
    end
    fueled.ChangeSection = function(component)
        RestoreLockedValue(component, "currentfuel", locked_currentfuel)
    end
    fueled.InitializeFuelLevel = function(component)
        RestoreLockedValue(component, "currentfuel", locked_currentfuel)
        RestoreLockedValue(component, "maxfuel", locked_maxfuel)
    end
    fueled.SetPercent = function(component)
        RestoreLockedValue(component, "currentfuel", locked_currentfuel)
    end
    fueled.DoDelta = function(component)
        RestoreLockedValue(component, "currentfuel", locked_currentfuel)
    end
    fueled.DoUpdate = function(component)
        RestoreLockedValue(component, "currentfuel", locked_currentfuel)
    end
    fueled.LongUpdate = function(component)
        RestoreLockedValue(component, "currentfuel", locked_currentfuel)
    end
    fueled.TakeFuelItem = function(component)
        return false
    end
    fueled.StartConsuming = function(component)
        component.consuming = false
        component.task = nil
    end
end

-- Keep perishable available to source callbacks and UI code, but stop its
-- timer and make its perish values immutable.  Perish is blocked as well so a
-- previously empty component cannot replace/remove a virtual equipment item.
function VirtualEquipment.LockPerishable(item)
    if item == nil or item.components == nil then
        return
    end

    local perishable = item.components.perishable
    if perishable == nil or perishable.kei_virtual_perishable_locked then
        return
    end

    perishable.kei_virtual_perishable_locked = true

    local locked_perishtime = perishable.perishtime
    local locked_remaining = perishable.perishremainingtime

    LockProperty(perishable, "perishtime", locked_perishtime)
    LockProperty(perishable, "perishremainingtime", locked_remaining)

    if perishable.StopPerishing ~= nil then
        perishable:StopPerishing()
    end

    perishable.Dilute = function(component)
        RestoreLockedValue(component, "perishtime", locked_perishtime)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
    perishable.AddTime = function(component)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
    perishable.SetPerishTime = function(component)
        RestoreLockedValue(component, "perishtime", locked_perishtime)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
    perishable.SetNewMaxPerishTime = function(component)
        RestoreLockedValue(component, "perishtime", locked_perishtime)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
    perishable.SetPercent = function(component)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
    perishable.ReducePercent = function(component)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
    perishable.StartPerishing = function(component)
        component.updatetask = nil
    end
    perishable.Perish = function(component)
        RestoreLockedValue(component, "perishtime", locked_perishtime)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
    perishable.LongUpdate = function(component)
        RestoreLockedValue(component, "perishtime", locked_perishtime)
        RestoreLockedValue(component, "perishremainingtime", locked_remaining)
    end
end

-- Apply every virtual durability rule in one place so armor and hand virtual
-- equipment cannot accidentally diverge.
function VirtualEquipment.LockDurability(item)
    VirtualEquipment.LockFiniteUses(item)
    VirtualEquipment.LockFueled(item)
    VirtualEquipment.LockPerishable(item)
end

local function GuardCallback(equippable, field)
    local callback = equippable[field]
    if callback == nil then return false end

    equippable[field] = function(item, owner, from_ground)
        local builder = owner ~= nil and owner.components ~= nil and owner.components.builder or nil
        local previous_mod = builder ~= nil and builder.ingredientmod or 1
        local ok, result1, result2, result3 = pcall(callback, item, owner, from_ground)

        -- Keep discounts from real equipment, but remove reductions introduced
        -- by this virtual equipment callback.
        local current_mod = builder ~= nil and builder.ingredientmod or previous_mod
        if builder ~= nil and current_mod < previous_mod then
            builder.ingredientmod = previous_mod
        end
        if not ok then error(result1) end
        return result1, result2, result3
    end
    return true
end

function VirtualEquipment.GuardBuildDiscount(item)
    if TUNING.KEI_VIRTUAL_EQUIPMENT_BUILD_DISCOUNT ~= false
        or item == nil
        or item.components == nil
        or item.components.equippable == nil
        or item.components.equippable.kei_build_discount_guarded
    then
        return
    end

    local equippable = item.components.equippable
    local guarded = GuardCallback(equippable, "onequipfn")
    guarded = GuardCallback(equippable, "onequiptomodelfn") or guarded
    equippable.kei_build_discount_guarded = guarded or nil
end

return VirtualEquipment
