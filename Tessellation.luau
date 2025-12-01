--!strict
--[[
	TESSELLATION ANIMATION KERNEL v2.0
	
	WHY THIS EXISTS:
	
	Roblox's animation system is powerful but leaves critical gaps that make production-level
	animation management fragile and error-prone. This kernel exists to solve fundamental issues:
	
	1. STATE COHERENCE: Roblox doesn't track animation state reliably across respawns, character
	   reloads, or animator recreation. Games crash or produce ghost animations because there's
	   no central authority managing lifecycle.
	
	2. PRIORITY CONFLICTS: The AnimationTrack priority system is manual and conflict-prone.
	   Playing a walk cycle shouldn't require manually stopping 12 other animations. This kernel
	   provides intelligent priority-based stopping and conflict resolution.
	
	3. NO BATCHING: Playing synchronized animation sets (idle + facial + breathing) requires
	   fragile manual coordination. Groups solve this by treating multiple animations as a
	   single atomic unit with shared configuration.
	
	4. DEBUGGING NIGHTMARE: When animations break, you get no visibility into what went wrong.
	   Track not loading? Animator missing? Animation object deleted? The kernel provides
	   observability through a debug pipeline that logs the entire animation lifecycle.
	
	5. MEMORY LEAKS: Connections to MarkerReached signals and old tracks pile up over time.
	   The kernel manages cleanup and ensures proper destruction through a centralized
	   connection registry.
	
	6. BOILERPLATE HELL: Every game rewrites the same "load animator, cache tracks, handle
	   respawn" logic. This kernel is that boilerplate, hardened through production use.
	
	The "kernel" pattern means this is a single source of truth for all animation operations.
	It sits between your game logic and Roblox's animation API, intercepting every call to
	enforce consistency, provide debugging, and handle edge cases you'd otherwise miss.
	
]]

local RunService = game:GetService("RunService")

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	CENTRALIZED CONFIGURATION
	═══════════════════════════════════════════════════════════════════════════
]]

export type KernelConfig = {
	-- Default playback settings
	defaultFadeTime: number?,
	defaultWeight: number?,
	defaultSpeed: number?,
	defaultPriority: Enum.AnimationPriority?,
	defaultLooped: boolean?,

	-- Priority resolution strategy
	priorityStrategy: ("aggressive" | "conservative" | "manual")?,
	priorityThreshold: number?, -- Only stop tracks this many priority levels below

	-- Debug settings
	debugMode: boolean?,
	debugThrottleMs: number?, -- Minimum time between debug events (0 = no throttle)
	debugBatchSize: number?, -- Batch events before emitting (1 = no batching)

	-- Performance settings
	maxCachedTracks: number?, -- Limit track cache size (0 = unlimited)
	validateMarkers: boolean?, -- Check if markers exist before binding

	-- Error recovery
	autoRetryLoads: boolean?, -- Retry failed track loads once
	gracefulDegradation: boolean?, -- Continue on errors instead of failing
}

local DEFAULT_CONFIG: KernelConfig = {
	defaultFadeTime = 0.2,
	defaultWeight = 1,
	defaultSpeed = 1,
	defaultPriority = Enum.AnimationPriority.Action,
	defaultLooped = false,

	priorityStrategy = "aggressive",
	priorityThreshold = 0,

	debugMode = false,
	debugThrottleMs = 16, -- ~60fps
	debugBatchSize = 1,

	maxCachedTracks = 50,
	validateMarkers = true,

	autoRetryLoads = true,
	gracefulDegradation = true,
}

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	TYPE SYSTEM
	═══════════════════════════════════════════════════════════════════════════
]]

export type DebugEventType = "TRACK_LOAD" | "TRACK_PLAY" | "TRACK_STOP" | "TRACK_ADJUST" |"GROUP_CREATE" | "GROUP_PLAY" | "MARKER_BIND" | "MARKER_FIRE" | "MARKER_INVALID" |
	"ANIMATOR_CREATE" | "ANIMATOR_LOST" |
	"CHARACTER_RESPAWN" | "CLEANUP" | "CACHE_EVICT" |
	"ERROR_MISSING_ANIMATION" | "ERROR_LOAD_FAILED" | "ERROR_NO_ANIMATOR" |
	"ERROR_INVALID_CONFIG" | "ERROR_MARKER_MISSING"

