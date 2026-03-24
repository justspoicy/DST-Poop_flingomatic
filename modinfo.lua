name = "Poop Flingomatic_Compatibility upgrade2.0"
description = [[
Automatic fires fertilizers on plants and farms.

Recipe: 2 Electrical Doodads, 5 Manures and 4 Boards.

Accepts: Manure, Guano, Bucket-o-poop, Rotten Egg, Glommer's Goop and  Compost Wrap



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

