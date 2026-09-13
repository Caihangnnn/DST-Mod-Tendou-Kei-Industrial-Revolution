-- Kei 玩家特效生命周期管理器。
--
-- 特效通常由协议处理器创建，但协议状态、玩家实体和网络实体并不总是
-- 同时销毁。所有需要跨帧存在的 Kei 特效都应在这里登记，以便：
--   1. 玩家实体被移除时统一取消任务并删除特效；
--   2. 传送时清空旧特效，避免旧跟随任务继续操作旧位置；
--   3. 特效自然结束时自动解除登记，不保留失效引用。

local KeiEffectManager = {}

local function GetManager(owner, create)
    if owner == nil then
        return nil
    end

    local manager = owner._kei_effect_manager
    if manager ~= nil or not create then
        return manager
    end

    manager = {
        owner = owner,
        entries = {},
        next_id = 0,
        clearing = false,
    }
    owner._kei_effect_manager = manager

    owner:ListenForEvent("onremove", function()
        KeiEffectManager.Clear(owner)
    end)

    if TheWorld ~= nil then
        owner:ListenForEvent("ms_playerjoined", function(_, player)
            if player ~= owner then
                return
            end

            KeiEffectManager.Clear(owner, "player_joined")
            local slots = owner.components ~= nil and owner.components.kei_protocolslots or nil
            if slots ~= nil and slots.ScheduleRefresh ~= nil then
                slots:ScheduleRefresh()
            end
        end, TheWorld)
    end

    return manager
end

local function CancelTask(task)
    if task ~= nil then
        task:Cancel()
    end
end

local function CancelTasks(entry)
    if entry == nil then
        return
    end

    if entry.task ~= nil then
        CancelTask(entry.task)
        entry.task = nil
    end

    for _, task in ipairs(entry.tasks or {}) do
        CancelTask(task)
    end
    entry.tasks = nil
end

local function RunCleanup(entry, reason)
    if entry ~= nil and entry.cleanup ~= nil then
        entry.cleanup(entry, reason)
    end
end

local function Detach(owner, key, remove_fx, reason)
    local manager = GetManager(owner, false)
    if manager == nil then
        return false
    end

    local entry = manager.entries[key]
    if entry == nil then
        return false
    end

    manager.entries[key] = nil
    CancelTasks(entry)
    RunCleanup(entry, reason)

    if remove_fx and entry.fx ~= nil and entry.fx:IsValid() then
        entry.fx:Remove()
    end
    return true
end

local function MakeKey(manager, key)
    if key ~= nil then
        return key
    end
    manager.next_id = manager.next_id + 1
    return "anonymous_" .. tostring(manager.next_id)
end

function KeiEffectManager.Register(owner, fx, key, cleanup)
    if owner == nil or fx == nil then
        return nil
    end

    local manager = GetManager(owner, true)
    key = MakeKey(manager, key)
    if manager.entries[key] ~= nil then
        Detach(owner, key, true, "replace")
    end

    local entry = {
        fx = fx,
        cleanup = cleanup,
    }
    manager.entries[key] = entry

    fx:ListenForEvent("onremove", function()
        if manager.entries[key] == entry then
            manager.entries[key] = nil
            CancelTasks(entry)
            RunCleanup(entry, "fx_removed")
        end
    end)

    return key
end

function KeiEffectManager.RegisterTask(owner, task, key, cleanup)
    if owner == nil or task == nil then
        return nil
    end

    local manager = GetManager(owner, true)
    key = MakeKey(manager, key)
    if manager.entries[key] ~= nil then
        Detach(owner, key, false, "replace")
    end

    manager.entries[key] = {
        task = task,
        cleanup = cleanup,
    }
    return key
end

function KeiEffectManager.SetTask(owner, key, task)
    local manager = GetManager(owner, false)
    local entry = manager ~= nil and manager.entries[key] or nil
    if entry ~= nil then
        entry.task = task
    end
end

function KeiEffectManager.SetTasks(owner, key, tasks)
    local manager = GetManager(owner, false)
    local entry = manager ~= nil and manager.entries[key] or nil
    if entry ~= nil then
        entry.tasks = tasks
    end
end

function KeiEffectManager.AddTask(owner, key, task)
    if task == nil then
        return
    end

    local manager = GetManager(owner, false)
    local entry = manager ~= nil and manager.entries[key] or nil
    if entry == nil then
        return
    end

    entry.tasks = entry.tasks or {}
    entry.tasks[#entry.tasks + 1] = task
end

-- 释放登记，但保留特效实体。用于协议自己的 Disable 已经负责播放退出动画
-- 或删除实体的情况。
function KeiEffectManager.Release(owner, key, reason)
    return Detach(owner, key, false, reason or "release")
end

-- 删除一个登记项及其特效实体。
function KeiEffectManager.Remove(owner, key, reason)
    return Detach(owner, key, true, reason or "remove")
end

-- 清理该玩家登记的全部特效和任务。传送、玩家 onremove、跨世界切换都使用
-- 这个入口，保证旧玩家实体不会把任务带到新位置或新连接。
function KeiEffectManager.Clear(owner, reason)
    local manager = GetManager(owner, false)
    if manager == nil or manager.clearing then
        return
    end

    manager.clearing = true
    local keys = {}
    for key in pairs(manager.entries) do
        keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
        Detach(owner, key, true, reason or "clear")
    end
    manager.clearing = false
end

function KeiEffectManager.Count(owner)
    local manager = GetManager(owner, false)
    if manager == nil then
        return 0
    end

    local count = 0
    for _ in pairs(manager.entries) do
        count = count + 1
    end
    return count
end

return KeiEffectManager