export type DebugEvent = {
	type: DebugEventType,
	timestamp: number,
	animationName: string?,
	details: string?,
	success: boolean?,
	severity: ("info" | "warning" | "error")?,
}

export type DebugCallback = (event: DebugEvent) -> ()

export type TessellationConfig = {
	fadeTime: number?,
	weight: number?,
	speed: number?,
	priority: Enum.AnimationPriority?,
	looped: boolean?,
	stopOthers: boolean?,
}

type AnimationGroup = {
	name: string,
	members: {string},
	defaultConfig: TessellationConfig,
	validated: boolean,
}

export type KernelStats = {
	tracksLoaded: number,
	tracksActive: number,
	tracksCached: number,
	tracksEvicted: number,
	groupsRegistered: number,
	markersRegistered: number,
	animatorRecreations: number,
	errorCount: number,
	lastError: string?,
}

export type PriorityStrategy = "aggressive" | "conservative" | "manual"

export type Tessellation = {
	-- Core Properties
	Player: Player,
	Character: Model,
	Animator: Animator?,
	AnimationsFolder: Folder,
	Config: KernelConfig,

	-- Private Kernel State
	_animations: {[string]: Animation},
	_tracks: {[string]: AnimationTrack},
	_trackAccessOrder: {string}, -- LRU cache tracking
	_groups: {[string]: AnimationGroup},
	_connections: {[string]: RBXScriptConnection},
	_debugSubscribers: {DebugCallback},
	_debugBatch: {DebugEvent},
	_lastDebugEmit: number,
	_stats: KernelStats,
	_loadRetries: {[string]: number},

	-- Public API
	Play: (self: Tessellation, name: string, config: TessellationConfig?) -> AnimationTrack?,
	Stop: (self: Tessellation, name: string, fadeTime: number?) -> (),
	Adjust: (self: Tessellation, name: string, speed: number?, weight: number?, fade: number?) -> (),
	IsPlaying: (self: Tessellation, name: string) -> boolean,
	StopAll: (self: Tessellation, fadeTime: number?) -> (),

	CreateGroup: (self: Tessellation, name: string, members: {string}, defaultConfig: TessellationConfig?) -> (),
	PlayGroup: (self: Tessellation, name: string, config: TessellationConfig?) -> {[string]: AnimationTrack?},
	StopGroup: (self: Tessellation, name: string, fadeTime: number?) -> (),

	BindMarker: (self: Tessellation, animName: string, markerName: string, callback: () -> ()) -> (),
	GetStats: (self: Tessellation) -> KernelStats,
	SubscribeToDebug: (self: Tessellation, callback: DebugCallback) -> () -> (),
	UpdateConfig: (self: Tessellation, newConfig: KernelConfig) -> (),
	FlushDebugBatch: (self: Tessellation) -> (),

	Destroy: (self: Tessellation) -> (),

	-- Kernel Internal Methods
	_GetAnimator: (self: Tessellation) -> Animator?,
	_GetTrack: (self: Tessellation, name: string) -> AnimationTrack?,
	_LoadAnimationObjects: (self: Tessellation) -> (),
	_HookCharacter: (self: Tessellation) -> (),
	_EmitDebug: (self: Tessellation, event: DebugEvent) -> (),
	_ValidateGroup: (self: Tessellation, group: AnimationGroup) -> boolean,
	_UpdateStats: (self: Tessellation) -> (),
	_ShouldStopTrack: (self: Tessellation, track: AnimationTrack, newPriority: Enum.AnimationPriority) -> boolean,
	_EvictOldestTrack: (self: Tessellation) -> (),
	_MergeConfig: (self: Tessellation, base: TessellationConfig, override: TessellationConfig?) -> TessellationConfig,
	_ValidateMarkerExists: (self: Tessellation, track: AnimationTrack, markerName: string) -> boolean,
}

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	UTILITIES
	═══════════════════════════════════════════════════════════════════════════
]]

