
-- idk if this works lmao

if engine.ActiveGamemode() ~= "beatrun" then return end

util.AddNetworkString("brrm_tps_state")

net.Receive("brrm_tps_state", function(_, ply)
	ply.BRRM_UsingTPS = net.ReadBool()
end)

hook.Add("RM_CanChangeCamera", "BRRM_ThirdPersonCamera", function(ply)
	if ply.BRRM_UsingTPS then return false end
end)


hook.Add("RM_CustomRagdollCamera", "BRRM_ThirdPersonCamera", function(ragdoll, ply)
	if not ply.BRRM_UsingTPS then return end

	local start = ragdoll:GetPos() + Vector(0, 0, 20)

	local tr = util.TraceHull({
		start = start,
		endpos = start - ply:GetAimVector() * 100,
		filter = {ragdoll, ply},
		mins = Vector(-3, -3, -3),
		maxs = Vector(3, 3, 3)
	})

	return tr.HitPos, ply:EyeAngles()
end)
