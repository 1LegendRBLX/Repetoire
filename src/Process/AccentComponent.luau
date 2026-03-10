--!strict

--[[
	possible future improvements:
		- global Accent scheduler (less threads)
		- remove task.delay() timers and switch to an _activeClones registry [store expire time]
]]

local Root = script.Parent.Parent.Parent

local Config = require("../Config")
local Promise = require(Root.Promise)
local Signal = require(Root.Signal)

local AccentComponent = {}
AccentComponent.__index = AccentComponent

local Builder = {}
Builder.__index = Builder

type Handler<T, P> = (T, P) -> ...any?

export type BuilderConfig<T, P> = {
	Handler: Handler<T, P>,
	Props: T,
	Connection: Signal.Connection?,
}

export type AccentComponent = typeof(setmetatable(
	{} :: {
		Instance: Instance,
		ClassName: string,
		ParentTo: Instance,
		Logging: boolean,

		OnSpawned: Signal.Signal<Instance>,
		OnDespawned: Signal.Signal<Instance>,
		OnTouched: Signal.Signal<Instance>,

		CloneStorage: { [Instance]: true },

		_actions: { [Handler<any, any>]: BuilderConfig<any, any> },
		_reactions: { [Signal.Signal<any>]: { BuilderConfig<any, any> } },
		_alive: boolean,
	},
	AccentComponent
))

export type Builder<P> = {
	new: (self: Builder<P>) -> Builder<P>,
	Hook: (self: Builder<P>, Sig: Signal.Signal<...any>) -> Builder<P>,
	Props: (self: Builder<P>, Props: P?) -> AccentComponent,

	Config: any,
	Accent: any,
}

function Builder.new<T, P>(Config: BuilderConfig<T, P>, Accent: AccentComponent): Builder<P>
	return setmetatable({
		Config = Config,
		Accent = Accent,
	}, Builder) :: any
end

function Builder.Hook<P>(self: Builder<P>, Sig: Signal.Signal<any>): Builder<P>
	local Accent = self.Accent

	Accent._reactions[Sig] = Accent._reactions[Sig] or {}
	table.insert(Accent._reactions[Sig], self.Config)

	return self
end

function Builder.Props<P>(self: Builder<P>, Props: P): AccentComponent
	self.Config.Props = Props
	return self.Accent
end

function AccentComponent.new(Target: Instance, Settings: any?): AccentComponent
	local MergedSettings = {}

	for k, v in Config.Settings :: any do
		MergedSettings[k] = Settings and Settings[k] or v
	end

	return setmetatable({
		Instance = Target:Clone(),
		ClassName = Target.ClassName,
		Settings = MergedSettings,
		Logging = MergedSettings.Logging or false,

		ParentTo = workspace :: Instance,

		OnSpawned = Signal.new(),
		OnDespawned = Signal.new(),
		OnTouched = Signal.new(),

		CloneStorage = {},

		_actions = {},
		_reactions = {},
		_alive = true,
	}, AccentComponent)
end

function AccentComponent.AddAction<T, P>(self: AccentComponent, Handler: Handler<T, P>): Builder<P>
	local ConfigData = {
		Handler = Handler,
		Connection = nil,
		Props = nil :: any,
	}

	self._actions[Handler] = ConfigData

	return Builder.new(ConfigData, self)
end

function AccentComponent.AddReaction<T, P>(self: AccentComponent, Handler: Handler<T, P>): Builder<P>
	local ConfigData = {
		Handler = Handler,
		Connection = nil,
		Props = nil :: any,
	}

	return Builder.new(ConfigData, self)
end

function AccentComponent.Spawn(self: AccentComponent, position: Vector3, parent: Instance?): Promise.Promise
	if not self._alive then
		return Promise.reject("Accent destroyed")
	end

	if self.Logging then
		print("[Accent] Spawn requested")
	end

	return Promise.try(function()
		self.ParentTo = parent or self.ParentTo

		local count = self:_runAction(Config.Actions.RandomCount) or 1
		local lifetime = self:_runAction(Config.Actions.RandomLifetime) or 5

		for i = 1, count do
			local Clone = self:_clone(position)
			Clone.Parent = self.ParentTo

			if self.Logging then
				print("[Accent] Clone spawned")
			end

			self.OnSpawned:Fire(Clone)

			self:_executeReactions(self.OnSpawned, Clone)
				:andThen(function()
					self.OnSpawned:Fire(Clone)
				end)
				:catch(warn)

			task.delay(lifetime, function()
				if not self._alive then
					return
				end

				if self.CloneStorage[Clone] then
					self:Despawn(Clone)
				end
			end)
		end
	end)
end

function AccentComponent.Despawn(self: AccentComponent, Target: Instance): Promise.Promise?
	if not self.CloneStorage[Target] then
		return nil
	end

	if self.Logging then
		print("[Accent] Despawn requested:", Target)
	end

	self.CloneStorage[Target] = nil
	self.OnDespawned:Fire(Target)

	return self:_executeReactions(self.OnDespawned, Target):timeout(5):finally(function()
		if self.Logging then
			print("[Accent] Despawn reactions complete:", Target)
		end

		if not self._alive then
			return
		end

		self.OnDespawned:Fire(Target)

		if Target then
			Target:Destroy()
		end
	end)
end

function AccentComponent.Destroy(self: AccentComponent)
	if not self._alive then
		return
	end

	self._alive = true

	for clone in self.CloneStorage do
		if not clone then
			continue
		end
		clone:Destroy()
	end

	self.OnDespawned:Destroy()
	self.OnSpawned:Destroy()
	self.OnTouched:Destroy()

	table.clear(self :: any)
	setmetatable(self :: any, nil)
end

function AccentComponent._executeReactions(
	self: AccentComponent,
	Sig: Signal.Signal<any>,
	Target: Instance
): Promise.Promise
	local Reactions = self._reactions[Sig]

	if not Reactions then
		return Promise.resolve()
	end

	if self.Logging then
		print("[Accent] Executing reactions:", #Reactions)
	end

	local Promises = table.create(#Reactions) :: { Promise.Promise }

	for _, Reaction in Reactions do
		table.insert(Promises :: any, Promise.try(Reaction.Handler, Target, Reaction.Props))
	end

	return Promise.all(Promises):andThen(function()
		if self.Logging then
			print("[Accent] All reactions finished:", Target)
		end
	end)
end

function AccentComponent._runAction(self: AccentComponent, Handler: Handler<any, any>): ...any?
	local Data = self._actions[Handler]

	if not Data then
		return nil
	end

	return Handler(nil :: any, Data.Props)
end

function AccentComponent._clone(self: AccentComponent, Position: Vector3): Instance
	local Clone = self.Instance:Clone()

	if Clone:IsA("BasePart") then
		Clone.Position = Position
	elseif Clone:IsA("Model") then
		Clone:PivotTo(CFrame.new(Position))
	end

	self.CloneStorage[Clone] = true

	return Clone
end

return {
	new = AccentComponent.new,
}
