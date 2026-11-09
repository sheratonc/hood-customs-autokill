-- Hood Customs Free For All — Autokill
-- UI: LinoriaLib (violin-suzutsuki fork)
-- Combat routes through a single remote: ReplicatedStorage.MainEvent:FireServer(action, ...)
--
-- "Shoot" is CLIENT-AUTHORITATIVE hit reg. You raycast locally and tell the server which model/part
-- you hit; it trusts the descriptor. Payload:
--   { ORIGIN=Vector3, AIM=Vector3, INDEX=number, HITS={ { PELLET, MODEL, PART, POSITION }, ... } }
--   INDEX must mirror the gun framework's shared shot counter or the server replies ERROR_CLIENT_UNSYNCED_SERVER.
--   This means silent-aim works from anywhere in range — no teleport needed to land damage.
--
-- "Stomp" is POSITIONAL. The client raycasts DOWN from LowerTorso to find a body, then fires
--   MainEvent:FireServer("Stomp") with NO target argument; the server resolves the K.O'd victim beneath
--   your REPLICATED position. So the finisher needs you standing over the body — we micro-blink onto the
--   target only for the stomp, then return. Stomp carries no position payload, so this blink doesn't trip
--   the Shoot remote's origin-vs-position desync check.
--
-- Kill model: silent-aim shots drop the target to K.O, the stomp finishes.
-- Real health lives in BodyEffects.Health_CLIENT (Humanoid.Health stays 100 as a decoy).

local repo = 'https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/'
local Library      = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager  = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()

local Players          = game:GetService('Players')
local RunService       = game:GetService('RunService')
local ReplicatedStorage= game:GetService('ReplicatedStorage')

local LocalPlayer = Players.LocalPlayer
local MainEvent   = ReplicatedStorage:WaitForChild('MainEvent')

local GUN_RANGE = 200          -- server-side gun range cap from MainModule.GUN_RANGE
local GUN_RELOAD_TIME = 1.5    -- MainModule.GUN_RELOAD_TIME (full reload; non shell-reload guns)

-- kill any previous instance before building a new one (safe re-execute)
if getgenv().HoodCustoms_Unload then
    pcall(getgenv().HoodCustoms_Unload)
end

local Connections = {}    -- every connection we make lives here so teardown can drop them all
local Unloaded    = false -- the loop checks this and bails the instant we tear down

-- ============================================================= gun state (shared shot counter)

-- The gun framework keeps ONE shared state table that owns the shot counter (INDEX) and the PENDING
-- map of outstanding shots. The server stays synced to that counter. If we invent our own index the
-- server rejects the shot as UNSYNCED, so we grab the real table out of the GC, advance its INDEX the
-- same way the game's own script does, and seed PENDING[idx] so settleShot doesn't crash on the reply.
local GunState = nil
local function getGunState()
    if GunState and type(GunState) == 'table' and rawget(GunState, 'INDEX') ~= nil then
        return GunState
    end
    GunState = nil
    local ok, gc = pcall(getgc, true)
    if not ok then return nil end
    for _, v in ipairs(gc) do
        if type(v) == 'table'
            and rawget(v, 'PENDING') ~= nil
            and rawget(v, 'INDEX')   ~= nil
            and rawget(v, 'KNIVES')  ~= nil then
            GunState = v
            break
        end
    end
    return GunState
end

-- advance the real counter so the game's own gun script stays in sync, seed PENDING, return the index
local function nextShotIndex()
    local st = getGunState()
    if not st then return nil end
    st.INDEX += 1
    -- PENDING entry MUST carry a KNOCKED table; settleShot does `for v in next, entry.KNOCKED`
    -- and errors with "invalid argument #1 to 'next'" if it's nil.
    if type(rawget(st, 'PENDING')) == 'table' then
        st.PENDING[st.INDEX] = { TARGET = nil, KNOCKED = {} }
    end
    return st.INDEX
end

-- the server rate-limits the Shoot remote to the equipped gun's own fire interval
-- (DATA.cooldown). shots sent faster than this get dropped, so we read it live and
-- never fire below it. a small margin covers client/server clock skew.
local function gunCooldown()
    local st = getGunState()
    local data = st and rawget(st, 'DATA')
    if type(data) == 'table' then
        local cd = tonumber(rawget(data, 'cooldown'))
        if cd and cd > 0 then return cd end
    end
    return nil
