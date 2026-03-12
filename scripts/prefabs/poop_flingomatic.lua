require "prefabutil"

local assets =
{
    Asset("ANIM", "anim/poop_flingomatic.zip"),
    Asset("ANIM", "anim/ui_chest_3x3.zip"),
    Asset("ATLAS", "minimap/poop_flingomatic.xml"),
    Asset("IMAGE", "minimap/poop_flingomatic.tex"),
}

local prefabs =
{
    "fertilizer_projectile",
    "collapse_small",
}

local easing = require("easing")
local MAX_FARM_NUTRIENT = 100
local POOPFLING_DEBUG = rawget(_G, "POOPFLING_DEBUG") == true

local function DebugLog(fmt, ...)
    if POOPFLING_DEBUG then
        print(string.format("[PoopFlingDBG] " .. fmt, ...))
    end
end

local function GetFarmTileCenterPoint(target)
    if target == nil then
        return nil
    end

    local x, y, z = target.Transform:GetWorldPosition()
    if not TheWorld.Map:IsFarmableSoilAtPoint(x, y, z) then
        return nil
    end

    local center_x, center_y, center_z = TheWorld.Map:GetTileCenterPoint(x, 0, z)
    if center_x == nil or center_z == nil then
        return nil
    end

    return Vector3(center_x, center_y or 0, center_z)
end

local function GetFarmTileData(target)
    if target == nil or TheWorld.components.farming_manager == nil then
        return nil
    end

    local x, y, z = target.Transform:GetWorldPosition()
    if not TheWorld.Map:IsFarmableSoilAtPoint(x, y, z) then
        return nil
    end

    local tile_x, tile_z = TheWorld.Map:GetTileCoordsAtPoint(x, y, z)
    local nutrient_1, nutrient_2, nutrient_3 =
        TheWorld.components.farming_manager:GetTileNutrients(tile_x, tile_z)

    return tile_x, tile_z, nutrient_1, nutrient_2, nutrient_3
end

local function GetFarmTileKey(tile_x, tile_z)
    return tostring(tile_x) .. ":" .. tostring(tile_z)
end

local function GetPendingTileData(inst, tile_key)
    if inst.pending_tile_additions == nil then
        inst.pending_tile_additions = {}
    end

    local pending = inst.pending_tile_additions[tile_key]
    if pending == nil then
        pending = { 0, 0, 0 }
        inst.pending_tile_additions[tile_key] = pending
    end

    return pending
end

local function GetProjectedTileNutrients(inst, tile_key, nutrient_1, nutrient_2, nutrient_3)
    local pending = GetPendingTileData(inst, tile_key)
    return {
        (nutrient_1 or 0) + (pending[1] or 0),
        (nutrient_2 or 0) + (pending[2] or 0),
        (nutrient_3 or 0) + (pending[3] or 0),
    }, pending
end

local function ApplyPendingReservation(inst, tile_key, add_1, add_2, add_3, sign)
    if tile_key == nil then
        return
    end

    local pending = GetPendingTileData(inst, tile_key)
    local factor = sign or 1

    pending[1] = math.max(0, (pending[1] or 0) + (add_1 or 0) * factor)
    pending[2] = math.max(0, (pending[2] or 0) + (add_2 or 0) * factor)
    pending[3] = math.max(0, (pending[3] or 0) + (add_3 or 0) * factor)

    DebugLog(
        "tile=%s sign=%d add=(%d,%d,%d) pending=(%d,%d,%d)",
        tostring(tile_key),
        factor,
        add_1 or 0,
        add_2 or 0,
        add_3 or 0,
        pending[1] or 0,
        pending[2] or 0,
        pending[3] or 0
    )

    if pending[1] <= 0 and pending[2] <= 0 and pending[3] <= 0 then
        inst.pending_tile_additions[tile_key] = nil
    end
end

local function GetPendingTargetShots(inst, target)
    if target == nil then
        return 0
    end

    if inst.pending_target_shots == nil then
        inst.pending_target_shots = {}
    end

    return inst.pending_target_shots[target.GUID] or 0
end

local function ApplyPendingTargetShot(inst, target, delta)
    if target == nil then
        return
    end

    if inst.pending_target_shots == nil then
        inst.pending_target_shots = {}
    end

    local guid = target.GUID
    local next_value = math.max(0, (inst.pending_target_shots[guid] or 0) + (delta or 0))
    if next_value <= 0 then
        inst.pending_target_shots[guid] = nil
    else
        inst.pending_target_shots[guid] = next_value
    end
end

