local require = GLOBAL.require
local Vector3 = GLOBAL.Vector3

GLOBAL.POOPFLING_DEBUG = GetModConfigData ~= nil and GetModConfigData("poopfling_debug") == true

Assets = {
    Asset("ANIM", "anim/ui_chest_3x3.zip"),
    Asset("ATLAS", "images/inventoryimages/poop_flingomatic.xml"),
    Asset("ATLAS", "minimap/poop_flingomatic.xml"),
}

PrefabFiles = {
    "poop_flingomatic",
    "fertilizer_projectile",
}

local fertilizer_list = {
    fertilizer = true,
    glommerfuel = true,
    rottenegg = true,
    spoiled_food = true,
    spoiled_fish = true,
    spoiled_fish_small = true,
    guano = true,
    poop = true,
    compost = true,
    compostwrap = true,
    soil_amender = true,
    soil_amender_fermented = true,
}

GLOBAL.STRINGS.NAMES.POOP_FLINGOMATIC = "Poop Flingomatic"
GLOBAL.STRINGS.RECIPE_DESC.POOP_FLINGOMATIC = "Fertilize plants and farms."
GLOBAL.STRINGS.CHARACTERS.GENERIC.DESCRIBE.POOP_FLINGOMATIC = "It stinks, but it\'s useful."

AddMinimapAtlas("minimap/poop_flingomatic.xml")

AddRecipe("poop_flingomatic",
    {GLOBAL.Ingredient("transistor", 2), 
     GLOBAL.Ingredient("poop", 5),
     GLOBAL.Ingredient("boards", 4)},
    GLOBAL.RECIPETABS.SCIENCE,
    GLOBAL.TECH.SCIENCE_TWO,
    "poop_flingomatic_placer",
    2,
    nil, nil, nil,
    "images/inventoryimages/poop_flingomatic.xml",
    "poop_flingomatic.tex"
)

-- 方法1：使用官方推荐的方式注册自定义容器（推荐）
local containers = require "containers"

-- 定义容器参数
local poop_flingomatic_params = {
    widget = {
        slotpos = {},
        animbank = "ui_chest_3x3",
        animbuild = "ui_chest_3x3",
        pos = GLOBAL.Vector3(0, 200, 0),
        side_align_tip = 160,

        -- 添加以下字段确保UI正确显示
        badgepos = GLOBAL.Vector3(0, -5, 0),
        animhover = "ui_chest_3x3_hover",
        animselect = "ui_chest_3x3_select",
        openanim = "ui_chest_3x3_open",
        closedanim = "ui_chest_3x3_closed",
        itemtestfn = function(container, item, slot)
            return item:HasTag("poop_flingomatic_fertilizer")
        end,
    },
    type = "chest",

    -- 添加容器打开/关闭动画信息
    open_sound = "dontstarve/common/chest_open",
    close_sound = "dontstarve/common/chest_close",
}

-- 创建3x3格子位置
for y = 2, 0, -1 do
    for x = 0, 2 do
        table.insert(poop_flingomatic_params.widget.slotpos, 
                    GLOBAL.Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 80, 0))
    end
end

-- 使用官方API注册容器
containers.MAXITEMSLOTS = math.max(containers.MAXITEMSLOTS, #poop_flingomatic_params.widget.slotpos)
containers.params["poop_flingomatic"] = poop_flingomatic_params

-- 为肥料物品添加标签
for prefab, _ in pairs(fertilizer_list) do
    AddPrefabPostInit(prefab, function(inst)
        if not GLOBAL.TheWorld.ismastersim then
            return
        end
        inst:AddTag("poop_flingomatic_fertilizer")
    end)
end

------------------------------------------------------------
-- DEBUG：控制台一键清空周围农田养分
-- 用法：
--   c_clearfarmnutrients()       默认半径 20，清空周围农田
--   c_clearfarmnutrients(40)     指定半径 40
------------------------------------------------------------
GLOBAL.c_clearfarmnutrients = function(radius)
    -- 只能在服务器端执行
    if not GLOBAL.TheWorld.ismastersim then
        print("[PoopFling] 清空养分只能在服务器端执行")
        return
    end

    radius = radius or 20

    local player = GLOBAL.ThePlayer
    if player == nil then
        print("[PoopFling] 找不到玩家实体")
        return
    end

    local fm = GLOBAL.TheWorld.components.farming_manager
    if fm == nil then
        print("[PoopFling] farming_manager 不存在（可能不在服务器端）")
        return
    end

    local x, y, z = player.Transform:GetWorldPosition()
    local map     = GLOBAL.TheWorld.Map

    -- 已处理过的 tile key，避免重复清同一地块
    local cleared = {}
    local count   = 0

    -- 扫描范围内所有实体，找到位于农田土壤上的都清其所在地块
    for _, ent in ipairs(GLOBAL.TheSim:FindEntities(x, y, z, radius)) do
        local ex, ey, ez = ent.Transform:GetWorldPosition()
        if map:IsFarmableSoilAtPoint(ex, ey, ez) then
            local tx, tz = map:GetTileCoordsAtPoint(ex, ey, ez)
            local key = tx .. ":" .. tz
            if not cleared[key] then
                cleared[key] = true
                local n1, n2, n3 = fm:GetTileNutrients(tx, tz)
                if n1 ~= nil and (n1 > 0 or n2 > 0 or n3 > 0) then
                    -- 减去当前值使三项均归零
                    fm:AddTileNutrients(tx, tz, -n1, -n2, -n3)
                    count = count + 1
                end
            end
        end
    end

    -- 同步重置周围所有 poop_flingomatic 的内部施肥计划，
    -- 避免旧计划在养分清零后立刻触发大量喷射导致断连。
    for _, ent in ipairs(GLOBAL.TheSim:FindEntities(x, y, z, radius + 20)) do
        if ent.prefab == "poop_flingomatic" then
            ent.active_fill_targets = {}
            ent.pending_tile_additions = {}
            ent.pending_target_shots = {}
        end
    end

    print(string.format("[PoopFling] 已清空 %d 块农田养分（半径=%d）", count, radius))
end