end

-- ============================================================= target / state helpers

local function bodyEffects(char)
    return char and char:FindFirstChild('BodyEffects')
end

local function healthOf(char)
    local be = bodyEffects(char)
    local hc = be and be:FindFirstChild('Health_CLIENT')
    return hc and hc.Value or nil
end

local function isKO(char)
    local be = bodyEffects(char)
    local ko = be and be:FindFirstChild('K.O')
    return ko ~= nil and ko.Value == true
end

-- BodyEffects.Dead flips false->true the moment a stomp finishes the kill; a dead body is
-- spent, so we stop blinking onto it and let the next target take over.
local function isDead(char)
    local be = bodyEffects(char)
    local dead = be and be:FindFirstChild('Dead')
    return dead ~= nil and dead.Value == true
end

-- a character we can act on: present in the world with a root part
local function validTarget(char)
    return char ~= nil
        and char.Parent ~= nil
        and char:FindFirstChild('HumanoidRootPart') ~= nil
        and not isDead(char)
end

-- part we aim the silent-aim shot at
local function aimPart(char)
    return char:FindFirstChild('UpperTorso') or char:FindFirstChild('HumanoidRootPart')
end

-- part the finisher blink should land on top of
local function stompPart(char)
    return char:FindFirstChild('LowerTorso') or char:FindFirstChild('UpperTorso') or char:FindFirstChild('HumanoidRootPart')
end