local function GetActiveFillPlan(inst, target, create_if_missing)
    local tile_x, tile_z, nutrient_1, nutrient_2, nutrient_3 = GetFarmTileData(target)
    if tile_x == nil then
        return nil, nil
    end

    inst.active_fill_targets = inst.active_fill_targets or {}

    local key = GetFarmTileKey(tile_x, tile_z)
    local plan = inst.active_fill_targets[key]

    if plan == nil and create_if_missing
        and (nutrient_1 == 0 or nutrient_2 == 0 or nutrient_3 == 0) then
        local zero_at_start = {
            nutrient_1 == 0,
            nutrient_2 == 0,
            nutrient_3 == 0,
        }

        local initial_index = nil
        for i = 1, 3 do
            if zero_at_start[i] then
                initial_index = i
                break
            end
        end

        plan = {
            -- 仅追踪“本轮启动时为 0”的养分项。
            nutrients = zero_at_start,
            current_nutrient_index = initial_index,
            planned_nutrient_index = nil,
            planned_item_prefab = nil,
            planned_shots_remaining = 0,
        }
        inst.active_fill_targets[key] = plan
    end

    if plan == nil then
        return nil, nil
    end

    local actual_values = { nutrient_1 or 0, nutrient_2 or 0, nutrient_3 or 0 }
    local nutrient_values, pending = GetProjectedTileNutrients(inst, key, nutrient_1, nutrient_2, nutrient_3)
    local requested_nutrients = { false, false, false }

    local current_index = plan.current_nutrient_index
    local wait_for_inflight_settle = current_index ~= nil
        and nutrient_values[current_index] >= MAX_FARM_NUTRIENT
        and (pending[current_index] or 0) > 0

    -- 切换当前养分前必须满足：在途该项为 0，且该项实际值已满。
    -- 若在途未清空，则继续锁定当前项等待命中结算，避免过早切项。
    if current_index ~= nil and not wait_for_inflight_settle
        and nutrient_values[current_index] >= MAX_FARM_NUTRIENT then
        if (pending[current_index] or 0) > 0 then
            -- 仍有在途，先等待，不切项。
        elseif actual_values[current_index] >= MAX_FARM_NUTRIENT then
            plan.planned_nutrient_index = nil
            plan.planned_item_prefab = nil
            plan.planned_shots_remaining = 0
            current_index = nil
        else
            -- 在途已清空但实际未满（可能被角色挡住），保留当前项并重算预算。
            plan.planned_nutrient_index = nil
            plan.planned_item_prefab = nil
            plan.planned_shots_remaining = 0
        end
    end

    if current_index == nil
        or not plan.nutrients[current_index]
        or (nutrient_values[current_index] >= MAX_FARM_NUTRIENT and not wait_for_inflight_settle) then
        current_index = nil
        for i = 1, 3 do
            -- 只处理启动时为 0 的项。
            if plan.nutrients[i]
                and nutrient_values[i] < MAX_FARM_NUTRIENT then
                current_index = i
                break
            end
        end
        plan.current_nutrient_index = current_index

        if plan.planned_nutrient_index ~= current_index then
            plan.planned_nutrient_index = nil
            plan.planned_item_prefab = nil
            plan.planned_shots_remaining = 0
        end
    end

    if current_index ~= nil then
        requested_nutrients[current_index] = true
    end

    if not requested_nutrients[1]
        and not requested_nutrients[2]
        and not requested_nutrients[3] then
        inst.active_fill_targets[key] = nil
        return nil, nil
    end

    return plan, requested_nutrients
end

-- 判断一个农作物实体是否存在"缺养分"。
-- 这里调用 CycleNutrientsAtPoint 的 test_only 模式：
-- true 表示只检测，不真正扣减/修改地块养分。
local function IsFarmPlantNeedingNutrients(inst, target)
    -- 目标不存在时，无法继续判定，直接返回 false。
    if target == nil
        -- 不是农作物实体时，不参与农作物缺肥检测。
        or not target:HasTag("farm_plant")
        -- 世界没有 farming_manager 时，无法读取地块营养。
        or TheWorld.components.farming_manager == nil then
        -- 任一前置条件不满足都视为“不需要/不能判定施肥”。
        return false
    end

    local _, requested_nutrients = GetActiveFillPlan(inst, target, true)
    return requested_nutrients ~= nil
end

-- 判断一个农田土壤实体是否需要施肥。
-- 当前策略是：三项养分任意一项等于 0 就认为需要施肥。
local function IsFarmSoilNeedingNutrients(inst, target)
    -- 目标为空时无法检测。
    if target == nil
        -- 只对 soil 标签实体执行“空地块缺肥”逻辑。
        or not target:HasTag("soil")
        -- 没有 farming_manager 时无法查询养分。
        or TheWorld.components.farming_manager == nil then
        -- 条件不满足则不当作缺肥目标。
        return false
    end

    local _, requested_nutrients = GetActiveFillPlan(inst, target, true)
    return requested_nutrients ~= nil
end