local function mergeKernelConfig(base: KernelConfig, override: KernelConfig?): KernelConfig
	if not override then return table.clone(base) end

	local result: KernelConfig = table.clone(base)
	if override.defaultFadeTime ~= nil then result.defaultFadeTime = override.defaultFadeTime end
	if override.defaultWeight ~= nil then result.defaultWeight = override.defaultWeight end
	if override.defaultSpeed ~= nil then result.defaultSpeed = override.defaultSpeed end
	if override.defaultPriority ~= nil then result.defaultPriority = override.defaultPriority end
	if override.defaultLooped ~= nil then result.defaultLooped = override.defaultLooped end
	if override.priorityStrategy ~= nil then result.priorityStrategy = override.priorityStrategy end
	if override.priorityThreshold ~= nil then result.priorityThreshold = override.priorityThreshold end
	if override.debugMode ~= nil then result.debugMode = override.debugMode end
	if override.debugThrottleMs ~= nil then result.debugThrottleMs = override.debugThrottleMs end
	if override.debugBatchSize ~= nil then result.debugBatchSize = override.debugBatchSize end
	if override.maxCachedTracks ~= nil then result.maxCachedTracks = override.maxCachedTracks end
	if override.validateMarkers ~= nil then result.validateMarkers = override.validateMarkers end
	if override.autoRetryLoads ~= nil then result.autoRetryLoads = override.autoRetryLoads end
	if override.gracefulDegradation ~= nil then result.gracefulDegradation = override.gracefulDegradation end

	return result
end

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	KERNEL INITIALIZATION
	═══════════════════════════════════════════════════════════════════════════
]]

local Tessellation = {}
Tessellation.__index = Tessellation

function Tessellation.new(
	animationsFolder: Folder, 
	player: Player, 
	config: KernelConfig?
): Tessellation
	local finalConfig = mergeKernelConfig(DEFAULT_CONFIG, config)

	local self = setmetatable({
		Player = player,
		Character = player.Character or player.CharacterAdded:Wait(),
		Animator = nil :: Animator?,
		AnimationsFolder = animationsFolder,
		Config = finalConfig,

		_animations = {} :: {[string]: Animation},
		_tracks = {} :: {[string]: AnimationTrack},
		_trackAccessOrder = {} :: {string},
		_groups = {} :: {[string]: AnimationGroup},
		_connections = {} :: {[string]: RBXScriptConnection},
		_debugSubscribers = {} :: {DebugCallback},
		_debugBatch = {} :: {DebugEvent},
		_lastDebugEmit = 0,
		_loadRetries = {} :: {[string]: number},
		_stats = {
			tracksLoaded = 0,
			tracksActive = 0,
			tracksCached = 0,
			tracksEvicted = 0,
			groupsRegistered = 0,
			markersRegistered = 0,
			animatorRecreations = 0,
			errorCount = 0,
			lastError = nil,
		} :: KernelStats,
	}, Tessellation) :: any

	local typedSelf = self :: Tessellation
	typedSelf:_LoadAnimationObjects()
	typedSelf:_HookCharacter()

	typedSelf:_EmitDebug({
		type = "ANIMATOR_CREATE",
		timestamp = os.clock(),
		details = "Kernel initialized",
		success = true,
		severity = "info",
	})

	return typedSelf
end

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	KERNEL INTERNAL SYSTEMS
	═══════════════════════════════════════════════════════════════════════════
]]

function Tessellation:_EmitDebug(event: DebugEvent)
	local self = self :: Tessellation

	if not self.Config.debugMode then return end

	-- Set default severity
	if not event.severity then
		if event.type:match("^ERROR_") then
			event.severity = "error"
		elseif event.type:match("INVALID") or event.type:match("MISSING") then
			event.severity = "warning"
		else
			event.severity = "info"
		end
	end

	-- Track errors in stats
	if event.severity == "error" then
		self._stats.errorCount += 1
		self._stats.lastError = event.details or event.type
	end

	-- Add to batch
	table.insert(self._debugBatch, event)

	-- Check if we should emit now
	local batchSize = self.Config.debugBatchSize or 1
	local throttleMs = self.Config.debugThrottleMs or 0
	local now = os.clock() * 1000
	local timeSinceLastEmit = now - self._lastDebugEmit

	local shouldEmit = #self._debugBatch >= batchSize or 
		timeSinceLastEmit >= throttleMs or
		event.severity == "error" -- Always emit errors immediately

	if shouldEmit then
		self:FlushDebugBatch()
	end