-- my own gate for firing Stomp (mirrors the game's client stomp() checks)
local function canStomp()
    local char = LocalPlayer.Character
    local be = bodyEffects(char)
    if not be then return false end
    local ok = true
    pcall(function()
        ok = be['K.O'].Value == false
            and be.Reloading_CLIENT.Value == false
            and be.Attacking_CLIENT.Value == false
            and be.Grabbed.Value == nil
            and char:FindFirstChild('GRABBING_CONSTRAINT') == nil
    end)
    return ok
end

-- ============================================================= gun detection

-- real guns hold a Script with an Ammo value (tool.Script.Ammo.CLIENT.Value). GunData does NOT exist.
local function isGun(t)
    if not (t and t:IsA('Tool')) then return false end
    local s = t:FindFirstChild('Script')
    return s ~= nil and s:FindFirstChild('Ammo') ~= nil
end

-- magazine size straight off the tool (used to rank guns before we've tracked ammo)
local function magSize(t)
    local s = t and t:FindFirstChild('Script')
    local m = s and s:FindFirstChild('MaxAmmo')
    return (m and m.Value) or 0
end

local function findGun()
    local char = LocalPlayer.Character
    if char then
        local t = char:FindFirstChildOfClass('Tool')
        if isGun(t) then return t, true end
    end
    local bp = LocalPlayer:FindFirstChild('Backpack')
    if bp then
        -- prefer the biggest magazine: Revolver (6) over DoubleBarrel (2) means fewer
        -- reload gaps mid-kill, so the target bleeds out faster.
        local best, bestMax = nil, -1
        for _, t in ipairs(bp:GetChildren()) do
            if isGun(t) then
                local m = magSize(t)
                if m > bestMax then best, bestMax = t, m end
            end
        end
        if best then return best, false end
    end
    return nil, false
end

-- Ammo.CLIENT is display-only and desyncs under our manual fire/reload path, so we read it
-- ONLY to seed the counter the first time we pick up a gun. After that we track rounds ourselves.
local function gunAmmo(tool)
    local s = tool and tool:FindFirstChild('Script')
    local ammo = s and s:FindFirstChild('Ammo')
    local client = ammo and ammo:FindFirstChild('CLIENT')
    return client and client.Value or 0
end

local function gunMaxAmmo(tool)
    local s = tool and tool:FindFirstChild('Script')
    local m = s and s:FindFirstChild('MaxAmmo')
    return (m and m.Value) or 2
end

-- world position of the gun muzzle; Handle carries a "Muzzle" CFrame attribute
local function muzzleOrigin(tool)
    local handle = tool and tool:FindFirstChild('Handle')
    if not handle then return nil end
    local mz = handle:GetAttribute('Muzzle')
    if typeof(mz) == 'CFrame' then
        return (handle.CFrame * mz.Position)
    end
    return handle.Position
end

-- ============================================================= combat actions

local function equipGun(tool)
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass('Humanoid')
    if hum then pcall(function() hum:EquipTool(tool) end) end
end

-- walk up to a Model with a Humanoid, exactly like the gun script's getHitModel. This is how the
-- game turns a raycast-hit part into the character that owns it.
local function hitModelFromInstance(inst)
    for _ = 1, 5 do
        if inst == nil or inst == workspace then return nil end
        if inst:IsA('Model') and inst:FindFirstChildOfClass('Humanoid') then
            return inst
        end
        inst = inst.Parent
    end
    return nil
end

-- silent-aim shot that the server can't flag as a wallbang.
--
-- The gun's own client builds HITS by raycasting FROM THE MUZZLE along each pellet direction with
-- the exclude list { workspace.Ignored, OwnCharacter, Camera } and recording whatever the ray
-- actually strikes. The server re-runs that same cast to validate ORIGIN->POSITION/PART. Our old
-- path fabricated a dead-center torso hit regardless of geometry, so any wall between us and the
-- target made the server's re-validation land on the wall -> "wallbang" rejection.
--
-- Here we reproduce the game's cast verbatim: aim at the torso, cast muzzle->target with the exact
-- same filter, and submit the REAL hit. On open ground the ray lands on the target and the shot is
-- indistinguishable from a legit one. Behind cover the ray stops on the wall (model ~= target), so
-- we fire nothing instead of forging a flagged shot.
local function fireShot(tool, targetChar)
    local origin = muzzleOrigin(tool)
    local part   = aimPart(targetChar)
    if not origin or not part then return false end

    local aim = part.Position
    local delta = aim - origin
    local mag = delta.Magnitude
    if mag < 1e-3 then return false end
    local dir = delta / mag

    local filter = { LocalPlayer.Character, workspace.CurrentCamera }
    local ignored = workspace:FindFirstChild('Ignored')
    if ignored then table.insert(filter, ignored) end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = filter
    params.IgnoreWater = true

    local result = workspace:Raycast(origin, dir * GUN_RANGE, params)
    local model  = result and hitModelFromInstance(result.Instance)
    if not model or model ~= targetChar then
        return false   -- geometry in the way (or we'd clip someone else): skip, don't forge a hit
    end

    local idx = nextShotIndex()
    if not idx then return false end   -- no synced gun state yet; skip rather than desync the server

    MainEvent:FireServer('Shoot', {
        ORIGIN = origin,
        AIM    = aim,
        INDEX  = idx,
        HITS   = { { PELLET = 1, MODEL = model, PART = result.Instance, POSITION = result.Position } },
    })
    return true
end

local function doStomp()
    MainEvent:FireServer('Stomp')
end

-- ---- ammo / reload tracking -----------------------------------------------------------
-- The server refills exactly MaxAmmo rounds per Reload and rejects any shot past that, while
-- the client's Ammo.CLIENT display stays frozen under our manual path. So we mirror the server's
-- real ammo with our own counter: seed it from the display when a gun is first picked up, then
-- decrement on every fired shot and refill on reload. Proven: 2 shots land, then the gun is dry.
local TrackedGun  = nil
local ShotsLeft   = 0
local ReloadUntil = 0   -- os.clock() the in-progress reload completes at (0 = not reloading)

-- re-seed when we switch to a different gun instance (equip / respawn / weapon swap)
local function syncAmmo(tool)
    if tool ~= TrackedGun then
        TrackedGun  = tool
        ShotsLeft   = gunAmmo(tool)   -- display is accurate at first sight, before we desync it
        ReloadUntil = 0
    end
end

local function reloadInProgress()
    return ReloadUntil > 0
end

-- fire the real reload remote: pass the TOOL (the framework does `FireServer("Reload", TOOL)`)
-- and flip Reloading_CLIENT so the gun's own gating treats us as mid-reload.
local function startReload(tool)
    MainEvent:FireServer('Reload', tool)
    local be = bodyEffects(LocalPlayer.Character)
    local rc = be and be:FindFirstChild('Reloading_CLIENT')
    if rc then rc.Value = true end
    ReloadUntil = os.clock() + GUN_RELOAD_TIME + 0.1
end

-- call every tick; once the reload window elapses the server has refilled, so top the counter up
local function finishReloadIfDue(tool)
    if ReloadUntil > 0 and os.clock() >= ReloadUntil then
        ReloadUntil = 0
        ShotsLeft   = gunMaxAmmo(tool)
        local be = bodyEffects(LocalPlayer.Character)
        local rc = be and be:FindFirstChild('Reloading_CLIENT')
        if rc then rc.Value = false end
    end
end

-- ============================================================= finisher blink

-- Only teleport for the stomp. Blink on top of the body, let our position replicate, fire Stomp
-- (which the server resolves by our position), wait out the stomp, then snap back.
local SavedCFrame = nil

local function restorePosition()
    local myChar = LocalPlayer.Character
    local myHRP  = myChar and myChar:FindFirstChild('HumanoidRootPart')
    if myHRP and SavedCFrame then
        myHRP.CFrame = SavedCFrame
        myHRP.AssemblyLinearVelocity = Vector3.zero
    end
    SavedCFrame = nil
end

local function finisher(targetChar)
    local myChar = LocalPlayer.Character
    local myHRP  = myChar and myChar:FindFirstChild('HumanoidRootPart')
    local body   = stompPart(targetChar)
    if not myHRP or not body then return end
    if not canStomp() then return end

    SavedCFrame = myHRP.CFrame
    -- sit just above the body so our LowerTorso raycast finds it
    myHRP.CFrame = CFrame.new(body.Position + Vector3.new(0, 2, 0))
    myHRP.AssemblyLinearVelocity = Vector3.zero

    task.wait(0.2)   -- let the server see our new position
    if isKO(targetChar) and canStomp() then
        doStomp()
    end
    task.wait(0.65)  -- stomp anim (~0.55) + settle
    restorePosition()
end

-- ============================================================= UI

local Window = Library:CreateWindow({
    Title = 'Hood Customs — Autokill',
    Center = true,
    AutoShow = true,
    TabPadding = 8,
    MenuFadeTime = 0.2,
})

local Tabs = {
    Main = Window:AddTab('Main'),
    Settings = Window:AddTab('UI Settings'),
}

local Box = Tabs.Main:AddLeftGroupbox('Autokill')

Box:AddToggle('Enabled', { Text = 'Autokill enabled', Default = false, Tooltip = 'Master switch for the kill loop' })

Box:AddDropdown('TargetPlayer', {
    SpecialType = 'Player',
    Text = 'Target player',
    Tooltip = 'Who to kill (ignored when Nearest is on, or used as priority)',
    ExcludeLocalPlayer = true,
})

Box:AddToggle('Nearest', { Text = 'Fallback to nearest', Default = true, Tooltip = 'When no dropdown target is picked (or it died), auto-target the closest living player' })
Box:AddToggle('UseGun',  { Text = 'Shoot to down',  Default = true, Tooltip = 'Silent-aim the gun at the target until they K.O' })
Box:AddToggle('UseStomp',{ Text = 'Stomp to finish',Default = true, Tooltip = 'Blink onto the body and stomp once the target is downed' })
Box:AddToggle('AutoEquip',{ Text = 'Auto-equip gun', Default = true, Tooltip = 'Pull a gun from the backpack if none is held' })
Box:AddToggle('AutoReload',{ Text = 'Auto-reload',  Default = true, Tooltip = 'Reload when the clip is empty' })

Box:AddSlider('MaxDistance', { Text = 'Max distance', Default = 200, Min = 10, Max = 500, Rounding = 0, Suffix = ' studs' })
Box:AddSlider('FireDelay',   { Text = 'Shot delay (floor)', Default = 0.35, Min = 0.15, Max = 0.8, Rounding = 2, Suffix = 's', Tooltip = "Minimum spacing between shots. The gun's own server cooldown overrides this upward, so shots are never dropped." })

local FarmBox = Tabs.Main:AddRightGroupbox('Stomp farm')
FarmBox:AddToggle('StompFarm', { Text = 'Stomp anyone under me', Default = false, Tooltip = 'Pure finisher spam — stomps any downed body beneath you (no blink)' })

Box:AddLabel('Toggle autokill'):AddKeyPicker('AutokillKey', { Default = 'K', Mode = 'Toggle', Text = 'Autokill', SyncToggleState = true })

Box:AddDivider()
Box:AddButton('Unload', function() Library:Unload() end)  -- routes through Library:OnUnload below

-- ============================================================= logic

local busy      = false
local lastShot  = 0
local lastStomp = 0

-- resolve the player we're attacking: dropdown pick wins, nearest living is the fallback
local function resolveTarget()
    local myChar = LocalPlayer.Character
    local myHRP = myChar and myChar:FindFirstChild('HumanoidRootPart')
    if not myHRP then return nil end

    local maxD = Options.MaxDistance.Value

    local name = Options.TargetPlayer.Value
    if name and name ~= '' then
        local plr = Players:FindFirstChild(name)
        if plr and validTarget(plr.Character) then return plr end
        -- selected player is dead/gone; fall through to Nearest only if it's enabled
    end

    if Toggles.Nearest.Value then
        local best, bestD = nil, math.huge
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and validTarget(plr.Character) then
                local hrp = plr.Character:FindFirstChild('HumanoidRootPart')
                local d = (hrp.Position - myHRP.Position).Magnitude
                if d < bestD and d <= maxD then best, bestD = plr, d end
            end
        end
        return best
    end

    return nil
end

local function step()
    if Unloaded or busy then return end

    -- pure stomp farm: stomp whatever downed body is already beneath us (no blink)
    if Toggles.StompFarm.Value and canStomp() and (os.clock() - lastStomp) > 0.6 then
        doStomp()
        lastStomp = os.clock()
    end

    if not Toggles.Enabled.Value then return end

    local target = resolveTarget()
    if not target or not validTarget(target.Character) then return end

    busy = true
    pcall(function()
        local tChar = target.Character
        local myChar = LocalPlayer.Character
        local myHRP = myChar and myChar:FindFirstChild('HumanoidRootPart')
        if not myHRP then return end

        -- finisher phase (skip bodies already stomped to death)
        if isKO(tChar) then
            if Toggles.UseStomp.Value and not isDead(tChar) then finisher(tChar) end
            return
        end

        -- damage phase
        if not Toggles.UseGun.Value then return end

        local gun, inChar = findGun()
        if not gun then return end
        if not inChar then
            if not Toggles.AutoEquip.Value then return end
            equipGun(gun)
            task.wait(0.1)
            gun, inChar = findGun()
        end
        if not (gun and inChar) then return end

        syncAmmo(gun)

        -- reload is non-blocking: when a reload is running, just let it finish on its own clock
        if reloadInProgress() then
            finishReloadIfDue(gun)
            return
        end

        -- dry gun -> kick off a reload (server gives us exactly MaxAmmo rounds back)
        if ShotsLeft <= 0 then
            if Toggles.AutoReload.Value then startReload(gun) end
            return
        end

        local part = aimPart(tChar)
        if not part then return end
        local d = (part.Position - myHRP.Position).Magnitude
        if d > math.min(Options.MaxDistance.Value, GUN_RANGE) then return end

        -- respect whichever is slower: the user's slider or the gun's real server cooldown
        local cd = gunCooldown()
        local delay = Options.FireDelay.Value
        if cd then delay = math.max(delay, cd + 0.05) end
        if (os.clock() - lastShot) >= delay then
            if fireShot(gun, tChar) then
                lastShot  = os.clock()
                ShotsLeft = ShotsLeft - 1
            end
        end
    end)
    busy = false
end

Connections.Heartbeat = RunService.Heartbeat:Connect(function()
    pcall(step)
end)

-- ============================================================= teardown

-- Full unload: stop the loop, drop every connection, restore position, free the global.
-- The Unload button and the menu's X both call Library:Unload(), which fires this.
local function teardown()
    if Unloaded then return end
    Unloaded = true

    for key, conn in pairs(Connections) do
        if typeof(conn) == 'RBXScriptConnection' then
            pcall(function() conn:Disconnect() end)
        end
        Connections[key] = nil
    end

    -- put us back if a finisher blink left us parked on someone
    pcall(restorePosition)

    getgenv().HoodCustoms_Unload = nil
end

getgenv().HoodCustoms_Unload = function()
    teardown()
    pcall(function() Library:Unload() end)
end

Library:OnUnload(teardown)

-- ============================================================= addons / config

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)

SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ 'AutokillKey' })

ThemeManager:SetFolder('HoodCustomsAutokill')
SaveManager:SetFolder('HoodCustomsAutokill/configs')

SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)

SaveManager:LoadAutoloadConfig()

Library:Notify('Hood Customs Autokill loaded — press RightShift for menu, K to toggle.')