-- 获取目标所在地块的"缺项掩码"。
-- 返回 {bool,bool,bool}，分别表示三项养分是否为 0。
-- 若目标不是有效农田，返回 nil，调用方可降级为普通选肥逻辑。
local function GetTargetMissingNutrients(inst, target, create_if_missing)
    -- 目标为空或管理器不存在时无法构建缺项信息。
    if target == nil or TheWorld.components.farming_manager == nil then
        return nil
    end

    local _, requested_nutrients = GetActiveFillPlan(inst, target, create_if_missing ~= false)
    return requested_nutrients
end

-- 给某个肥料打分，用于按缺项智能选肥。
-- 评分原则：
-- 1) 能覆盖缺项越多越好（matched）
-- 2) 额外补到不缺项越少越好（extra）
-- 3) 总养分量略小者优先（避免重肥总是压过单项肥）
local function ScoreFertilizerForNeeds(item, missing_nutrients)
    -- 没有物品、没有 fertilizer 组件、或没有缺项信息时无法评分。
    if item == nil
        or item.components.fertilizer == nil
        or missing_nutrients == nil then
        return nil
    end

    -- 读取该肥料定义的三项营养增量。
    local nutrients = item.components.fertilizer.nutrients
    -- 缺少营养表时不参与评分。
    if nutrients == nil then
        return nil
    end

    local target_index = nil
    for i = 1, 3 do
        if missing_nutrients[i] then
            target_index = i
            break
        end
    end
    if target_index == nil then
        return nil
    end

    local target_amount = nutrients[target_index] or 0
    if target_amount <= 0 then
        return nil
    end

    local extra = 0
    local total = 0

    -- 逐项遍历三种营养，统计评分要素。
    for i = 1, 3 do
        -- 安全读取单项养分，nil 视为 0。
        local amount = nutrients[i] or 0
        -- 累加总养分，用于轻微惩罚“过重肥料”。
        total = total + amount

        if amount > 0 and i ~= target_index then
            extra = extra + 1
        end
    end

    -- 单养分模式：优先该养分增量更高（更快补满），其次减少额外补项。
    return target_amount * 100 - extra * 10 - total * 0.01
end

------------------------------------------------------------
-- 常量
------------------------------------------------------------
local FERTILIZATION_RANGE = 20
local N_MAX               = 30
local T_MAX               = 0.12
local CHECK_FERT_TIME     = 0.15
local INITIAL_CHECK_DELAY = 0.05
local PROJECTILE_LAUNCH_DELAY = 0.01
local PROJECTILE_BASE_SPEED = 30
local PROJECTILE_SPEED_DELTA = 28
local PROJECTILE_GRAVITY = -70
--建筑的工作范围显示
-- local PLACER_SCALE = 1.77
-- local FERTILIZATION_RANGE = 20

-- 这个值是 DST 的范围圈贴图默认半径（实测约 11）
-- Fire Flingomatic、Ice Fling 等 mod 都普遍用 11 作为基准
local BASE_RANGE = 11   

local PLACER_SCALE = FERTILIZATION_RANGE / BASE_RANGE


local function OnEnableHelper(inst, enabled)
    if enabled then
        if inst.helper == nil then
            inst.helper = CreateEntity()

            inst.helper.entity:SetCanSleep(false)
            inst.helper.persists = false

            inst.helper.entity:AddTransform()
            inst.helper.entity:AddAnimState()

            inst.helper:AddTag("CLASSIFIED")
            inst.helper:AddTag("NOCLICK")
            inst.helper:AddTag("placer")

            inst.helper.Transform:SetScale(PLACER_SCALE, PLACER_SCALE, PLACER_SCALE)

            inst.helper.AnimState:SetBank("poop_flingomatic")
            inst.helper.AnimState:SetBuild("poop_flingomatic")
            inst.helper.AnimState:PlayAnimation("placer")
            inst.helper.AnimState:SetLightOverride(1)
            inst.helper.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
            inst.helper.AnimState:SetLayer(LAYER_BACKGROUND)
            inst.helper.AnimState:SetSortOrder(1)
            inst.helper.AnimState:SetAddColour(0, .2, .5, 0)

            inst.helper.entity:SetParent(inst.entity)
        end
    elseif inst.helper ~= nil then
        inst.helper:Remove()
        inst.helper = nil
    end
end