end

function Tessellation:FlushDebugBatch()
	local self = self :: Tessellation

	if #self._debugBatch == 0 then return end

	-- Broadcast all batched events
	for _, event in ipairs(self._debugBatch) do
		for _, callback in ipairs(self._debugSubscribers) do
			task.spawn(callback, event)
		end

		-- Console output for errors/warnings
		if event.severity == "error" then
			warn(`[Tessellation] {event.type}: {event.details or "No details"}`)
		elseif event.severity == "warning" then
			warn(`[Tessellation] {event.type}: {event.details or ""}`)
		end
	end

	table.clear(self._debugBatch)
	self._lastDebugEmit = os.clock() * 1000
end

function Tessellation:_UpdateStats()
	local self = self :: Tessellation

	local active = 0
	for _, track in pairs(self._tracks) do
		if track.IsPlaying then
			active += 1
		end
	end

	self._stats.tracksActive = active
	self._stats.tracksCached = 0
	for _ in pairs(self._tracks) do
		self._stats.tracksCached += 1
	end
	self._stats.tracksLoaded = self._stats.tracksCached + self._stats.tracksEvicted
end

function Tessellation:_HookCharacter()
	local self = self :: Tessellation

	local function onCharacterAdded(char: Model)
		self:FlushDebugBatch() -- Ensure previous events are emitted

		self:_EmitDebug({
			type = "CHARACTER_RESPAWN",
			timestamp = os.clock(),
			details = `Character respawned, clearing {self._stats.tracksCached} tracks`,
			success = true,
			severity = "info",
		})

		self.Character = char
		self.Animator = nil

		-- Clean up old tracks with error handling
		for name, track in pairs(self._tracks) do
			local success = pcall(function()
				track:Stop(0)
				track:Destroy()
			end)
			if not success and self.Config.gracefulDegradation then
				self:_EmitDebug({
					type = "CLEANUP",
					timestamp = os.clock(),
					animationName = name,
					details = "Failed to clean up track on respawn",
					success = false,
					severity = "warning",
				})
			end
		end

		table.clear(self._tracks)
		table.clear(self._trackAccessOrder)
		table.clear(self._loadRetries)
		self._stats.animatorRecreations += 1
		self:_GetAnimator()
		self:_UpdateStats()
	end

	if self.Player.Character then
		onCharacterAdded(self.Player.Character)
	end

	self._connections["CharAdded"] = self.Player.CharacterAdded:Connect(onCharacterAdded)
end

function Tessellation:_LoadAnimationObjects()
	local self = self :: Tessellation

	table.clear(self._animations)
	local count = 0

	local success, err = pcall(function()
		for _, child in ipairs(self.AnimationsFolder:GetChildren()) do
			if child:IsA("Animation") then
				self._animations[child.Name] = child
				count += 1
			end
		end
	end)

	if not success then
		self:_EmitDebug({
			type = "ERROR_LOAD_FAILED",
			timestamp = os.clock(),
			details = `Failed to load animations: {err}`,
			success = false,
			severity = "error",
		})
		return
	end

	self:_EmitDebug({
		type = "ANIMATOR_CREATE",
		timestamp = os.clock(),
		details = `Loaded {count} animation objects`,
		success = true,
		severity = "info",
	})
end

