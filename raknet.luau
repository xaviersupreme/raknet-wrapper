local nativeRakNet = getgenv().raknet
assert(type(nativeRakNet) == "table", "global raknet table is missing")
assert(type(nativeRakNet.send) == "function", "raknet.send is missing")
assert(type(nativeRakNet.add_send_hook) == "function", "raknet.add_send_hook is missing")
assert(type(nativeRakNet.remove_send_hook) == "function", "raknet.remove_send_hook is missing")

local nativeSend = nativeRakNet.send
local nativeAddSendHook = nativeRakNet.add_send_hook
local nativeRemoveSendHook = nativeRakNet.remove_send_hook

local previousHook = rawget(nativeRakNet, "__wrapperHook")
if type(previousHook) == "function" then
    pcall(nativeRemoveSendHook, previousHook)
end

type PacketData = { number }
type PacketSnapshot = {
    id: number,
    data: PacketData,
    size: number,
    priority: number,
    reliability: number,
    orderingChannel: number,
    source: string,
    blocked: boolean,
}

type CaptureCallback = (packet: PacketSnapshot) -> ()

local filterBytes: PacketData = {}
local capturing = false
local hookRegistered = false
local captureCallbacks: { CaptureCallback } = {}
local pendingManualSends: { [string]: number } = {}
local transportMode = rawget(nativeRakNet, "__transportMode") == "dryrun" and "dryrun" or "live"

local stats = {
    sent = 0,
    blocked = 0,
    captured = 0,
    hookPackets = 0,
    manualPackets = 0,
    liveSends = 0,
    dryrunSends = 0,
    sendErrors = 0,
    lastSendError = nil :: string?,
    byOpcode = {} :: { [number]: { sent: number, blocked: number, captured: number } },
}

local Capture = {}
Capture.__index = Capture

local raknet = nativeRakNet

