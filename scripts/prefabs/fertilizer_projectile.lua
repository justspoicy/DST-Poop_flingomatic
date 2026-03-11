local fertilizer_projectile_assets =
{
    Asset("ANIM", "anim/poop.zip"),
}

local fertilizer_projectile_prefabs =
{
    "slingshotammo_hitfx_poop",
}

local DAMAGE_SANITY=10
local WORMWOOD_HEAL=2
local MAX_FARM_NUTRIENT=100
local POOPFLING_DEBUG = rawget(_G, "POOPFLING_DEBUG") == true

local function DebugLog(fmt, ...)
    if POOPFLING_DEBUG then
        print(string.format("[PoopFlingDBG] " .. fmt, ...))
    end
end

local function ReleasePendingReservation(inst)
    if inst._pending_released then
        return
    end

    inst._pending_released = true

    if inst.launcher == nil
        or not inst.launcher:IsValid() then
        return
    end

    if inst.pending_tile_key ~= nil and inst.launcher.pending_tile_additions ~= nil then
        local pending = inst.launcher.pending_tile_additions[inst.pending_tile_key]
        if pending ~= nil then
            pending[1] = math.max(0, (pending[1] or 0) - (inst.reserved_add_1 or 0))
            pending[2] = math.max(0, (pending[2] or 0) - (inst.reserved_add_2 or 0))
            pending[3] = math.max(0, (pending[3] or 0) - (inst.reserved_add_3 or 0))

            if pending[1] <= 0 and pending[2] <= 0 and pending[3] <= 0 then
                inst.launcher.pending_tile_additions[inst.pending_tile_key] = nil
            end
        end
    end

    if inst.pending_target_guid ~= nil and inst.launcher.pending_target_shots ~= nil then
        local next_value = math.max(0, (inst.launcher.pending_target_shots[inst.pending_target_guid] or 0) - 1)
        if next_value <= 0 then
            inst.launcher.pending_target_shots[inst.pending_target_guid] = nil
        else
            inst.launcher.pending_target_shots[inst.pending_target_guid] = next_value
        end
    end
end

local function GetFarmTileFromPoint(x, y, z)
    if TheWorld.components.farming_manager == nil then
        return nil
    end

    if not TheWorld.Map:IsFarmableSoilAtPoint(x, y, z) then
        return nil
    end

    return TheWorld.Map:GetTileCoordsAtPoint(x, y, z)
end

local function ResolveFarmTile(inst)
    if inst.target_tile_x ~= nil and inst.target_tile_z ~= nil then
        return inst.target_tile_x, inst.target_tile_z
    end

    if inst.target ~= nil and inst.target:IsValid() then
        local x, y, z = inst.target.Transform:GetWorldPosition()
        local tile_x, tile_z = GetFarmTileFromPoint(x, y, z)
        if tile_x ~= nil then
            return tile_x, tile_z
        end
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    return GetFarmTileFromPoint(x, y, z)
end

local function FertilizeFarmTile(inst)
    if inst.item == nil
        or inst.item.components.fertilizer == nil
        or TheWorld.components.farming_manager == nil then
        return false
    end

    local tile_x, tile_z = ResolveFarmTile(inst)
    if tile_x == nil then
        return false
    end

    local nutrients = inst.item.components.fertilizer.nutrients or { 0, 0, 0 }

    local current_1, current_2, current_3 =
        TheWorld.components.farming_manager:GetTileNutrients(tile_x, tile_z)

    local add_1 = math.max(0, math.min(nutrients[1] or 0, MAX_FARM_NUTRIENT - (current_1 or 0)))
    local add_2 = math.max(0, math.min(nutrients[2] or 0, MAX_FARM_NUTRIENT - (current_2 or 0)))
    local add_3 = math.max(0, math.min(nutrients[3] or 0, MAX_FARM_NUTRIENT - (current_3 or 0)))

    if add_1 <= 0 and add_2 <= 0 and add_3 <= 0 then
        return false
    end

    TheWorld.components.farming_manager:AddTileNutrients(
        tile_x,
        tile_z,
        add_1,
        add_2,
        add_3
    )

    return true
end

