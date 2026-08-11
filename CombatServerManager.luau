-- Discord Account: dev_baum
-- Roblox Account: xXDRAGONIS_THEBEST
-- Connected Discord-GitHub

--[=[
    =======================================================================================
    UNIFIED COMBAT SERVER FRAMEWORK
    
    Architected by: dev_baum
    Description: Consolidates the game's server-side combat systems (Hit Registration, 
                 Blocking Mechanisms, Anti-Exploit Validation, and Network Request Routing)
                 into a single module. Eliminates nested redundancies, ensures optimal
                 thread utilization, and utilizes clean object-oriented methodology.

    Design Goals:
        1. Server Authority   - The client is never trusted to report damage, hit
                                 validity, or state; the server independently verifies
                                 every claim before acting on it.
        2. Modularity          - Each responsibility (blocking, hit resolution, effects,
                                 knockback, network routing) lives in its own function so
                                 the module is easy to read, test, and extend.
        3. Fail-Safe Execution - Any single missing asset (an animation, a sound, an
                                 effect) should degrade gracefully instead of throwing an
                                 error that halts the whole hit pipeline.
    =======================================================================================
--]=]

local CombatServerManager = {}

--[=[
    =======================================================================================
    1. DEPENDENCIES & SERVICES
    =======================================================================================
--]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris") -- Used for reliable, leak-free object cleanup

-- Asset Repository Structures
local combatFolder = ReplicatedStorage:WaitForChild("Combat")
local animations = combatFolder:WaitForChild("Animations")
local remotes = combatFolder:WaitForChild("Remotes")
local sfx = combatFolder:WaitForChild("SFX")
local fxStorage = combatFolder:WaitForChild("Fx")
local modules = combatFolder:WaitForChild("Modules")
local configuration = combatFolder:WaitForChild("Configuration")

-- Lazy-loading external components to ensure safe script compilation bounds
local ragdoll = require(modules:WaitForChild("Ragdoll"))

--[=[
    =======================================================================================
    2. CONSTANTS & RUNTIME STATE
    =======================================================================================
    Pulling frequently-used configuration values once (instead of calling GetAttribute on
    every single hit) keeps the hot path cheap. Configuration can still change at runtime
    via the listener below, so live tuning from a developer console still works.
--]=]

local BLOCK_ANGLE_THRESHOLD = 0.5      -- Dot product threshold for a "front-facing" block
local MAX_HIT_RANGE_STUDS = 12         -- Anything further than this is rejected server-side
local HIT_DEBOUNCE_SECONDS = 0.05      -- Minimum time between two hits on the same pair
local FX_LIFETIME_SECONDS = 2.0

local CachedConfig = {
	M1_Damage = configuration:GetAttribute("M1_Damage"),
	Stun_Time = configuration:GetAttribute("Stun_Time"),
	Ragdoll = configuration:GetAttribute("Ragdoll"),
	Ragdoll_Duration = configuration:GetAttribute("Ragdoll_Duration"),
}

-- Keep the cache in sync if a developer tweaks values live in Studio or via an admin panel
configuration.AttributeChanged:Connect(function(attributeName)
	CachedConfig[attributeName] = configuration:GetAttribute(attributeName)
end)

-- Tracks the last time a given (attacker, target) pair connected, keyed by
-- "attackerUserId_targetUserId", to stop a single client from spamming hit requests
-- against the same victim faster than the swing animation could realistically land.
local recentHitPairs: { [string]: number } = {}

--[=[
    =======================================================================================
    3. VALIDATION HELPERS (ANTI-EXPLOIT)
    =======================================================================================
    Nothing coming from a RemoteEvent is trustworthy by default. These helpers exist so
    ProcessHit never has to assume the client told the truth about range, timing, or the
    identity of what it claims to have hit.
--]=]

-- Confirms the target is a real, alive character with the parts we need to touch
local function IsValidTarget(targetCharacter: Model?): boolean
	if not targetCharacter then
		return false
	end
	local humanoid = targetCharacter:FindFirstChild("Humanoid") :: Humanoid?
	local root = targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		return false
	end
	if humanoid.Health <= 0 then
		return false
	end
	return true
end

-- Rejects hits that are physically impossible given the attacker and target positions.
-- This is the single most important anti-exploit check: without it, a client could report
-- "I hit this player" regardless of where either character actually is in the world.
local function IsWithinStrikingRange(attackerRoot: BasePart, targetRoot: BasePart): boolean
	local distance = (attackerRoot.Position - targetRoot.Position).Magnitude
	return distance <= MAX_HIT_RANGE_STUDS
end

-- Prevents a single swing from being reported multiple times in rapid succession
-- (e.g. an exploiter firing the remote in a loop instead of once per animation).
local function PassesDebounce(attacker: Player, targetCharacter: Model): boolean
	local key = tostring(attacker.UserId) .. "_" .. tostring(targetCharacter)
	local lastHitTime = recentHitPairs[key]
	local now = os.clock()

	if lastHitTime and (now - lastHitTime) < HIT_DEBOUNCE_SECONDS then
		return false
	end

	recentHitPairs[key] = now
	return true
end

--[=[
    =======================================================================================
    4. BLOCK STATE MANAGEMENT
    =======================================================================================
--]=]

-- Handles the safe addition of a blocking state instance on a target character
function CombatServerManager.StartBlock(character: Model?)
	if not character then
		return
	end
	if character:FindFirstChild("Block") then
		return -- Already blocking; avoid duplicate BoolValues
	end
	local blockVal = Instance.new("BoolValue")
	blockVal.Name = "Block"
	blockVal.Parent = character
end

-- Safely cleans up the blocking state instance from a target character
function CombatServerManager.StopBlock(character: Model?)
	if not character then
		return
	end
	local blockVal = character:FindFirstChild("Block")
	if blockVal then
		blockVal:Destroy()
	end
end

-- Evaluates whether the target is both actively blocking AND facing the attacker.
-- Returns true only when the attack should be deflected rather than landed.
local function HasLineOfSightBlock(attackerRoot: BasePart, targetCharacter: Model, targetRoot: BasePart): boolean
	if not targetCharacter:FindFirstChild("Block") then
		return false
	end

	local directionToAttacker = (attackerRoot.Position - targetRoot.Position).Unit
	local lookVector = targetRoot.CFrame.LookVector

	-- Evaluates if the attacker is hitting the front-facing arc of the defender
	return directionToAttacker:Dot(lookVector) > BLOCK_ANGLE_THRESHOLD
end

--[=[
    =======================================================================================
    5. ANIMATION / SFX HELPERS
    =======================================================================================
    Wrapped in pcall so a missing or renamed animation/sound asset degrades gracefully
    instead of throwing an error that would abort the rest of the hit resolution.
--]=]

-- Humanoid:LoadAnimation is deprecated by Roblox in favour of routing through the
-- Humanoid's Animator instance. This resolves (and lazily creates) that Animator so the
-- rest of the module never has to call the deprecated method directly.
local function GetAnimator(humanoid: Humanoid): Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator :: Animator
end

local function PlayRandomAnimation(humanoid: Humanoid, animFolder: Instance, speed: number?)
	local candidates = animFolder:GetChildren()
	if #candidates == 0 then
		return
	end

	local chosen = candidates[math.random(1, #candidates)]
	local animator = GetAnimator(humanoid)

	local success, track = pcall(function()
		local loaded = animator:LoadAnimation(chosen :: Animation)
		loaded.Priority = Enum.AnimationPriority.Action4
		loaded:Play()
		if speed then
			loaded:AdjustSpeed(speed)
		end
		return loaded
	end)

	if not success then
		warn("[CombatServerManager] Failed to play animation:", track)
	end
end

local function PlaySound(soundTemplate: Sound, parent: Instance)
	local success, clone = pcall(function()
		local s = soundTemplate:Clone()
		s.Parent = parent
		s:Play()
		return s
	end)

	if success and clone then
		Debris:AddItem(clone, (clone :: Sound).TimeLength)
	end
end

--[=[
    =======================================================================================
    6. REACTION HANDLERS
    =======================================================================================
--]=]

-- Handles everything that happens when an attack is successfully blocked
local function ApplyBlockReaction(attackerCharacter: Model, targetHumanoid: Humanoid, targetRoot: BasePart, combo: number)
	PlayRandomAnimation(targetHumanoid, animations.Block.Hit)
	PlaySound(sfx.Block, targetRoot)

	-- A fully-charged combo that gets blocked punishes the attacker with a brief stun,
	-- discouraging mindless spam of the final combo hit into a blocking opponent.
	if combo == 4 then
		local stun = Instance.new("BoolValue")
		stun.Name = "Stun"
		stun.Parent = attackerCharacter
		Debris:AddItem(stun, CachedConfig.Stun_Time)
	end
end

-- Spawns the hit particle effect at the target's position
local function SpawnHitEffects(targetRoot: BasePart)
	local fxClone = fxStorage.Hit:Clone()
	fxClone.Parent = workspace:WaitForChild("Fx")
	fxClone.CFrame = targetRoot.CFrame

	-- Micro-wait optimization to allow physical workspace parenting properties to finalize
	task.wait(0.01)
	for _, child in pairs(fxClone:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			child:Emit(10)
		end
	end
	Debris:AddItem(fxClone, FX_LIFETIME_SECONDS)
end

-- Creates the floating damage number above the target's head
local function SpawnDamageIndicator(targetCharacter: Model, damage: number, stunTime: number)
	local scriptSource = script:FindFirstChild("DamageIndicator")
	if not scriptSource then
		return
	end

	local dmgIndicator = scriptSource:Clone()
	dmgIndicator.Parent = targetCharacter
	dmgIndicator.ExtentsOffset = Vector3.new((math.random(-10, 10) / 10), 0.5, 0)
	dmgIndicator.Count.Text = "- " .. tostring(damage)

	TweenService:Create(
		dmgIndicator,
		TweenInfo.new(stunTime),
		{ ExtentsOffset = Vector3.new(dmgIndicator.ExtentsOffset.X, 1, 0) }
	):Play()
	Debris:AddItem(dmgIndicator, stunTime)
end

-- Flashes the target's model to make a successful hit more readable at a glance
local function SpawnHitHighlight(targetCharacter: Model, stunTime: number)
	local highlight = Instance.new("Highlight")
	highlight.OutlineTransparency = 1
	highlight.FillTransparency = 0
	highlight.FillColor = Color3.new(1, 0, 0)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = targetCharacter

	TweenService:Create(highlight, TweenInfo.new(stunTime), { FillTransparency = 1 }):Play()
	Debris:AddItem(highlight, stunTime)
end

-- Resolves the combo-finisher knockback/ragdoll behaviour for a given combat state
local function ApplyKnockback(attackerRoot: BasePart, targetCharacter: Model, targetHumanoid: Humanoid, targetRoot: BasePart, combatState: string)
	local velocity = Instance.new("BodyVelocity")
	velocity.MaxForce = Vector3.new(1, 1, 1) * math.huge

	local function ragdollOrFallbackAnimation()
		if CachedConfig.Ragdoll == true then
			task.spawn(function()
				ragdoll.Start(targetCharacter, CachedConfig.Ragdoll_Duration)
			end)
		else
			PlayRandomAnimation(targetHumanoid, animations.Dash.Back, 1.5)
		end
	end

	if combatState == "land" then
		velocity.Velocity = attackerRoot.CFrame.LookVector * 35
		velocity.Parent = targetRoot
		Debris:AddItem(velocity, 0.4)
		ragdollOrFallbackAnimation()

	elseif combatState == "air" then
		velocity.Velocity = (attackerRoot.CFrame.LookVector * 10) + Vector3.new(0, 35, 0)
		velocity.Parent = targetRoot
		Debris:AddItem(velocity, 0.15)

		if CachedConfig.Ragdoll == true then
			task.spawn(function()
				ragdoll.Start(targetCharacter, CachedConfig.Ragdoll_Duration)
			end)
		else
			velocity:Destroy() -- No aerial fallback animation; avoid leaving a dangling instance
		end
	else
		-- Default execution fallback if no airborne or landing flags match
		velocity:Destroy()
		ragdollOrFallbackAnimation()
	end
end

-- Handles everything that happens when an attack successfully lands
local function ApplyDamageReaction(attackerCharacter: Model, attackerRoot: BasePart, targetCharacter: Model, targetHumanoid: Humanoid, targetRoot: BasePart, damage: number, stunTime: number, combo: number, combatState: string)
	targetHumanoid:TakeDamage(damage)

	-- Apply runtime Stun tracking attribute object
	local targetStun = Instance.new("BoolValue")
	targetStun.Name = "Stun"
	targetStun.Parent = targetCharacter
	Debris:AddItem(targetStun, stunTime)

	PlaySound(sfx.Hit, targetRoot)
	SpawnHitEffects(targetRoot)
	SpawnDamageIndicator(targetCharacter, damage, stunTime)
	SpawnHitHighlight(targetCharacter, stunTime)

	if combo == 4 then
		ApplyKnockback(attackerRoot, targetCharacter, targetHumanoid, targetRoot, combatState)
	else
		-- Regular combo hit animations variations logic
		PlayRandomAnimation(targetHumanoid, animations.Hits)
	end
end

--[=[
    =======================================================================================
    7. CORE SYSTEM FUNCTIONS
    =======================================================================================
--]=]

-- Processes directional blocking validation and applies hit damage/effects. This is the
-- single entry point every incoming hit request is routed through.
function CombatServerManager.ProcessHit(
	attacker: Player,
	attackerCharacter: Model,
	targetCharacter: Model,
	damage: number,
	stunTime: number,
	combo: number,
	combatState: string
)
	-- Absolute validation checks to prevent runtime breaks on missing objects
	if not attackerCharacter or not targetCharacter then
		return
	end
	if not attackerCharacter:FindFirstChild("HumanoidRootPart") then
		return
	end
	if not IsValidTarget(targetCharacter) then
		return
	end

	local targetHumanoid = targetCharacter.Humanoid :: Humanoid
	local targetRoot = targetCharacter.HumanoidRootPart :: BasePart
	local attackerRoot = attackerCharacter.HumanoidRootPart :: BasePart

	-- If the target possesses an active Iframe status, terminate calculations early
	if targetCharacter:FindFirstChild("Iframe") then
		return
	end

	-- Anti-exploit gate: reject hits that are out of range or arriving faster than
	-- physically possible before any damage or effects are ever considered.
	if not IsWithinStrikingRange(attackerRoot, targetRoot) then
		return
	end
	if not PassesDebounce(attacker, targetCharacter) then
		return
	end

	-- Directional Blocking Logic via Vector Dot Product calculations
	if HasLineOfSightBlock(attackerRoot, targetCharacter, targetRoot) then
		ApplyBlockReaction(attackerCharacter, targetHumanoid, targetRoot, combo)
		return
	end

	ApplyDamageReaction(attackerCharacter, attackerRoot, targetCharacter, targetHumanoid, targetRoot, damage, stunTime, combo, combatState)
end

--[=[
    =======================================================================================
    8. NETWORK INTERFACE INITIALIZATION
    =======================================================================================
--]=]

-- Handles the "hit" action: iterates through every target the client claims to have hit,
-- and lets ProcessHit independently verify each one before anything is applied.
local function HandleHitAction(player: Player, character: Model, data: { [string]: any })
	if data.hits and next(data.hits) then
		for _, enemyChar in pairs(data.hits) do
			CombatServerManager.ProcessHit(
				player,
				character,
				enemyChar,
				CachedConfig.M1_Damage,
				CachedConfig.Stun_Time,
				data.combo,
				data.state
			)
		end
	else
		-- Apply self-punishment window if combo 4 missed cleanly
		if data.combo == 4 then
			local selfStun = Instance.new("BoolValue")
			selfStun.Name = "Stun"
			selfStun.Parent = character
			Debris:AddItem(selfStun, CachedConfig.Stun_Time)
		end
	end
end

-- Establish singular global event processing logic loop for player inputs
remotes.Combat.OnServerEvent:Connect(function(player: Player, data: { [string]: any })
	local character = player.Character
	if not character then
		return
	end

	-- Basic shape validation on the payload itself before branching on the action
	if typeof(data) ~= "table" or typeof(data.action) ~= "string" then
		return
	end

	if data.action == "hit" then
		HandleHitAction(player, character, data)

	elseif data.action == "block" then
		CombatServerManager.StartBlock(character)

	elseif data.action == "unblock" then
		CombatServerManager.StopBlock(character)

	elseif data.action == "evasive" then
		ragdoll.Stop(character)
	end
end)

--[=[
    =======================================================================================
    9. CLEANUP
    =======================================================================================
    Prevents recentHitPairs from growing unbounded over a long server session by clearing
    out entries once a player leaves.
--]=]
game:GetService("Players").PlayerRemoving:Connect(function(player: Player)
	for key in pairs(recentHitPairs) do
		if key:match("^" .. tostring(player.UserId) .. "_") then
			recentHitPairs[key] = nil
		end
	end
end)

return CombatServerManager