function Tessellation:_GetAnimator(): Animator?
	local self = self :: Tessellation

	if self.Animator and self.Animator.Parent then 
		return self.Animator 
	end

	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then 
		self:_EmitDebug({
			type = "ERROR_NO_ANIMATOR",
			timestamp = os.clock(),
			details = "No Humanoid found in Character",
			success = false,
			severity = "error",
		})
		return nil 
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local success, result = pcall(function()
			local newAnimator = Instance.new("Animator")
			newAnimator.Parent = humanoid
			return newAnimator
		end)

		if not success then
			self:_EmitDebug({
				type = "ERROR_NO_ANIMATOR",
				timestamp = os.clock(),
				details = "Failed to create Animator instance",
				success = false,
				severity = "error",
			})
			return nil
		end

		animator = result

		self:_EmitDebug({
			type = "ANIMATOR_CREATE",
			timestamp = os.clock(),
			details = "Created new Animator instance",
			success = true,
			severity = "info",
		})
	end

	self.Animator = animator
	return self.Animator
end

function Tessellation:_EvictOldestTrack()
	local self = self :: Tessellation

	if #self._trackAccessOrder == 0 then return end

	local oldestName = table.remove(self._trackAccessOrder, 1)
	local oldTrack = self._tracks[oldestName]

	if oldTrack then
		pcall(function()
			oldTrack:Stop(0)
			oldTrack:Destroy()
		end)
		self._tracks[oldestName] = nil
		self._stats.tracksEvicted += 1

		self:_EmitDebug({
			type = "CACHE_EVICT",
			timestamp = os.clock(),
			animationName = oldestName,
			details = `Evicted track from cache (limit: {self.Config.maxCachedTracks})`,
			success = true,
			severity = "info",
		})
	end
end

function Tessellation:_GetTrack(name: string): AnimationTrack?
	local self = self :: Tessellation

	-- Return cached track if available
	if self._tracks[name] then
		-- Update LRU order
		local index = table.find(self._trackAccessOrder, name)
		if index then
			table.remove(self._trackAccessOrder, index)
		end
		table.insert(self._trackAccessOrder, name)

		return self._tracks[name]
	end

	local animObject = self._animations[name]
	if not animObject then
		self:_EmitDebug({
			type = "ERROR_MISSING_ANIMATION",
			timestamp = os.clock(),
			animationName = name,
			details = `Animation object '{name}' not found in folder`,
			success = false,
			severity = "error",
		})
		return nil
	end

	local animator = self:_GetAnimator()
	if not animator then return nil end

	local success, track = pcall(function()
		return animator:LoadAnimation(animObject)
	end)

	if success and track then
		-- Check cache limit
		local maxCache = self.Config.maxCachedTracks or 50
		if maxCache > 0 and self._stats.tracksCached >= maxCache then
			self:_EvictOldestTrack()
		end

		self._tracks[name] = track :: AnimationTrack
		table.insert(self._trackAccessOrder, name)

		self:_EmitDebug({
			type = "TRACK_LOAD",
			timestamp = os.clock(),
			animationName = name,
			details = `Track loaded successfully`,
			success = true,
			severity = "info",
		})

		self:_UpdateStats()
		return track :: AnimationTrack
	end

	-- Retry logic
	if self.Config.autoRetryLoads then
		local retries = self._loadRetries[name] or 0
		if retries < 1 then
			self._loadRetries[name] = retries + 1
			task.wait(0.1)
			return self:_GetTrack(name)
		end
	end

	self:_EmitDebug({
		type = "ERROR_LOAD_FAILED",
		timestamp = os.clock(),
		animationName = name,
		details = `Failed to load animation track after retries`,
		success = false,
		severity = "error",
	})

	return nil
end

function Tessellation:_ValidateGroup(group: AnimationGroup): boolean
	local self = self :: Tessellation

	if group.validated then return true end

	local allValid = true
	for _, animName in ipairs(group.members) do
		if not self._animations[animName] then
			self:_EmitDebug({
				type = "ERROR_MISSING_ANIMATION",
				timestamp = os.clock(),
				animationName = animName,
				details = `Group '{group.name}' references missing animation '{animName}'`,
				success = false,
				severity = "error",
			})
			allValid = false
		end
	end

	group.validated = allValid
	return allValid
end

