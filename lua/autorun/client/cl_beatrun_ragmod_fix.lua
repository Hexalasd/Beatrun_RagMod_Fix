
if engine.ActiveGamemode() ~= "beatrun" then return end

local ANCHOR_HEIGHT = 20
local ANCHOR_MAX_LAG = 16
local BLEND_TIME = 0.3
local BLEND_MAX_DIST = 500
local TPS_MIN_OFFSET = 24
local DEFAULT_OFFSET = Vector(-100, 0, 0)

local hullMins = Vector(-4, -4, -4)
local hullMaxs = Vector(4, 4, 4)

local debugCvar = CreateClientConVar("brrm_debug", "0", false, false, "Print the ragdoll camera decisions once per second")

local function GetLocalRagdoll(ply)
	if not ragmod then return NULL end

	return ragmod:GetRagmodRagdoll(ply or LocalPlayer())
end

local function IsLocalRagdolled()
	return IsValid(GetLocalRagdoll())
end

local cvarCache = {}

local function GetCvar(name)
	local cv = cvarCache[name]

	if not cv then
		cv = GetConVar(name)
		cvarCache[name] = cv
	end

	return cv
end

local function CvarFloat(name, default)
	local cv = GetCvar(name)

	return cv and cv:GetFloat() or default
end

-- Beatrun Thirdperson Camera (with Freelook)
local function BrCamEnabled()
	local cv = GetCvar("cl_br_cam_enabled")

	return cv ~= nil and cv:GetBool()
end


local function BeatrunFOV(fov)
	local desired = GetCvar("fov_desired")
	local beatrunFov = GetCvar("beatrun_fov")
	if not desired or not beatrunFov or desired:GetInt() == 0 then return fov end

	return math.Remap(fov, 0, desired:GetInt(), 0, beatrunFov:GetInt())
end


local ourWrappers = setmetatable({}, {__mode = "k"})

local function EnsureWrapped(event, id, makeWrapper)
	local hooks = hook.GetTable()[event]
	local fn = hooks and hooks[id]
	if not fn or ourWrappers[fn] then return end

	local wrapper = makeWrapper(fn)
	ourWrappers[wrapper] = true
	hook.Add(event, id, wrapper)
end

local function SkipWhileRagdolled(original)
	return function(...)
		if IsLocalRagdolled() then return end

		return original(...)
	end
end


local blend = nil

local function StartBlend(origin, angles)
	if not origin or not angles then return end

	blend = {
		origin = Vector(origin),
		angles = Angle(angles.p, angles.y, 0),
		start = RealTime()
	}
end

local function ApplyBlend(view)
	if not blend or not istable(view) or not isvector(view.origin) or not isangle(view.angles) then return end

	-- Nested CalcView calls can hand back the same table
	if view.BRRM_BlendFrame == FrameNumber() then return end
	view.BRRM_BlendFrame = FrameNumber()

	local frac = (RealTime() - blend.start) / BLEND_TIME

	if frac >= 1 or blend.origin:DistToSqr(view.origin) > BLEND_MAX_DIST * BLEND_MAX_DIST then
		blend = nil

		return
	end

	local eased = math.ease.OutCubic(frac)
	view.origin = LerpVector(eased, blend.origin, view.origin)
	view.angles = LerpAngle(eased, blend.angles, view.angles)
end


-- Last rendered view, and the thirdperson offset learned from it before ragdolling
local lastView = {}
local thirdPerson = false
local learnedOffset = nil
local learnedFov = nil

hook.Add("RenderScene", "BRRM_TrackView", function(origin, angles, fov)
	lastView.origin = Vector(origin)
	lastView.angles = Angle(angles.p, angles.y, 0)

	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() or ply:InVehicle() or IsLocalRagdolled() or ply:GetViewEntity() ~= ply then return end

	local offset = WorldToLocal(origin, angle_zero, ply:EyePos(), lastView.angles)
	local dist = offset:Length()

	thirdPerson = BrCamEnabled() or (dist > TPS_MIN_OFFSET and (dist > TPS_MIN_OFFSET * 2.5 or ply:ShouldDrawLocalPlayer()))

	if thirdPerson then
		learnedOffset = offset
		learnedFov = fov
	end
end)

-- Cameras that only set drawviewer (Third Person++) leave ShouldDrawLocalPlayer false outside of rendering,
-- so Beatrun keeps drawing its first person body next to the player
hook.Add("ShouldDrawLocalPlayer", "BRRM_ThirdPersonBody", function(ply)
	if thirdPerson and ply:Alive() and not ply:InVehicle() and ply:GetViewEntity() == ply and not IsLocalRagdolled() then
		return true
	end
end)