local function OnHitPoop(inst, attacker, target)
    target = inst.target or target

    DebugLog(
        "hit prefab=%s tile=%s target=%s",
        tostring(inst.item ~= nil and inst.item.prefab or "nil"),
        tostring(inst.pending_tile_key),
        tostring(target ~= nil and target.prefab or "nil")
    )

    -- 命中瞬间冻结抛射物物理，避免继续在地面滑行。
    if inst.Physics ~= nil then
        inst.Physics:Stop()
        inst.Physics:ClearCollisionMask()
        inst.Physics:SetActive(false)
    end

    local proj=SpawnPrefab("slingshotammo_hitfx_poop")
    local x,y,z=inst.Transform:GetWorldPosition()
    proj.Transform:SetPosition(x,y-2,z)
    
    local ent=TheSim:FindEntities(x,y,z,1, {"player"})
    if #ent > 0 then
        DebugLog("hit_blocked_by_player count=%d tile=%s", #ent, tostring(inst.pending_tile_key))
        for k,v in ipairs(ent) do
            if (inst.item.prefab=="poop" or inst.item.prefab=="guano") and v.prefab=="wormwood" then
                    v.components.health:DoDelta(WORMWOOD_HEAL)
            else
                v.components.sanity:DoDelta(-DAMAGE_SANITY)
                v:PushEvent("attacked", { attacker = attacker, damage = 0 })
            end
        end

        -- 被角色挡住未生效时，立即释放在途预占，允许后续补打。
        ReleasePendingReservation(inst)
        
    else
        inst.SoundEmitter:PlaySound(inst.item.components.fertilizer.fertilize_sound)
        local fertilized_farm_tile = FertilizeFarmTile(inst)
        DebugLog("hit_apply_farmtile=%s tile=%s", tostring(fertilized_farm_tile), tostring(inst.pending_tile_key))

        if target ~= nil
            and target.components.pickable
            and target.components.pickable:IsBarren() then
            target.components.pickable:Fertilize(inst.item)
        end
        if target ~= nil and target.components.grower then
             target.components.grower:Fertilize(inst.item)
        end
        if target ~= nil and not fertilized_farm_tile and target:HasTag("farm_plant") then
            FertilizeFarmTile(inst)
        end

        -- 命中处理完成后再释放预占，避免“先释放、后加养分”的时序窗口。
        ReleasePendingReservation(inst)
    end
        
    
    inst:DoTaskInTime(0.01, function()
        ReleasePendingReservation(inst)
        if inst.item ~= nil and inst.item:IsValid() then
            inst.item:Remove()
        end
        inst:Remove()
    end) -- This timer is just to give time to the item to play the sound
end

local function fertilizer_projectile_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.entity:AddPhysics()
    inst.Physics:SetMass(1)
    inst.Physics:SetFriction(0)
    inst.Physics:SetDamping(0)
    inst.Physics:SetCollisionGroup(COLLISION.CHARACTERS)
    inst.Physics:ClearCollisionMask()
    inst.Physics:CollidesWith(COLLISION.GROUND)
    inst.Physics:SetCapsule(0.2, 0.2)
    inst.Physics:SetDontRemoveOnSleep(true)

    inst:AddTag("projectile")
    inst:AddTag("NOCLICK")

    inst.AnimState:SetBank("poop")
    inst.AnimState:SetBuild("poop")
    inst.AnimState:PlayAnimation("idle", true)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("locomotor")

    inst:AddComponent("complexprojectile")


    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false
    
    inst.target=nil
    inst.item=nil
    inst.target_tile_x=nil
    inst.target_tile_z=nil
    inst.pending_tile_key=nil
    inst.pending_target_guid=nil
    inst.reserved_add_1=0
    inst.reserved_add_2=0
    inst.reserved_add_3=0
    inst.launcher=nil
    inst._pending_released=false

    inst:ListenForEvent("onremove", ReleasePendingReservation)

    inst.components.complexprojectile:SetHorizontalSpeed(70)
    inst.components.complexprojectile:SetGravity(-140)
    inst.components.complexprojectile:SetLaunchOffset(Vector3(0, 0.05, 0))
    inst.components.complexprojectile:SetOnHit(OnHitPoop)

    return inst
end


return Prefab("fertilizer_projectile", fertilizer_projectile_fn, fertilizer_projectile_assets, fertilizer_projectile_prefabs)