function Tessellation:_ShouldStopTrack(track: AnimationTrack, newPriority: Enum.AnimationPriority): boolean
	local self = self :: Tessellation

	local strategy = self.Config.priorityStrategy or "aggressive"
	local threshold = self.Config.priorityThreshold or 0

	if strategy == "manual" then
		return false
	elseif strategy == "conservative" then
		-- Only stop if new priority is significantly higher
		return track.Priority.Value + threshold < newPriority.Value
	else -- aggressive
		-- Stop if new priority is equal or higher
		return track.Priority.Value + threshold <= newPriority.Value
	end
end

function Tessellation:_MergeConfig(base: TessellationConfig, override: TessellationConfig?): TessellationConfig
	local self = self :: Tessellation

	local result: TessellationConfig = {}

	-- Start with kernel defaults
	result.fadeTime = self.Config.defaultFadeTime
	result.weight = self.Config.defaultWeight
	result.speed = self.Config.defaultSpeed
	result.priority = self.Config.defaultPriority
	result.looped = self.Config.defaultLooped
	result.stopOthers = true

	-- Apply base config
	if base.fadeTime ~= nil then result.fadeTime = base.fadeTime end
	if base.weight ~= nil then result.weight = base.weight end
	if base.speed ~= nil then result.speed = base.speed end
	if base.priority ~= nil then result.priority = base.priority end
	if base.looped ~= nil then result.looped = base.looped end
	if base.stopOthers ~= nil then result.stopOthers = base.stopOthers end

	-- Apply override
	if override then
		if override.fadeTime ~= nil then result.fadeTime = override.fadeTime end
		if override.weight ~= nil then result.weight = override.weight end
		if override.speed ~= nil then result.speed = override.speed end
		if override.priority ~= nil then result.priority = override.priority end
		if override.looped ~= nil then result.looped = override.looped end
		if override.stopOthers ~= nil then result.stopOthers = override.stopOthers end
	end

	return result
end

function Tessellation:_ValidateMarkerExists(track: AnimationTrack, markerName: string): boolean
	local self = self :: Tessellation

	if not self.Config.validateMarkers then return true end

	local markers = track:GetMarkerReachedSignal(markerName)
	if not markers then
		self:_EmitDebug({
			type = "ERROR_MARKER_MISSING",
			timestamp = os.clock(),
			details = `Marker '{markerName}' does not exist in animation`,
			success = false,
			severity = "warning",
		})
		return false
	end

	return true
end

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	PUBLIC API - SINGLE TRACK OPERATIONS
	═══════════════════════════════════════════════════════════════════════════
]]

function Tessellation:Play(name: string, config: TessellationConfig?): AnimationTrack?
	local self = self :: Tessellation
	
	
	local track = self:_GetTrack(name)
	if not track then return nil end

	-- Merge configurations
	local finalConfig = self:_MergeConfig({}, config)

	local fade = finalConfig.fadeTime or 0.2
	local weight = finalConfig.weight or 1
	local speed = finalConfig.speed or 1
	local priority = finalConfig.priority or track.Priority
	local looped = if finalConfig.looped ~= nil then finalConfig.looped else track.Looped
	local stopOthers = if finalConfig.stopOthers ~= nil then finalConfig.stopOthers else true

	track.Priority = priority
	track.Looped = looped

	-- Configurable priority-based conflict resolution
	if stopOthers then
		local animator = self:_GetAnimator()
		if animator then
			local stoppedCount = 0
			for _, otherTrack in ipairs(animator:GetPlayingAnimationTracks()) do
				if otherTrack ~= track and self:_ShouldStopTrack(otherTrack, priority) then
					otherTrack:Stop(fade)
					stoppedCount += 1
				end
			end

			if stoppedCount > 0 then
				self:_EmitDebug({
					type = "TRACK_STOP",
					timestamp = os.clock(),
					animationName = name,
					details = `Stopped {stoppedCount} conflicting tracks (strategy: {self.Config.priorityStrategy})`,
					success = true,
					severity = "info",
				})
			end
		end
	end

	track:Play(fade, weight, speed)

	self:_EmitDebug({
		type = "TRACK_PLAY",
		timestamp = os.clock(),
		animationName = name,
		details = `Playing (fade={fade}, weight={weight}, speed={speed}, priority={priority.Name})`,
		success = true,
		severity = "info",
	})

	self:_UpdateStats()
	return track
