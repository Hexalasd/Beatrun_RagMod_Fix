if engine.ActiveGamemode() ~= "beatrun" then return end

if SERVER then AddCSLuaFile() end

-- RagMod turns the player into a spectator while ragdolled. Beatrun's movement hooks don't
-- skip spectators, so climbing can grab a ceiling above the spectator and hang the player in it.
local function IsRagdolled(ply)
	return IsValid(ply:GetNWEntity("ragmod_Possessed"))
end

local function IsBeatrunHook(fn)
	local info = debug.getinfo(fn, "S")
	return info ~= nil and string.find(info.short_src, "gamemodes/beatrun/", 1, true) ~= nil
end

local function WrapBeatrunMoveHooks()
	local found = {}

	for id, fn in pairs(hook.GetTable().SetupMove or {}) do
		if isstring(id) and isfunction(fn) and IsBeatrunHook(fn) then
			found[id] = fn
		end
	end

	for id, fn in pairs(found) do
		hook.Add("SetupMove", id, function(ply, mv, cmd)
			if IsRagdolled(ply) then return end
			return fn(ply, mv, cmd)
		end)
	end
end

hook.Add("InitPostEntity", "BRRM_WrapMoveHooks", WrapBeatrunMoveHooks)
timer.Create("BRRM_WrapMoveHooks", 5, 0, WrapBeatrunMoveHooks)