------------------------------------------------------------
-- 发射抛射物
------------------------------------------------------------
local function LaunchProjectile(inst, target, item, reservation, reserve_target_shot)
    -- 记录发射器位置作为抛射物起点。
    local x, y, z = inst.Transform:GetWorldPosition()
    -- 农田目标优先瞄准地块中心，减少打在边缘导致的命中偏差。
    local targetpos = GetFarmTileCenterPoint(target) or target:GetPosition()
    local tile_x, tile_z = GetFarmTileData(target)
    local tile_key = tile_x ~= nil and GetFarmTileKey(tile_x, tile_z) or nil

    if reservation ~= nil then
        tile_x = reservation.tile_x
        tile_z = reservation.tile_z
        tile_key = reservation.tile_key
    end

    -- 延迟一点点发射，让开火动画与音效更自然。
    inst:DoTaskInTime(PROJECTILE_LAUNCH_DELAY, function()
        -- 发射前再次确认发射器仍然有效。
        if not inst:IsValid() then
            return
        end

        -- 生成抛射物实体。
        local projectile = SpawnPrefab("fertilizer_projectile")
        -- 抛射物放在机器当前位置。
        projectile.Transform:SetPosition(x, y, z)
        -- 缩小抛射物视觉尺寸，避免遮挡。
        projectile.AnimState:SetScale(0.5, 0.5)

        -- 给抛射物绑定目标，供命中时读取。
        projectile.target = target ~= nil and target:IsValid() and target or nil
        projectile.target_tile_x = tile_x
        projectile.target_tile_z = tile_z
        projectile.pending_tile_key = tile_key
        projectile.pending_target_guid = reserve_target_shot and target ~= nil and target.GUID or nil
        projectile.launcher = inst
        projectile.reserved_add_1 = reservation ~= nil and (reservation.add_1 or 0) or 0
        projectile.reserved_add_2 = reservation ~= nil and (reservation.add_2 or 0) or 0
        projectile.reserved_add_3 = reservation ~= nil and (reservation.add_3 or 0) or 0
        -- 给抛射物绑定“肥料实体”，供命中时读取 nutrients。
        projectile.item   = item

        -- 尝试复用物品动画，让飞出去的是“对应肥料外观”。
        local dstring = item.GetDebugString and item:GetDebugString()
        if dstring then
            local bank, build, anim =
                string.match(dstring, "AnimState: bank: (.*) build: (.*) anim: (.*) anim")
            if bank and build and anim then
                -- 特殊 bank 修正，避免某些数值 bank 导致动画异常。
                if bank == "FROMNUM" then
                    bank = "birdegg"
                end
                -- 应用读取到的 bank/build/anim。
                projectile.AnimState:SetBank(bank)
                projectile.AnimState:SetBuild(build)
                projectile.AnimState:PlayAnimation(anim, false)
                -- 把动画时间拉到末尾，避免飞行过程出现不合适帧。
                projectile.AnimState:SetTime(
                    projectile.AnimState:GetCurrentAnimationLength()
                )
            end
        end

        -- 计算水平位移向量。
        local dx = targetpos.x - x
        local dz = targetpos.z - z
        -- 计算平面距离平方，供速度插值使用。
        local rangesq = dx * dx + dz * dz
        -- 距离越远速度越快，距离越近速度越慢。
        local speed = easing.linear(
            rangesq,
            PROJECTILE_BASE_SPEED,
            PROJECTILE_SPEED_DELTA,
            FERTILIZATION_RANGE * FERTILIZATION_RANGE
        )

        -- 设置抛射物水平速度。
        projectile.components.complexprojectile:SetHorizontalSpeed(speed)
        -- 重力提高（更负）用于压低弹道，避免“喷得更高”的观感。
        projectile.components.complexprojectile:SetGravity(PROJECTILE_GRAVITY)
        -- 执行发射。
        projectile.components.complexprojectile:Launch(targetpos, inst, inst)
    end)
end