end

function Tessellation:Stop(name: string, fadeTime: number?)
	local self = self :: Tessellation

	local track = self._tracks[name]
	if track and track.IsPlaying then
		local fade = fadeTime or self.Config.defaultFadeTime or 0.2
		track:Stop(fade)

		self:_EmitDebug({
			type = "TRACK_STOP",
			timestamp = os.clock(),
			animationName = name,
			details = `Stopped with fade={fade}`,
			success = true,
			severity = "info",
		})

		self:_UpdateStats()
	end
end

function Tessellation:StopAll(fadeTime: number?)
	local self = self :: Tessellation

	local fade = fadeTime or self.Config.defaultFadeTime or 0.2
	local stoppedCount = 0

	for name, track in pairs(self._tracks) do
		if track.IsPlaying then
			local success = pcall(function()
				track:Stop(fade)
			end)
			if success then
				stoppedCount += 1
			elseif not self.Config.gracefulDegradation then
				return
			end
		end
	end

	self:_EmitDebug({
		type = "TRACK_STOP",
		timestamp = os.clock(),
		details = `Stopped all {stoppedCount} playing tracks`,
		success = true,
		severity = "info",
	})

	self:_UpdateStats()
end

function Tessellation:Adjust(name: string, speed: number?, weight: number?, fade: number?)
	local self = self :: Tessellation

	local track = self._tracks[name]
	if track and track.IsPlaying then
		local adjustFade = fade or 0.1
		if speed then track:AdjustSpeed(speed) end
		if weight then track:AdjustWeight(weight, adjustFade) end

		self:_EmitDebug({
			type = "TRACK_ADJUST",
			timestamp = os.clock(),
			animationName = name,
			details = `Adjusted (speed={speed or "nil"}, weight={weight or "nil"})`,
			success = true,
			severity = "info",
		})
	end
end

function Tessellation:IsPlaying(name: string): boolean
	local self = self :: Tessellation

	local track = self._tracks[name]
	return (track ~= nil and track.IsPlaying)
end

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	PUBLIC API - GROUP OPERATIONS
	═══════════════════════════════════════════════════════════════════════════
]]

function Tessellation:CreateGroup(name: string, members: {string}, defaultConfig: TessellationConfig?)
	local self = self :: Tessellation

	local group: AnimationGroup = {
		name = name,
		members = members,
		defaultConfig = defaultConfig or {},
		validated = false,
	}

	self._groups[name] = group
	self._stats.groupsRegistered += 1

	-- Validate immediately
	self:_ValidateGroup(group)

	self:_EmitDebug({
		type = "GROUP_CREATE",
		timestamp = os.clock(),
		details = `Group '{name}' created with {#members} members`,
		success = true,
		severity = "info",
	})
end

function Tessellation:PlayGroup(name: string, config: TessellationConfig?): {[string]: AnimationTrack?}
	local self = self :: Tessellation

	local group = self._groups[name]
	if not group then 
		self:_EmitDebug({
			type = "ERROR_MISSING_ANIMATION",
			timestamp = os.clock(),
			details = `Group '{name}' not found`,
			success = false,
			severity = "error",
		})
		return {} 
	end

	-- Validate group before playing
	if not self:_ValidateGroup(group) then
		if not self.Config.gracefulDegradation then
			return {}
		end
	end

	-- Merge group config with override
	local finalConfig = self:_MergeConfig(group.defaultConfig, config)

	local playedTracks: {[string]: AnimationTrack?} = {}
	local successCount = 0

	for _, animName in ipairs(group.members) do
		local track = self:Play(animName, finalConfig)
		playedTracks[animName] = track
		if track then successCount += 1 end
	end

	self:_EmitDebug({
		type = "GROUP_PLAY",
		timestamp = os.clock(),
		details = `Group '{name}' played {successCount}/{#group.members} animations`,
		success = successCount == #group.members,
		severity = if successCount == #group.members then "info" else "warning",
	})

	return playedTracks
end