local camAnchor = nil
local lastFPViewAngles = nil
local ragdollTPS = nil
local lastCameraTPS = nil
local lastViewType = nil
local eyeDeltaMode = false

local function BuildRagdollView(ply, ragdoll, viewAngles, fov, offset)
	local target = ragdoll:GetPos()
	target.z = target.z + ANCHOR_HEIGHT

	-- Smooth out small jitter, but never lag far behind a ragdoll flying at high speed
	local smooth = CvarFloat("cl_br_cam_smooth", 12)

	if not camAnchor or smooth <= 0 then
		camAnchor = target
	else
		camAnchor = LerpVector(1 - math.exp(-smooth * FrameTime()), camAnchor, target)

		local lag = camAnchor - target

		if lag:LengthSqr() > ANCHOR_MAX_LAG * ANCHOR_MAX_LAG then
			lag:Normalize()
			camAnchor = target + lag * ANCHOR_MAX_LAG
		end
	end

	local desired = LocalToWorld(offset, angle_zero, camAnchor, Angle(viewAngles.p, viewAngles.y, 0))

	local tr = util.TraceHull({
		start = camAnchor,
		endpos = desired,
		filter = {ply, ragdoll},
		mins = hullMins,
		maxs = hullMaxs,
		mask = MASK_SOLID
	})

	local view = {
		origin = tr.Hit and tr.HitPos + tr.HitNormal * 2 or desired,
		angles = Angle(viewAngles.p, viewAngles.y, viewAngles.r),
		fov = fov,
		drawviewer = false
	}

	ApplyBlend(view)

	return view
end


local forcedOptions = {}

local function GetForcedViewOptions(viewOptions, viewType)
	local forced = forcedOptions[viewType]
	if forced and forced.base == viewOptions.ForcedView then return forced end

	forced = {
		base = viewOptions.ForcedView,
		ForcedView = setmetatable({}, {
			__index = viewOptions.ForcedView,
			__call = function() return true end
		}),
		ForcedViewType = setmetatable({}, {
			__index = viewOptions.ForcedViewType,
			__call = function() return viewType end
		})
	}

	forcedOptions[viewType] = forced

	return forced
end

-- Runs RagMod's CalcView as if the server forced this view type
local function CallRagmodAs(viewType, original, ...)
	local viewOptions = RagModOptions and RagModOptions.View
	if not viewOptions or not viewOptions.ForcedView or not viewOptions.ForcedViewType then return end

	local forced = GetForcedViewOptions(viewOptions, viewType)
	local oldForcedView, oldForcedViewType = viewOptions.ForcedView, viewOptions.ForcedViewType
	viewOptions.ForcedView, viewOptions.ForcedViewType = forced.ForcedView, forced.ForcedViewType

	local ok, view = pcall(original, ...)

	viewOptions.ForcedView, viewOptions.ForcedViewType = oldForcedView, oldForcedViewType

	if not ok then
		ErrorNoHalt("[Beatrun RagMod Fix] RagMod CalcView error: " .. tostring(view) .. "\n")

		return
	end

	if istable(view) then return view end
end

local function RagmodViewForced()
	local viewOptions = RagModOptions and RagModOptions.View

	return viewOptions ~= nil and viewOptions.ForcedView ~= nil and tobool(viewOptions.ForcedView())
end

local SKIP_WHILE_RAGDOLLED = {
	BodyAnimCalcView2 = true,
	br_TPS_Camera_Render = true
}

local function CallCalcViewHook(id, fn, ...)
	local ok, view

	if isstring(id) then
		ok, view = pcall(fn, ...)
	elseif IsValid(id) then
		ok, view = pcall(fn, id, ...)
	else
		return
	end

	if not ok then
		ErrorNoHalt("[Beatrun RagMod Fix] CalcView hook '" .. tostring(id) .. "' error: " .. tostring(view) .. "\n")

		return
	end

	if istable(view) then return view end
end

local function CallCalcViewHooks(gm, skipId, ply, origin, angles, fov, znear, zfar)
	for id, fn in pairs(hook.GetTable().CalcView or {}) do
		if id ~= skipId then
			local view = CallCalcViewHook(id, fn, ply, origin, angles, fov, znear, zfar)
			if view then return view end
		end
	end

	if gm and gm.CalcView then
		return gm:CalcView(ply, origin, angles, fov, znear, zfar)
	end
end

local function IsThirdPersonView(view, origin)
	if not view then return false end
	if view.drawviewer == true then return true end

	return isvector(view.origin) and view.origin:DistToSqr(origin) > TPS_MIN_OFFSET * TPS_MIN_OFFSET