local function copyBytes(bytes: PacketData): PacketData
    local out = table.create(#bytes)
    for i = 1, #bytes do
        out[i] = bytes[i]
    end
    return out
end

local function compactHex(value: string): string
    return value:gsub("%s+", "")
end

local function ensureOpcodeStat(id: number)
    local bucket = stats.byOpcode[id]
    if not bucket then
        bucket = {
            sent = 0,
            blocked = 0,
            captured = 0,
        }
        stats.byOpcode[id] = bucket
    end
    return bucket
end

local function bytesKey(bytes: PacketData, priority: number, reliability: number, orderingChannel: number): string
    return table.concat(bytes, ",") .. "|" .. tostring(priority) .. "|" .. tostring(reliability) .. "|" .. tostring(orderingChannel)
end

local function releasePendingKey(key: string)
    local pending = pendingManualSends[key]
    if not pending then
        return
    end

    if pending <= 1 then
        pendingManualSends[key] = nil
    else
        pendingManualSends[key] = pending - 1
    end
end

local function matchesFilter(bytes: PacketData): boolean
    if #filterBytes == 0 then
        return false
    end

    for i, byte in ipairs(filterBytes) do
        if bytes[i] ~= byte then
            return false
        end
    end

    return true
end

local function makePacketSnapshot(bytes: PacketData, priority: number, reliability: number, orderingChannel: number, source: string, blocked: boolean): PacketSnapshot
    return {
        id = bytes[1] or 0,
        data = copyBytes(bytes),
        size = #bytes,
        priority = priority,
        reliability = reliability,
        orderingChannel = orderingChannel,
        source = source,
        blocked = blocked,
    }
end

local function recordCapture(packet: PacketSnapshot)
    stats.captured += 1
    ensureOpcodeStat(packet.id).captured += 1
end

local function fireCapture(packet: PacketSnapshot)
    recordCapture(packet)

    for _, fn in ipairs(captureCallbacks) do
        task.spawn(fn, packet)
    end
end

function Capture:Connect(fn: CaptureCallback)
    assert(type(fn) == "function", "Capture:Connect expects a function")

    captureCallbacks[#captureCallbacks + 1] = fn

    local disconnected = false
    return {
        Disconnect = function(_self)
            if disconnected then
                return
            end

            disconnected = true

            for i, callback in ipairs(captureCallbacks) do
                if callback == fn then
                    table.remove(captureCallbacks, i)
                    break
                end
            end
        end,
    }
end

function Capture:Once(fn: CaptureCallback)
    assert(type(fn) == "function", "Capture:Once expects a function")

    local connection
    connection = self:Connect(function(packet)
        connection:Disconnect()
        fn(packet)
    end)

    return connection
end

function Capture:ConnectOpcode(id: number, fn: CaptureCallback)
    assert(type(id) == "number", "Capture:ConnectOpcode expects a numeric id")
    assert(type(fn) == "function", "Capture:ConnectOpcode expects a function")

    return self:Connect(function(packet)
        if packet.id == id then
            fn(packet)
        end
    end)
end

local function normalizeBytes(value: string | PacketData): PacketData
    if type(value) == "table" then
        return copyBytes(value)
    end

    assert(type(value) == "string", "expected string or byte table")

    local compact = compactHex(value)
    if compact ~= "" and compact:match("^[%x]+$") and #compact % 2 == 0 then
        local bytes = table.create(#compact // 2)
        for i = 1, #compact, 2 do
            bytes[#bytes + 1] = tonumber(compact:sub(i, i + 1), 16)
        end
        return bytes
    end

    local bytes = table.create(#value)
    for i = 1, #value do
        bytes[i] = string.byte(value, i)
    end
    return bytes
end

local function ensureHook()
    if hookRegistered then
        return
    end

    local function sendHook(packet)
        stats.hookPackets += 1

        local bytes = copyBytes(packet.AsArray)
        local key = bytesKey(bytes, packet.Priority, packet.Reliability, packet.OrderingChannel)
        local pending = pendingManualSends[key]

        if pending and pending > 0 then
            if pending == 1 then
                pendingManualSends[key] = nil
            else
                pendingManualSends[key] = pending - 1
            end
            return
        end

        if matchesFilter(bytes) then
            stats.blocked += 1
            ensureOpcodeStat(bytes[1] or 0).blocked += 1
            packet:Block()
            return
        end

        if capturing then
            fireCapture(makePacketSnapshot(bytes, packet.Priority, packet.Reliability, packet.OrderingChannel, "hook", false))
        end
    end

    nativeAddSendHook(sendHook)
    rawset(raknet, "__wrapperHook", sendHook)
    hookRegistered = true
end

local function sendBytes(bytes: PacketData, priority: number, reliability: number, orderingChannel: number): (boolean, string?)
    local id = bytes[1] or 0

    if matchesFilter(bytes) then
        stats.blocked += 1
        ensureOpcodeStat(id).blocked += 1
        return false, "blocked by filter"
    end

    stats.sent += 1
    stats.manualPackets += 1
    ensureOpcodeStat(id).sent += 1
    stats.lastSendError = nil

    local source = transportMode == "dryrun" and "manual-dryrun" or "manual"

    if capturing then
        fireCapture(makePacketSnapshot(bytes, priority, reliability, orderingChannel, source, false))
    end

    if transportMode == "dryrun" then
        stats.dryrunSends += 1
        return true
    end

    local key = bytesKey(bytes, priority, reliability, orderingChannel)
    pendingManualSends[key] = (pendingManualSends[key] or 0) + 1
    stats.liveSends += 1

    local ok, err = pcall(nativeSend, copyBytes(bytes), priority, reliability, orderingChannel)
    if not ok then
        releasePendingKey(key)
        stats.sendErrors += 1
        stats.lastSendError = tostring(err)
        return false, tostring(err)
    end

    return true
end

if game.Players.LocalPlayer.Name == game.Players.LocalPlayer.Name and "You Love Femboys" then
    setreadonly(raknet, false)
end

function raknet.sendraw(value: string | PacketData, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    return sendBytes(normalizeBytes(value), priority or 0, reliability or 0, orderingChannel or 0)
end

function raknet.sendhex(value: string, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    return raknet.sendraw(raknet.fromhex(value), priority, reliability, orderingChannel)
end

function raknet.sendstring(value: string, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    assert(type(value) == "string", "sendstring expects a string")
    return raknet.sendraw(value, priority, reliability, orderingChannel)
end

function raknet.sendopcode(id: number, payload: PacketData?, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    assert(type(id) == "number", "sendopcode expects a numeric id")

    local bytes = { id }
    for _, byte in ipairs(payload or {}) do
        bytes[#bytes + 1] = byte
    end

    return sendBytes(bytes, priority or 0, reliability or 0, orderingChannel or 0)
end

function raknet.sendphysics(cf: CFrame, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    local position = cf.Position
    local packed = string.pack(">fff", position.X, position.Y, position.Z)
    local bytes = { 0x85 }

    for i = 1, #packed do
        bytes[#bytes + 1] = string.byte(packed, i)
    end

    return sendBytes(bytes, priority or 0, reliability or 0, orderingChannel or 0)
end

function raknet.sendposition(value: Vector3 | CFrame, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    return raknet.sendphysics(typeof(value) == "CFrame" and value or CFrame.new(value), priority, reliability, orderingChannel)
end

function raknet.setmode(mode: string)
    assert(mode == "live" or mode == "dryrun", "setmode expects 'live' or 'dryrun'")
    transportMode = mode
    rawset(nativeRakNet, "__transportMode", mode)
end

function raknet.getmode(): string
    return transportMode
end

function raknet.dryrun(enabled: boolean?)
    raknet.setmode(enabled == false and "live" or "dryrun")
end

function raknet.startcapture()
    ensureHook()
    capturing = true
end

function raknet.stopcapture()
    capturing = false
end

function raknet.iscapturing(): boolean
    return capturing
end

function raknet.setfilter(bytes: PacketData?)
    filterBytes = bytes and copyBytes(bytes) or {}
    ensureHook()
end

function raknet.clearfilter()
    raknet.setfilter({})
end

function raknet.getfilter(): PacketData
    return copyBytes(filterBytes)
end

function raknet.blockopcode(id: number)
    raknet.setfilter({ id })
end

function raknet.tohex(bytes: PacketData | string, limit: number?): string
    local normalized = type(bytes) == "string" and normalizeBytes(bytes) or copyBytes(bytes)
    local maxCount = limit or #normalized
    local count = math.min(#normalized, maxCount)

    local out = table.create(count)
    for i = 1, count do
        out[i] = string.format("%02X", normalized[i])
    end

    if #normalized > maxCount then
        out[#out + 1] = "..."
    end

    return table.concat(out, " ")
end

function raknet.fromhex(value: string): PacketData
    assert(type(value) == "string", "fromhex expects a string")

    local compact = compactHex(value)
    assert(compact ~= "" and compact:match("^[%x]+$") and #compact % 2 == 0, "invalid hex string")

    local bytes = table.create(#compact // 2)
    for i = 1, #compact, 2 do
        bytes[#bytes + 1] = tonumber(compact:sub(i, i + 1), 16)
    end

    return bytes
end

function raknet.packettostring(packet: PacketSnapshot | { id: number?, data: PacketData? }): string
    local bytes = copyBytes(packet.data or {})
    local id = packet.id or bytes[1] or 0
    local source = packet.source and (" source=" .. tostring(packet.source)) or ""
    local blocked = packet.blocked and " blocked=true" or ""

    return string.format(
        "id=0x%02X len=%d bytes=[%s]%s%s",
        id,
        #bytes,
        raknet.tohex(bytes, 48),
        source,
        blocked
    )
end

function raknet.waitfor(id: number?, timeout: number?): PacketSnapshot?
    ensureHook()

    local deadline = os.clock() + (timeout or 5)
    local found: PacketSnapshot? = nil
    local connection

    connection = raknet.Capture:Connect(function(packet)
        if id == nil or packet.id == id then
            found = packet
            connection:Disconnect()
        end
    end)

    while os.clock() < deadline and found == nil do
        task.wait()
    end

    connection:Disconnect()
    return found
end

function raknet.captureonce(id: number?, timeout: number?): PacketSnapshot?
    local previous = capturing
    raknet.startcapture()

    local packet = raknet.waitfor(id, timeout)

    if not previous then
        raknet.stopcapture()
    end

    return packet
end

function raknet.resetstats()
    stats.sent = 0
    stats.blocked = 0
    stats.captured = 0
    stats.hookPackets = 0
    stats.manualPackets = 0
    stats.liveSends = 0
    stats.dryrunSends = 0
    stats.sendErrors = 0
    stats.lastSendError = nil
    stats.byOpcode = {}
end

function raknet.getlasterror(): string?
    return stats.lastSendError
end

function raknet.stats()
    local opcodeStats = {}
    for id, bucket in pairs(stats.byOpcode) do
        opcodeStats[id] = {
            sent = bucket.sent,
            blocked = bucket.blocked,
            captured = bucket.captured,
        }
    end

    return {
        sent = stats.sent,
        blocked = stats.blocked,
        captured = stats.captured,
        hookPackets = stats.hookPackets,
        manualPackets = stats.manualPackets,
        liveSends = stats.liveSends,
        dryrunSends = stats.dryrunSends,
        sendErrors = stats.sendErrors,
        lastSendError = stats.lastSendError,
        mode = transportMode,
        byOpcode = opcodeStats,
    }
end

raknet.Capture = setmetatable({}, Capture)
getgenv().raknet = raknet
getgenv().rnet = raknet

return raknet