------------------------------------------------------------
-- 从容器中取一个可用物品（只读）
------------------------------------------------------------
-- 为当前目标挑选最匹配的肥料：
-- 1) 先读取目标地块缺项。
-- 2) 遍历容器内所有肥料并评分。
-- 3) 返回分数最高的肥料。
local function GetBestItemForTarget(inst, target)
    -- 容器不存在时无法选肥。
    if not inst.components.container then
        return nil
    end

    local function FindBestItemForNeeds(needs)
        local best_item = nil
        local best_score = nil

        for _, v in pairs(inst.components.container.slots) do
            if v and v:IsValid() and v.components.fertilizer then
                local score = ScoreFertilizerForNeeds(v, needs)
                if score ~= nil and (best_score == nil or score > best_score) then
                    best_item = v
                    best_score = score
                end
            end
        end

        return best_item
    end

    -- 获取目标地块缺项掩码。
    local missing_nutrients = GetTargetMissingNutrients(inst, target, false)
    -- 缺项信息不可用时，退化为“拿到第一个可用肥料”。
    if missing_nutrients == nil then
        for _, v in pairs(inst.components.container.slots) do
            if v and v:IsValid() and v.components.fertilizer then
                return v, nil, nil
            end
        end
        return nil
    end

    local plan = select(1, GetActiveFillPlan(inst, target, false))
    local tile_x, tile_z, nutrient_1, nutrient_2, nutrient_3 = GetFarmTileData(target)
    local tile_key = tile_x ~= nil and GetFarmTileKey(tile_x, tile_z) or nil
    local projected_values = tile_key ~= nil
        and select(1, GetProjectedTileNutrients(inst, tile_key, nutrient_1, nutrient_2, nutrient_3))
        or { nutrient_1 or 0, nutrient_2 or 0, nutrient_3 or 0 }

    -- 当当前项没有对应肥料时，直接从本次计划中取消，避免卡住队列。
    for _ = 1, 3 do
        local best_item = FindBestItemForNeeds(missing_nutrients)
        if best_item ~= nil then
            if plan ~= nil and plan.current_nutrient_index ~= nil then
                local idx = plan.current_nutrient_index
                local nutrients = best_item.components.fertilizer.nutrients or { 0, 0, 0 }
                local amount = nutrients[idx] or 0

                if amount <= 0 then
                    best_item = nil
                else
                    local remaining = math.max(0, MAX_FARM_NUTRIENT - (projected_values[idx] or 0))

                    -- 启动喷射前先算清楚该项还需几发；预算耗尽但未补满时自动重算。
                    local need_rebudget = plan.planned_nutrient_index ~= idx
                        or plan.planned_item_prefab ~= best_item.prefab
                        or plan.planned_shots_remaining == nil
                        or plan.planned_shots_remaining <= 0

                    if need_rebudget then
                        plan.planned_nutrient_index = idx
                        plan.planned_item_prefab = best_item.prefab
                        plan.planned_shots_remaining = remaining > 0
                            and math.ceil(remaining / amount)
                            or 0

                        DebugLog(
                            "rebudget tile=%s idx=%d item=%s projected=%d remaining=%d amount=%d shots=%d",
                            tostring(tile_key),
                            idx,
                            tostring(best_item.prefab),
                            projected_values[idx] or 0,
                            remaining,
                            amount,
                            plan.planned_shots_remaining or 0
                        )
                    end

                    -- 在途预占已足够时，本帧不再发射，等待命中回写。
                    if plan.planned_shots_remaining <= 0 then
                        DebugLog(
                            "hold tile=%s idx=%d projected=%d waiting_in_flight",
                            tostring(tile_key),
                            idx,
                            projected_values[idx] or 0
                        )
                        return nil, missing_nutrients, plan
                    end
                end
            end

            if best_item ~= nil then
                return best_item, missing_nutrients, plan
            end
        end

        if plan == nil or plan.current_nutrient_index == nil then
            break
        end

        local blocked_index = plan.current_nutrient_index
        plan.nutrients[blocked_index] = false
        plan.current_nutrient_index = nil
        plan.planned_nutrient_index = nil
        plan.planned_item_prefab = nil
        plan.planned_shots_remaining = 0

        missing_nutrients = GetTargetMissingNutrients(inst, target, false)
        if missing_nutrients == nil then
            break
        end
    end

    return nil
end

local function BuildReservationForShot(inst, target, item, requested_nutrients)
    if item == nil or item.components.fertilizer == nil then
        return nil
    end

    local tile_x, tile_z, nutrient_1, nutrient_2, nutrient_3 = GetFarmTileData(target)
    if tile_x == nil then
        return nil
    end

    local tile_key = GetFarmTileKey(tile_x, tile_z)
    local pending = GetPendingTileData(inst, tile_key)
    local item_nutrients = item.components.fertilizer.nutrients or { 0, 0, 0 }
    local current_values = { nutrient_1 or 0, nutrient_2 or 0, nutrient_3 or 0 }

    local add_1, add_2, add_3 = 0, 0, 0
    local add_values = { add_1, add_2, add_3 }

    for i = 1, 3 do
        if requested_nutrients ~= nil and requested_nutrients[i] then
            local projected = current_values[i] + (pending[i] or 0)
            local remaining = math.max(0, MAX_FARM_NUTRIENT - projected)
            add_values[i] = math.max(0, math.min(item_nutrients[i] or 0, remaining))
        end
    end

    add_1, add_2, add_3 = add_values[1], add_values[2], add_values[3]
    if add_1 <= 0 and add_2 <= 0 and add_3 <= 0 then
        return nil
    end

    return {
        tile_x = tile_x,
        tile_z = tile_z,
        tile_key = tile_key,
        add_1 = add_1,
        add_2 = add_2,
        add_3 = add_3,
    }
end


