name = "Poop Flingomatic_Compatibility upgrade"
description = [[
Automatic fires fertilizers on plants and farms.

Recipe: 2 Electrical Doodads, 5 Manures and 4 Boards.

Accepts: Manure, Guano, Bucket-o-poop, Rotten Egg, Glommer's Goop and  Compost Wrap

该mod在原先的 Poop Flingomatic 上与 懒人堆肥桶 之间做了兼容性升级（也有可能和其他容器类mod兼容？没测试过）。鼠标左键打开或关闭容器。

]]
author = ""
version = "0.2"
forumthread = ""
api_version = 10
dst_compatible = true

all_clients_require_mod = true
client_only_mod = false

icon_atlas = "images/modicon.xml"
icon = "modicon.tex"

----------------------------
-- Configuration settings --
----------------------------

configuration_options = {
	{
		name = "poopfling_debug",
		label = "Enable Debug Logs",
		hover = "Print [PoopFlingDBG] logs in server log for troubleshooting.",
		options = {
			{ description = "Off", data = false },
			{ description = "On", data = true },
		},
		default = false,
	},
}