end

local nextDebugPrint = 0

-- While ragdolled the whole CalcView goes through here, so the result no longer depends on hook order.
-- Other camera addons still run (their state keeps ticking), their view only tells us whether a
-- thirdperson camera is active and which angles/FOV it wants.
local function DecideRagdollView(ply, origin, angles, fov, znear, zfar)
	local ragdoll = GetLocalRagdoll(ply)
	local eyeAngles = Angle(angles.p, angles.y, 0)
	local ragmodAngles = angles

	local hooks = {}

	for id, fn in pairs(hook.GetTable().CalcView or {}) do
		hooks[#hooks + 1] = {id, fn}
	end

	local candidate, candidateId, ragmodFn

	for _, entry in ipairs(hooks) do
		local id, fn = entry[1], entry[2]

		if id == "ragmod_CalcView" then
			ragmodFn = fn
		elseif not candidate and not SKIP_WHILE_RAGDOLLED[id] then
			candidate = CallCalcViewHook(id, fn, ply, Vector(origin), Angle(angles), fov, znear, zfar)
			candidateId = candidate and id
		end
	end

	local cameraTPS = BrCamEnabled() or hook.Run("ShouldDrawLocalPlayer", ply) == true or IsThirdPersonView(candidate, origin)
	local viewType, locked = ragmod:GetPlayerViewType(ply)
	local tps

	-- RagMod's view type picks the camera when ragdolling and whenever it changes. Toggling a thirdperson
	-- camera addon while ragdolled still switches, unless the server forces the view.
	if ragdollTPS == nil or viewType ~= lastViewType or RagmodViewForced() then
		tps = viewType == "thirdperson"
	elseif cameraTPS ~= lastCameraTPS then
		tps = cameraTPS
	else
		tps = ragdollTPS
	end

	lastCameraTPS, lastViewType = cameraTPS, viewType

	-- Switched to first person while RagMod is set to thirdperson: its position-only mode keeps the real eye angles
	local fpType = viewType == "thirdperson" and "firstperson_pos_only" or viewType
	local deltaMode = not tps and fpType == "firstperson" and not locked

	if ragdollTPS ~= nil then
		if tps ~= ragdollTPS then
			StartBlend(lastView.origin, lastView.angles)

			if tps then
				camAnchor = nil
			end
		end

		-- RagMod's semi-free first person keeps the eye angles at zero and reads them as a per-frame delta
		if deltaMode ~= eyeDeltaMode then
			if deltaMode then
				ply:SetEyeAngles(angle_zero)
				ragmodAngles = Angle(0, 0, 0)
			elseif lastFPViewAngles then
				ply:SetEyeAngles(lastFPViewAngles)
				eyeAngles = Angle(lastFPViewAngles)
				ragmodAngles = Angle(lastFPViewAngles)
			end
		end
	end

	ragdollTPS, eyeDeltaMode = tps, deltaMode

	local view, source

	if tps and cameraTPS then
		if ragmodFn then
			CallRagmodAs("thirdperson", ragmodFn, ply, origin, angles, fov, znear, zfar)
		end

		if BrCamEnabled() then
			local offset = Vector(-CvarFloat("cl_br_cam_dist", 100), -CvarFloat("cl_br_cam_side", 20), CvarFloat("cl_br_cam_up", 0))

			view = BuildRagdollView(ply, ragdoll, eyeAngles, CvarFloat("cl_br_cam_fov", fov), offset)
		else
			local viewAngles = candidate and isangle(candidate.angles) and candidate.angles or eyeAngles
			local viewFov = candidate and isnumber(candidate.fov) and candidate.fov or learnedFov or fov

			view = BuildRagdollView(ply, ragdoll, viewAngles, viewFov, learnedOffset or DEFAULT_OFFSET)
		end

		source = "thirdperson"
	else
		-- No thirdperson camera addon active, or first person: RagMod's own view
		view = ragmodFn and CallRagmodAs(tps and "thirdperson" or fpType, ragmodFn, ply, origin, ragmodAngles, fov, znear, zfar)

		if view then
			source = "ragmod"

			if not tps and view.angles then
				lastFPViewAngles = Angle(view.angles.p, view.angles.y, 0)
			end

			if view.fov then
				view.fov = BeatrunFOV(view.fov)
			end
		else
			view = candidate
			source = candidateId or "none"
		end

		ApplyBlend(view)
	end

	if debugCvar:GetBool() and RealTime() >= nextDebugPrint then
		nextDebugPrint = RealTime() + 1
		print(string.format("[Beatrun RagMod Fix] tps=%s camera=%s ragmodtype=%s forced=%s candidate=%s view=%s", tostring(tps), tostring(cameraTPS), tostring(viewType), tostring(RagmodViewForced()), tostring(candidateId), tostring(source)))
	end

	return view
end

local arbiterFrame = nil
local arbiterView = nil
local arbiterRunning = false

local function RunRagdollCamera(ply, origin, angles, fov, znear, zfar)
	if arbiterFrame == FrameNumber() then return arbiterView end

	arbiterRunning = true
	local ok, view = pcall(DecideRagdollView, LocalPlayer(), origin, angles, fov, znear, zfar)
	arbiterRunning = false

	if not ok then
		ErrorNoHalt("[Beatrun RagMod Fix] Ragdoll camera error: " .. tostring(view) .. "\n")
		view = nil
	end

	arbiterFrame, arbiterView = FrameNumber(), view

	return view
end

local function RagdollCameraActive()
	local ply = LocalPlayer()

	return IsValid(GetLocalRagdoll(ply)) and ply:GetViewEntity() == ply
end


local savedTPSHooks = nil
local tpsSuspended = false

local function FindTPSToggle()
	local callbacks = cvars.GetConVarCallbacks("cl_br_cam_enabled")
	if not callbacks then return end

	for _, callback in ipairs(callbacks) do
		if istable(callback) and callback[2] == "br_MenuSync" then return callback[1] end
	end
end

local function TPSHooksActive()
	local calcView = hook.GetTable().CalcView

	return calcView ~= nil and calcView.br_TPS_Camera_Render ~= nil
end

local function SetTPSHooksActive(active)
	local toggle = FindTPSToggle()

	if toggle then
		toggle("cl_br_cam_enabled", active and "0" or "1", active and "1" or "0")

		return
	end


	if active then
		if not savedTPSHooks then return end

		for event, fn in pairs(savedTPSHooks) do
			hook.Add(event, event == "CalcView" and "br_TPS_Camera_Render" or "br_FreeLook_Logic", fn)
		end

		savedTPSHooks = nil
	else
		local hooks = hook.GetTable()

		savedTPSHooks = {
			CalcView = hooks.CalcView and hooks.CalcView.br_TPS_Camera_Render,
			CreateMove = hooks.CreateMove and hooks.CreateMove.br_FreeLook_Logic
		}

		hook.Remove("CalcView", "br_TPS_Camera_Render")
		hook.Remove("CreateMove", "br_FreeLook_Logic")
	end
end

local function UpdateTPSHooks(suspend)
	if suspend then

		if TPSHooksActive() then
			SetTPSHooksActive(false)
		end

		tpsSuspended = true
	elseif tpsSuspended then
		tpsSuspended = false

		if BrCamEnabled() and not TPSHooksActive() then
			SetTPSHooksActive(true)
		end
	end
end


local function HiddenWhileRagdolled(self, flags)
	if IsLocalRagdolled() then return end

	local original = self.BRRM_RenderOverride

	if original then
		return original(self, flags)
	end

	self:DrawModel(flags)
end

local function HideWhileRagdolled(ent)
	if not IsValid(ent) or ent.RenderOverride == HiddenWhileRagdolled then return end

	ent.BRRM_RenderOverride = ent.RenderOverride
	ent.RenderOverride = HiddenWhileRagdolled
end

local function HideBodyAnimModels()
	HideWhileRagdolled(BodyAnim)
	HideWhileRagdolled(BodyAnimMDL)
	HideWhileRagdolled(BodyAnimMDLarm)
	HideWhileRagdolled(BodyAnimWEPMDL)
	HideWhileRagdolled(BodyAnimArmCopy)
end

hook.Add("PrePlayerDraw", "BRRM_HideRagdolledPlayer", function(ply)
	if ragmod and IsValid(ragmod:GetRagmodRagdoll(ply)) then return true end
end)


local wasRagdolled = false
local unpossessPending = false

local function OnRagdollStart(ply)
	camAnchor = nil
	lastFPViewAngles = nil
	ragdollTPS = nil
	lastCameraTPS = nil
	lastViewType = nil
	eyeDeltaMode = false
	unpossessPending = false

	if thirdPerson then
		StartBlend(lastView.origin, lastView.angles)
	end


	if isfunction(RemoveBodyAnim) and IsValid(BodyAnim) then
		local ok, err = pcall(RemoveBodyAnim, true)

		if not ok then
			ErrorNoHalt("[Beatrun RagMod Fix] RemoveBodyAnim error: " .. tostring(err) .. "\n")
		end
	end
end

local function OnRagdollEnd(ply)
	camAnchor = nil
	unpossessPending = true

	-- Back to whatever the camera addon shows; without one RagMod animates the way back itself
	if lastCameraTPS then
		StartBlend(lastView.origin, lastView.angles)
	end

	if lastCameraTPS ~= nil then
		thirdPerson = lastCameraTPS
	end

	ragdollTPS = nil
end

hook.Add("PreRender", "BRRM_Update", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ragmod then return end

	local ragdolled = IsLocalRagdolled()

	if ragdolled ~= wasRagdolled then
		wasRagdolled = ragdolled

		if ragdolled then
			OnRagdollStart(ply)
		else
			OnRagdollEnd(ply)
		end
	end

	if ragdolled then
		HideBodyAnimModels()
	end

	UpdateTPSHooks(ragdolled and BrCamEnabled())

	EnsureWrapped("CreateMove", "BodyLimitMove", SkipWhileRagdolled)
	EnsureWrapped("CreateMove", "BodyAnim_Mouse", SkipWhileRagdolled)
	EnsureWrapped("InputMouseApply", "BodyAnim_Mouse", SkipWhileRagdolled)
	EnsureWrapped("HUDPaint", "br_TrueAimCrosshair", SkipWhileRagdolled)
end)


-- The engine dispatches CalcView through hook.Call. Taking over that one event instead of wrapping every
-- CalcView hook keeps working when other addons re-wrap hooks themselves (ActMod, Onge's drone camera).
local OriginalHookCall = hook.Call

-- Lua refresh: don't stack on top of our previous override
if OriginalHookCall == BRRM_HookCall then
	OriginalHookCall = BRRM_OriginalHookCall
end

local function CalcViewCall(gm, ply, origin, angles, fov, znear, zfar)
	if RagdollCameraActive() then
		-- Nested hook.Run("CalcView") from inside another camera hook
		if arbiterRunning then return end

		local view = RunRagdollCamera(ply, origin, angles, fov, znear, zfar)
		if view then return view end

		if gm and gm.CalcView then
			return gm:CalcView(ply, origin, angles, fov, znear, zfar)
		end

		return
	end

	-- Unpossess transition: RagMod keeps its state, the thirdperson camera owns the view
	if unpossessPending then
		local ragmodFn = (hook.GetTable().CalcView or {}).ragmod_CalcView

		if not ragmodFn or not CallCalcViewHook("ragmod_CalcView", ragmodFn, ply, origin, angles, fov, znear, zfar) then
			unpossessPending = false
		elseif thirdPerson then
			local view = CallCalcViewHooks(gm, "ragmod_CalcView", ply, origin, angles, fov, znear, zfar)
			ApplyBlend(view)

			return view
		end
	end

	local view = OriginalHookCall("CalcView", gm, ply, origin, angles, fov, znear, zfar)
	ApplyBlend(view)

	return view
end

-- Return values mean nothing for these, but any hook returning one (even false) makes GMod skip the
-- remaining hooks. Onge's camera does on Initialize, which leaves e.g. Eye View without its convars.
local NO_RETURN_EVENTS = {
	Initialize = true,
	InitPostEntity = true
}

local function DropReturnValues(event)
	local hooks = hook.GetTable()[event]
	if not hooks then return end

	local pending = {}

	for id, fn in pairs(hooks) do
		if not ourWrappers[fn] and (isstring(id) or IsValid(id)) then
			pending[id] = fn
		end
	end

	for id, fn in pairs(pending) do
		local wrapper = function(...) fn(...) end
		ourWrappers[wrapper] = true
		hook.Add(event, id, wrapper)
	end
end

local function HookCall(name, gm, ...)
	if name == "CalcView" then
		return CalcViewCall(gm, ...)
	end

	if NO_RETURN_EVENTS[name] then
		DropReturnValues(name)
	end

	return OriginalHookCall(name, gm, ...)
end

BRRM_HookCall, BRRM_OriginalHookCall = HookCall, OriginalHookCall
hook.Call = HookCall


local sentTPSState = nil

hook.Add("Think", "BRRM_SyncCameraMode", function()
	if not IsValid(LocalPlayer()) then return end

	local state = thirdPerson

	if IsLocalRagdolled() and ragdollTPS ~= nil then
		state = ragdollTPS
	end

	if state == sentTPSState then return end
	if util.NetworkStringToID("brrm_tps_state") == 0 then return end

	sentTPSState = state
	net.Start("brrm_tps_state")
	net.WriteBool(state)
	net.SendToServer()
end)