-- 从容器里消费 1 份肥料，并返回用于投射的实体。
-- 三种分支：
-- 1) 可堆叠：复制一个同 prefab 投射体，原堆叠减 1。
-- 2) 有耐久：消耗一次耐久，并复制一个同 prefab 投射体。
-- 3) 其他：直接把原物体从容器移出作为投射体。
local function ConsumeItemForProjectile(inst, item)
    -- 物品为空或失效时无法消费。
    if item == nil or not item:IsValid() then
        return nil
    end

    -- 保存返回给发射流程的抛射物物体。
    local projectile_item = nil

    -- 可堆叠肥料：复制一个同 prefab 抛射体，堆叠数量减 1。
    if item.components.stackable ~= nil then
        projectile_item = SpawnPrefab(item.prefab)

        -- 还有余量则只减堆叠，不移除槽位。
        if item.components.stackable.stacksize > 1 then
            item.components.stackable:SetStackSize(
                item.components.stackable.stacksize - 1
            )
        else
            -- 最后一份时，从容器移除并删除原实体。
            inst.components.container:RemoveItem(item, true)
            item:Remove()
        end
    -- 有耐久肥料：消耗一次耐久，并复制一个同 prefab 抛射体。
    elseif item.components.finiteuses ~= nil then
        item.components.finiteuses:Use()
        projectile_item = SpawnPrefab(item.prefab)

        -- 耐久耗尽时，从容器移除并删除原实体。
        if item.components.finiteuses:GetUses() <= 0 then
            inst.components.container:RemoveItem(item, true)
            item:Remove()
        end
    else
        -- 其他类型：直接把原物体从容器拿出来作为抛射体。
        inst.components.container:RemoveItem(item)
        projectile_item = item
    end

    -- 返回抛射流程实际使用的物体。
    return projectile_item
end