function Tessellation:StopGroup(name: string, fadeTime: number?)
	local self = self :: Tessellation

	local group = self._groups[name]
	if not group then return end

	local fade = fadeTime or self.Config.defaultFadeTime or 0.2
	for _, animName in ipairs(group.members) do
		self:Stop(animName, fade)
	end
end

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	PUBLIC API - MARKERS & OBSERVABILITY
	═══════════════════════════════════════════════════════════════════════════
]]

function Tessellation:BindMarker(animName: string, markerName: string, callback: () -> ())
	local self = self :: Tessellation

	local track = self:_GetTrack(animName)
	if not track then return end

	-- Validate marker exists
	if not self:_ValidateMarkerExists(track, markerName) then
		if not self.Config.gracefulDegradation then
			return
		end
	end

	local key = `Marker_{animName}_{markerName}`

	-- Disconnect old binding if exists
	if self._connections[key] then
		self._connections[key]:Disconnect()
	end

	local success, connection = pcall(function()
		return track:GetMarkerReachedSignal(markerName):Connect(function()
			self:_EmitDebug({
				type = "MARKER_FIRE",
				timestamp = os.clock(),
				animationName = animName,
				details = `Marker '{markerName}' reached`,
				success = true,
				severity = "info",
			})
			callback()
		end)
	end)

	if not success then
		self:_EmitDebug({
			type = "ERROR_MARKER_MISSING",
			timestamp = os.clock(),
			animationName = animName,
			details = `Failed to bind marker '{markerName}'`,
			success = false,
			severity = "error",
		})
		return
	end

	self._connections[key] = connection
	self._stats.markersRegistered += 1

	self:_EmitDebug({
		type = "MARKER_BIND",
		timestamp = os.clock(),
		animationName = animName,
		details = `Bound callback to marker '{markerName}'`,
		success = true,
		severity = "info",
	})
end

function Tessellation:SubscribeToDebug(callback: DebugCallback): () -> ()
	local self = self :: Tessellation

	table.insert(self._debugSubscribers, callback)

	-- Return unsubscribe function
	return function()
		local index = table.find(self._debugSubscribers, callback)
		if index then
			table.remove(self._debugSubscribers, index)
		end
	end
end

function Tessellation:GetStats(): KernelStats
	local self = self :: Tessellation
	self:_UpdateStats()
	return table.clone(self._stats)
end

function Tessellation:UpdateConfig(newConfig: KernelConfig)
	local self = self :: Tessellation

	self.Config = mergeKernelConfig(self.Config, newConfig)

	self:_EmitDebug({
		type = "ANIMATOR_CREATE",
		timestamp = os.clock(),
		details = "Kernel configuration updated",
		success = true,
		severity = "info",
	})
end

--[[ 
	═══════════════════════════════════════════════════════════════════════════
	KERNEL CLEANUP
	═══════════════════════════════════════════════════════════════════════════
]]

function Tessellation:Destroy()
	local self = self :: Tessellation

	self:FlushDebugBatch() -- Emit any pending events

	self:_EmitDebug({
		type = "CLEANUP",
		timestamp = os.clock(),
		details = `Destroying kernel (tracks={self._stats.tracksCached}, groups={self._stats.groupsRegistered})`,
		success = true,
		severity = "info",
	})

	self:FlushDebugBatch() -- Ensure cleanup event is sent

	-- Disconnect all event connections
	for key, conn in pairs(self._connections) do
		local success = pcall(function()
			conn:Disconnect()
		end)
		if not success and not self.Config.gracefulDegradation then
			warn(`[Tessellation] Failed to disconnect {key}`)
		end
	end

	-- Stop and destroy all tracks
	for name, track in pairs(self._tracks) do
		pcall(function()
			track:Stop(0)
			track:Destroy()
		end)
	end

	-- Clear all kernel state
	table.clear(self._tracks)
	table.clear(self._trackAccessOrder)
	table.clear(self._animations)
	table.clear(self._groups)
	table.clear(self._connections)
	table.clear(self._debugSubscribers)
	table.clear(self._debugBatch)
	table.clear(self._loadRetries)

	setmetatable(self :: any, nil)
end

return Tessellation