------------------------------------------------------------
-- 核心逻辑：施肥
------------------------------------------------------------
local function CheckForFertilization(inst)
    -- 服务器限定
    if not TheWorld.ismastersim then
        return
    end

    -- 已烧毁 / 未开启
    if inst:HasTag("burnt")
        or not inst.components.machine
        or not inst.components.machine.ison then
        return
    end

    -- 容器打开时，绝对不工作（关键修复点）
    if inst.components.container and inst.components.container:IsOpen() then
        return
    end

    -- 容器为空时无需扫描目标，直接跳过整轮。
    if inst.components.container then
        local has_fertilizer = false
        for _, v in pairs(inst.components.container.slots) do
            if v and v:IsValid() and v.components.fertilizer then
                has_fertilizer = true
                break
            end
        end
        if not has_fertilizer then
            return
        end
    end

    -- 获取机器位置，并从范围内收集需要施肥的目标。
    -- 机器中心点，用于范围检索目标。
    local x, y, z = inst.Transform:GetWorldPosition()
    -- 保存本轮要处理的目标实体列表。
    local targets = {}
    local farm_tile_targets = {}
    local farm_targets_by_key = {}
    local farm_target_keys = {}
    local other_targets = {}

    -- 在施肥半径内扫描所有实体。
    for _, v in ipairs(TheSim:FindEntities(x, y, z, inst.fertilization_range)) do
        -- 满足任一条件就加入目标：枯萎采集物、旧 grower 缺肥、新农作物缺肥、soil 有 0 项。
        local is_farm_target = IsFarmPlantNeedingNutrients(inst, v)
            or IsFarmSoilNeedingNutrients(inst, v)

        if is_farm_target then
            local tile_x, tile_z = GetFarmTileData(v)
            if tile_x ~= nil then
                local tile_key = GetFarmTileKey(tile_x, tile_z)
                if not farm_tile_targets[tile_key] then
                    farm_tile_targets[tile_key] = true
                    farm_targets_by_key[tile_key] = v
                    table.insert(farm_target_keys, tile_key)
                end
            end
        elseif (v.components.pickable and v.components.pickable:IsBarren())
            or (v.components.grower and v.components.grower.cycles_left == 0) then
            -- 非农场作物：收集本轮可施肥目标（但要排除已有在飞肥料的）
            if GetPendingTargetShots(inst, v) <= 0 then
                table.insert(other_targets, v)
            end
        end
    end

    -- 农田串行模式：一次仅处理一个地块，当前地块完成后再切换下一个。
    local selected_farm_target = nil
    if #farm_target_keys > 0 then
        if inst.current_farm_tile_key ~= nil then
            selected_farm_target = farm_targets_by_key[inst.current_farm_tile_key]
        end

        if selected_farm_target == nil then
            table.sort(farm_target_keys)
            inst.current_farm_tile_key = farm_target_keys[1]
            selected_farm_target = farm_targets_by_key[inst.current_farm_tile_key]
        end

        if selected_farm_target ~= nil then
            table.insert(targets, selected_farm_target)
        end
    else
        inst.current_farm_tile_key = nil
        for _, v in ipairs(other_targets) do
            table.insert(targets, v)
        end
    end

    if #targets == 0 then
        return
    end

    -- 本轮最多处理 N_MAX 个目标，避免一次性喷射过多导致卡顿。
    local max_targets = math.min(#targets, N_MAX)

    -- 逐个目标安排发射任务。
    for i = 1, max_targets do
        -- 取当前循环目标。
        local target = targets[i]

        -- 在 [0, T_MAX] 时间窗内均匀错开发射，避免同帧集中执行。
        inst:DoTaskInTime((i - 1) * T_MAX / max_targets, function()
            if not inst:IsValid()
                or inst:HasTag("burnt")
                or not inst.components.machine
                or not inst.components.machine.ison then
                return
            end

            -- 二次防御：执行时仍然必须是关闭状态
            if inst.components.container:IsOpen() then
                return
            end

            -- 按目标缺项选择最适配肥料，而不是固定用第一格。
            local item, requested_nutrients, plan = GetBestItemForTarget(inst, target)
            -- 没有可用肥料时当前目标跳过。
            if not item or not item.components.fertilizer then
                return
            end

            local reservation = nil
            local reserve_target_shot = false
            if requested_nutrients ~= nil then
                -- 发射前按“当前值+在途预占”计算本次可用增量，避免空中过量浪费。
                reservation = BuildReservationForShot(inst, target, item, requested_nutrients)
                if reservation == nil then
                    return
                end

                ApplyPendingReservation(
                    inst,
                    reservation.tile_key,
                    reservation.add_1,
                    reservation.add_2,
                    reservation.add_3,
                    1
                )

                DebugLog(
                    "launch_reserve tile=%s item=%s req=(%s,%s,%s) reserve=(%d,%d,%d)",
                    tostring(reservation.tile_key),
                    tostring(item.prefab),
                    tostring(requested_nutrients[1]),
                    tostring(requested_nutrients[2]),
                    tostring(requested_nutrients[3]),
                    reservation.add_1 or 0,
                    reservation.add_2 or 0,
                    reservation.add_3 or 0
                )
            elseif GetPendingTargetShots(inst, target) > 0 then
                return
            else
                ApplyPendingTargetShot(inst, target, 1)
                reserve_target_shot = true
            end

            -- 播放开火动画。
            inst.AnimState:PlayAnimation("firing")

            -- 先消费肥料，再把对应投射体发射到目标。
            local projectile_item = ConsumeItemForProjectile(inst, item)

            -- 成功得到投射物时才发射。
            if projectile_item then
                inst.SoundEmitter:PlaySound(
                    "dontstarve_DLC001/creatures/dragonfly/buttstomp"
                )
                LaunchProjectile(inst, target, projectile_item, reservation, reserve_target_shot)

                if plan ~= nil
                    and requested_nutrients ~= nil
                    and plan.planned_shots_remaining ~= nil
                    and plan.planned_shots_remaining > 0 then
                    plan.planned_shots_remaining = plan.planned_shots_remaining - 1

                    DebugLog(
                        "shot_sent tile=%s idx=%s item=%s shots_left=%d",
                        tostring(reservation ~= nil and reservation.tile_key or "n/a"),
                        tostring(plan.current_nutrient_index),
                        tostring(item.prefab),
                        plan.planned_shots_remaining or 0
                    )
                end
            elseif reservation ~= nil then
                ApplyPendingReservation(
                    inst,
                    reservation.tile_key,
                    reservation.add_1,
                    reservation.add_2,
                    reservation.add_3,
                    -1
                )

                DebugLog(
                    "launch_failed_revert tile=%s item=%s",
                    tostring(reservation.tile_key),
                    tostring(item.prefab)
                )
            elseif reserve_target_shot then
                ApplyPendingTargetShot(inst, target, -1)
            end
        end)
    end
end

--容器开盖和关盖动画
local function OnContainerOpen(inst)
    -- 烧毁状态不播放开盖动画。
    if inst:HasTag("burnt") then
        return
    end

    -- 播放开盖动画。
    inst.AnimState:PlayAnimation("open")
    -- 播放开盖音效。
    inst.SoundEmitter:PlaySound(
        "dontstarve/common/together/portable/spicer/lid_open"
    )
end

local function OnContainerClose(inst)
    -- 烧毁状态不播放关盖动画。
    if inst:HasTag("burnt") then
        return
    end

    -- 播放关盖动画。
    inst.AnimState:PlayAnimation("close")
    -- 关盖后回到 idle 循环。
    inst.AnimState:PushAnimation("idle", true)

    -- 稍微延迟再播关盖音，让音画同步。
    inst:DoTaskInTime(0.4, function()
        -- 延迟执行时先检查实体是否仍有效。
        if inst:IsValid() then
            inst.SoundEmitter:PlaySound(
                "dontstarve/common/together/portable/spicer/lid_close"
            )
        end
    end)
end

local function OnHammered(inst, worker)
    if inst.components.container ~= nil then
        inst.components.container:DropEverything()
    end

    if inst.components.machine ~= nil then
        inst.components.machine:TurnOff()
    end

    if inst.components.lootdropper ~= nil then
        for _ = 1, 2 do
            inst.components.lootdropper:SpawnLootPrefab("transistor")
        end
        for _ = 1, 5 do
            inst.components.lootdropper:SpawnLootPrefab("poop")
        end
        for _ = 1, 4 do
            inst.components.lootdropper:SpawnLootPrefab("boards")
        end
    end

    SpawnPrefab("collapse_small").Transform:SetPosition(inst.Transform:GetWorldPosition())
    inst:Remove()
end

------------------------------------------------------------
-- Prefab
------------------------------------------------------------
local function fn()
    -- 创建 prefab 实体。
    local inst = CreateEntity()

    -- 添加基础实体组件：位置、动画、声音、小地图、网络同步。
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    -- 添加障碍物碰撞体，半径 0.5。
    MakeObstaclePhysics(inst, 0.5)

    -- 设置基础动画资源。
    inst.AnimState:SetBank("poop_flingomatic")
    inst.AnimState:SetBuild("poop_flingomatic")
    inst.AnimState:PlayAnimation("idle", true)

    -- 声明建筑标签。
    inst:AddTag("structure")

    -- Dedicated server 不需要 helper
    if not TheNet:IsDedicated() then
        inst:AddComponent("deployhelper")
        inst.components.deployhelper.onenablehelper = OnEnableHelper
    end
    

    -- 标记网络 pristine，之后进入主从分支。
    inst.entity:SetPristine()

    -- 客户端到此返回，后续仅服务器执行。
    if not TheWorld.ismastersim then
        return inst
    end

    -- 添加可检查组件（查看描述文本）。
    inst:AddComponent("inspectable")

    -- 被锤子摧毁后返还建造材料。
    inst:AddComponent("lootdropper")
    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(4)
    inst.components.workable:SetOnFinishCallback(OnHammered)

    -- 容器（官方范式）
    inst:AddComponent("container")
    -- 绑定容器 UI 配置。
    inst.components.container:WidgetSetup("poop_flingomatic")
    --初始化容器开盖和关盖动画
    inst.components.container.onopenfn  = OnContainerOpen
    inst.components.container.onclosefn = OnContainerClose

    -- 机器
    inst:AddComponent("machine")
    -- 默认通电开启。
    inst.components.machine.ison = true

    -- 写入施肥半径参数。
    inst.fertilization_range = FERTILIZATION_RANGE
    inst.active_fill_targets = {}
    inst.pending_tile_additions = {}
    inst.pending_target_shots = {}
    inst.current_farm_tile_key = nil

    -- 提高检查频率，减少农田从触发到开始喷射的等待时间。
    inst:DoPeriodicTask(CHECK_FERT_TIME, CheckForFertilization, INITIAL_CHECK_DELAY)

    -- 添加作祟交互处理。
    MakeHauntableWork(inst)

    -- 返回完整服务器实体。
    return inst
end

--建筑预放置（建造）的工作范围显示
local function placer_postinit_fn(inst)
    --Show the flingo placer on top of the flingo range ground placer

    -- 创建一个仅用于显示范围/动画的辅助 placer 实体。
    local placer2 = CreateEntity()

    --[[Non-networked entity]]
    placer2.entity:SetCanSleep(false)
    placer2.persists = false

    -- 添加基础展示组件。
    placer2.entity:AddTransform()
    placer2.entity:AddAnimState()

    placer2:AddTag("CLASSIFIED")
    placer2:AddTag("NOCLICK")
    placer2:AddTag("placer")

    -- 计算反向缩放，让显示范围和真实范围一致。
    local s = 1 / PLACER_SCALE
    placer2.Transform:SetScale(s, s, s)

    -- 设置预放置时的动画资源。
    placer2.AnimState:SetBank("poop_flingomatic")
    placer2.AnimState:SetBuild("poop_flingomatic")
    placer2.AnimState:PlayAnimation("idle",false)
    placer2.AnimState:SetLightOverride(1)

    -- 把辅助实体挂到主 placer 下，跟随移动。
    placer2.entity:SetParent(inst.entity)

    -- 把辅助实体交给 placer 系统管理。
    inst.components.placer:LinkEntity(placer2)
end

return
    -- 注册主 prefab。
    Prefab("poop_flingomatic", fn, assets, prefabs),
    -- 注册建造时使用的 placer prefab。
    MakePlacer(
        "poop_flingomatic_placer",
        "poop_flingomatic",
        "poop_flingomatic",
        "placer",
        true,
        nil,
        nil,
        PLACER_SCALE,
        nil,
        nil,
        placer_postinit_fn
    )





-- 目前的遗留问题是同时存在多个养分值缺乏的农场，对多个农场施肥的情况下可能会导致肥料浪费