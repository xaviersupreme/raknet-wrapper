local nativeRakNet = getgenv().raknet
assert(type(nativeRakNet) == "table", "global raknet table is missing")
assert(type(nativeRakNet.send) == "function", "raknet.send is missing")
assert(type(nativeRakNet.add_send_hook) == "function", "raknet.add_send_hook is missing")
assert(type(nativeRakNet.remove_send_hook) == "function", "raknet.remove_send_hook is missing")

setreadonly(nativeRakNet, false)

local nativeSend = nativeRakNet.send
local nativeAddSendHook = nativeRakNet.add_send_hook
local nativeRemoveSendHook = nativeRakNet.remove_send_hook

local previousHook = rawget(nativeRakNet, "__wrapperHook")
if type(previousHook) == "function" then
    pcall(nativeRemoveSendHook, previousHook)
    rawset(nativeRakNet, "__wrapperHook", nil)
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
type PipeCallback = (packet: PacketSnapshot) -> any
type Matcher = number | string | PacketData | ((packet: PacketSnapshot) -> boolean) | { [string]: any }

local filterBytes: PacketData = {}
local capturing = false
local hookRegistered = false
local captureCallbacks: { [number]: CaptureCallback } = {}
local nextCallbackId = 0
local pipes: { [string]: PipeCallback } = {}
local pipeOrder: { string } = {}
local namedWatches = {}
local recordings: { [string]: { active: boolean, packets: { PacketSnapshot }, source: string? } } = {}
local pendingManualSends: { [string]: number } = {}
local recentPackets: { PacketSnapshot } = {}
local recentPacketLimit = 200

local stats = {
    sent = 0,
    blocked = 0,
    captured = 0,
    hookPackets = 0,
    manualPackets = 0,
    liveSends = 0,
    sendErrors = 0,
    lastSendError = nil :: string?,
    byOpcode = {} :: { [number]: { sent: number, blocked: number, captured: number } },
}

local Capture = {}
Capture.__index = Capture

local raknet = nativeRakNet
local normalizeBytes

local function copyBytes(bytes: PacketData): PacketData
    local out = table.create(#bytes)
    for i = 1, #bytes do
        out[i] = bytes[i]
    end
    return out
end

local function byte(value: number, label: string): number
    assert(type(value) == "number", label .. " must be a number")
    assert(value == value and value % 1 == 0, label .. " must be an integer")
    assert(value >= 0 and value <= 255, label .. " must be 0-255")
    return value
end

local function stringBytes(value: string): PacketData
    local bytes = table.create(#value)
    for i = 1, #value do
        bytes[i] = string.byte(value, i)
    end
    return bytes
end

local function clonePacketSnapshot(packet: PacketSnapshot | { id: number?, data: PacketData?, size: number?, priority: number?, reliability: number?, orderingChannel: number?, source: string?, blocked: boolean? }): PacketSnapshot
    local data = copyBytes(packet.data or {})
    return {
        id = packet.id or data[1] or 0,
        data = data,
        size = packet.size or #data,
        priority = packet.priority or 0,
        reliability = packet.reliability or 0,
        orderingChannel = packet.orderingChannel or 0,
        source = packet.source or "unknown",
        blocked = packet.blocked == true,
    }
end

local function compactHex(value: string): string
    return value:gsub("%s+", "")
end

local function isHexString(value: string): boolean
    local compact = compactHex(value)
    return compact ~= "" and compact:match("^[%x]+$") ~= nil and #compact % 2 == 0
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

    for i = 1, #filterBytes do
        if bytes[i] ~= filterBytes[i] then
            return false
        end
    end

    return true
end

local function matchesPrefix(bytes: PacketData, prefix: PacketData): boolean
    if #prefix == 0 then
        return true
    end

    if #bytes < #prefix then
        return false
    end

    for i = 1, #prefix do
        if bytes[i] ~= prefix[i] then
            return false
        end
    end

    return true
end

local function isPacketMatcherTable(value): boolean
    return type(value) == "table"
        and (
            value.id ~= nil
            or value.opcode ~= nil
            or value.prefix ~= nil
            or value.source ~= nil
            or value.blocked ~= nil
            or value.priority ~= nil
            or value.reliability ~= nil
            or value.orderingChannel ~= nil
        )
end

local function makeMatcher(matcher: Matcher?)
    if matcher == nil then
        return function(_packet)
            return true
        end
    end

    if type(matcher) == "function" then
        return matcher
    end

    if type(matcher) == "number" then
        local id = byte(matcher, "matcher")
        return function(packet)
            return packet.id == id
        end
    end

    if isPacketMatcherTable(matcher) then
        local id = matcher.id ~= nil and byte(matcher.id, "matcher.id") or nil
        local opcode = matcher.opcode ~= nil and byte(matcher.opcode, "matcher.opcode") or nil
        local prefix = matcher.prefix ~= nil and normalizeBytes(matcher.prefix) or nil

        return function(packet)
            if id ~= nil and packet.id ~= id then
                return false
            end

            if opcode ~= nil and packet.id ~= opcode then
                return false
            end

            if prefix ~= nil and not matchesPrefix(packet.data, prefix) then
                return false
            end

            if matcher.source ~= nil and packet.source ~= matcher.source then
                return false
            end

            if matcher.blocked ~= nil and packet.blocked ~= matcher.blocked then
                return false
            end

            if matcher.priority ~= nil and packet.priority ~= matcher.priority then
                return false
            end

            if matcher.reliability ~= nil and packet.reliability ~= matcher.reliability then
                return false
            end

            if matcher.orderingChannel ~= nil and packet.orderingChannel ~= matcher.orderingChannel then
                return false
            end

            return true
        end
    end

    local prefix = normalizeBytes(matcher)
    return function(packet)
        return matchesPrefix(packet.data, prefix)
    end
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

    local snapshot = clonePacketSnapshot(packet)
    recentPackets[#recentPackets + 1] = snapshot
    if #recentPackets > recentPacketLimit then
        table.remove(recentPackets, 1)
    end

    for _, recording in pairs(recordings) do
        if recording.active and (recording.source == nil or recording.source == packet.source) then
            recording.packets[#recording.packets + 1] = clonePacketSnapshot(snapshot)
        end
    end
end

local function fireCapture(packet: PacketSnapshot)
    recordCapture(packet)

    local ids = {}
    for id in pairs(captureCallbacks) do
        ids[#ids + 1] = id
    end

    for i = 1, #ids do
        local callback = captureCallbacks[ids[i]]
        if callback then
            task.spawn(callback, packet)
        end
    end
end

function Capture:Connect(fn: CaptureCallback)
    assert(type(fn) == "function", "Capture:Connect expects a function")

    nextCallbackId += 1
    local id = nextCallbackId
    captureCallbacks[id] = fn

    local disconnected = false
    return {
        Disconnect = function(_self)
            if disconnected then
                return
            end

            disconnected = true
            captureCallbacks[id] = nil
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
    id = byte(id, "id")
    assert(type(fn) == "function", "Capture:ConnectOpcode expects a function")

    return self:ConnectMatch(id, fn)
end

function Capture:ConnectMatch(predicate, fn: CaptureCallback)
    assert(type(fn) == "function", "Capture:ConnectMatch expects a callback function")

    local matcher = makeMatcher(predicate)
    return self:Connect(function(packet)
        if matcher(packet) then
            fn(packet)
        end
    end)
end

function Capture:ConnectPrefix(prefix: PacketData | string, fn: CaptureCallback)
    assert(type(prefix) == "table" or type(prefix) == "string", "Capture:ConnectPrefix expects a byte table or string prefix")
    assert(type(fn) == "function", "Capture:ConnectPrefix expects a callback function")

    return self:ConnectMatch(prefix, fn)
end

normalizeBytes = function(value: string | PacketData): PacketData
    if type(value) == "table" then
        return copyBytes(value)
    end

    assert(type(value) == "string", "expected string or byte table")

    local compact = compactHex(value)
    if isHexString(compact) then
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

local function normalizePipePacket(packet: PacketSnapshot): PacketSnapshot
    local data = normalizeBytes(packet.data or {})
    return makePacketSnapshot(
        data,
        packet.priority or 0,
        packet.reliability or 0,
        packet.orderingChannel or 0,
        packet.source or "manual",
        packet.blocked == true
    )
end

local function applyPipes(packet: PacketSnapshot): (PacketSnapshot?, string?)
    local current = clonePacketSnapshot(packet)

    for i = 1, #pipeOrder do
        local name = pipeOrder[i]
        local fn = pipes[name]

        if fn then
            local result = fn(clonePacketSnapshot(current))
            if result == false then
                return nil, name
            end

            if type(result) == "table" then
                current = normalizePipePacket(result)
            end
        end
    end

    return current, nil
end

local function samePacketShape(packet: PacketSnapshot, bytes: PacketData, priority: number, reliability: number, orderingChannel: number): boolean
    if packet.priority ~= priority or packet.reliability ~= reliability or packet.orderingChannel ~= orderingChannel then
        return false
    end

    return matchesPrefix(packet.data, bytes) and #packet.data == #bytes
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

        local snapshot = makePacketSnapshot(bytes, packet.Priority, packet.Reliability, packet.OrderingChannel, "hook", false)
        local transformed = applyPipes(snapshot)

        if not transformed then
            stats.blocked += 1
            ensureOpcodeStat(bytes[1] or 0).blocked += 1

            if capturing then
                fireCapture(makePacketSnapshot(bytes, packet.Priority, packet.Reliability, packet.OrderingChannel, "hook", true))
            end

            packet:Block()
            return
        end

        if not samePacketShape(transformed, bytes, packet.Priority, packet.Reliability, packet.OrderingChannel) then
            packet:Block()

            local newKey = bytesKey(transformed.data, transformed.priority, transformed.reliability, transformed.orderingChannel)
            pendingManualSends[newKey] = (pendingManualSends[newKey] or 0) + 1

            local ok, err = pcall(nativeSend, copyBytes(transformed.data), transformed.priority, transformed.reliability, transformed.orderingChannel)
            if not ok then
                releasePendingKey(newKey)
                stats.sendErrors += 1
                stats.lastSendError = tostring(err)
                return
            end

            stats.liveSends += 1

            if capturing then
                fireCapture(makePacketSnapshot(transformed.data, transformed.priority, transformed.reliability, transformed.orderingChannel, "hook", false))
            end

            return
        end

        if capturing then
            fireCapture(snapshot)
        end
    end

    nativeAddSendHook(sendHook)
    rawset(raknet, "__wrapperHook", sendHook)
    hookRegistered = true
end

local function sendBytes(bytes: PacketData, priority: number, reliability: number, orderingChannel: number, nativeValue: PacketData | string?): (boolean, string?)
    local packet = makePacketSnapshot(bytes, priority, reliability, orderingChannel, "manual", false)
    local transformed, blockedByPipe = applyPipes(packet)

    if not transformed then
        local id = bytes[1] or 0
        stats.blocked += 1
        ensureOpcodeStat(id).blocked += 1
        return false, "blocked by pipe: " .. tostring(blockedByPipe)
    end

    bytes = transformed.data
    priority = transformed.priority
    reliability = transformed.reliability
    orderingChannel = transformed.orderingChannel

    local id = bytes[1] or 0

    if matchesFilter(bytes) then
        stats.blocked += 1
        ensureOpcodeStat(id).blocked += 1
        return false, "blocked by filter"
    end

    if capturing then
        fireCapture(makePacketSnapshot(bytes, priority, reliability, orderingChannel, "manual", false))
    end

    stats.lastSendError = nil

    local key: string? = nil
    if hookRegistered then
        key = bytesKey(bytes, priority, reliability, orderingChannel)
        pendingManualSends[key] = (pendingManualSends[key] or 0) + 1
    end

    local payload = #pipeOrder == 0 and nativeValue or nil
    if payload == nil then
        payload = copyBytes(bytes)
    end

    local ok, err = pcall(nativeSend, payload, priority, reliability, orderingChannel)
    if not ok then
        if key then
            releasePendingKey(key)
        end
        stats.sendErrors += 1
        stats.lastSendError = tostring(err)
        return false, tostring(err)
    end

    stats.sent += 1
    stats.manualPackets += 1
    stats.liveSends += 1
    ensureOpcodeStat(id).sent += 1

    return true
end

function raknet.sendraw(value: string | PacketData, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    local bytes = normalizeBytes(value)
    local nativeValue = type(value) == "string" and not isHexString(value) and value or copyBytes(bytes)
    return sendBytes(bytes, priority or 0, reliability or 0, orderingChannel or 0, nativeValue)
end

function raknet.sendhex(value: string, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    return raknet.sendraw(raknet.fromhex(value), priority, reliability, orderingChannel)
end

function raknet.sendstring(value: string, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    assert(type(value) == "string", "sendstring expects a string")
    return sendBytes(stringBytes(value), priority or 0, reliability or 0, orderingChannel or 0, value)
end

function raknet.sendopcode(id: number, payload: (PacketData | string)?, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    id = byte(id, "id")

    local bytes = { id }
    local payloadBytes = payload and normalizeBytes(payload) or {}
    for i = 1, #payloadBytes do
        bytes[#bytes + 1] = payloadBytes[i]
    end

    return sendBytes(bytes, priority or 0, reliability or 0, orderingChannel or 0)
end

function raknet.sendmany(packets): { { ok: boolean, err: string? } }
    assert(type(packets) == "table", "sendmany expects a packet list")

    local results = table.create(#packets)
    for i = 1, #packets do
        local packet = packets[i]
        assert(type(packet) == "table", "sendmany packet #" .. tostring(i) .. " must be a table")

        local bytes = packet.bytes or packet.data
        assert(bytes ~= nil, "sendmany packet #" .. tostring(i) .. " needs bytes or data")

        local ok, err = raknet.sendraw(
            bytes,
            packet.priority or 0,
            packet.reliability or 0,
            packet.orderingChannel or 0
        )

        results[i] = { ok = ok, err = err }
    end

    return results
end

function raknet.clonepacket(packet): PacketSnapshot
    assert(type(packet) == "table", "clonepacket expects a packet table")
    return clonePacketSnapshot(packet)
end

function raknet.matchprefix(bytes: PacketData | string, prefix: PacketData | string): boolean
    local normalizedBytes = type(bytes) == "string" and normalizeBytes(bytes) or copyBytes(bytes)
    local normalizedPrefix = type(prefix) == "string" and normalizeBytes(prefix) or copyBytes(prefix)
    return matchesPrefix(normalizedBytes, normalizedPrefix)
end

function raknet.resend(packet, priority: number?, reliability: number?, orderingChannel: number?): (boolean, string?)
    assert(type(packet) == "table", "resend expects a packet table")
    return raknet.sendraw(
        copyBytes(packet.data or {}),
        priority ~= nil and priority or packet.priority or 0,
        reliability ~= nil and reliability or packet.reliability or 0,
        orderingChannel ~= nil and orderingChannel or packet.orderingChannel or 0
    )
end

function raknet.sendlike(packet, newBytes: PacketData | string): (boolean, string?)
    assert(type(packet) == "table", "sendlike expects a packet table")
    return raknet.sendraw(
        newBytes,
        packet.priority or 0,
        packet.reliability or 0,
        packet.orderingChannel or 0
    )
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

function raknet.setfilter(bytes: (PacketData | string)?)
    filterBytes = bytes and normalizeBytes(bytes) or {}
    ensureHook()
end

function raknet.clearfilter()
    raknet.setfilter(nil)
end

function raknet.getfilter(): PacketData
    return copyBytes(filterBytes)
end

function raknet.blockopcode(id: number)
    id = byte(id, "id")
    raknet.setfilter({ id })
end

function raknet.pipe(name: string, fn: PipeCallback)
    assert(type(name) == "string" and name ~= "", "pipe expects a name")
    assert(type(fn) == "function", "pipe expects a function")

    if not pipes[name] then
        pipeOrder[#pipeOrder + 1] = name
    end

    pipes[name] = fn
    ensureHook()

    local removed = false
    return {
        Remove = function(_self)
            if removed then
                return
            end

            removed = true
            raknet.unpipe(name)
        end,
    }
end

function raknet.unpipe(name: string)
    assert(type(name) == "string" and name ~= "", "unpipe expects a name")
    pipes[name] = nil

    for i = #pipeOrder, 1, -1 do
        if pipeOrder[i] == name then
            table.remove(pipeOrder, i)
            break
        end
    end
end

function raknet.clearpipes()
    pipes = {}
    pipeOrder = {}
end

function raknet.listpipes(): { string }
    local out = table.create(#pipeOrder)
    for i = 1, #pipeOrder do
        out[i] = pipeOrder[i]
    end
    return out
end

function raknet.rules(nameOrRules, maybeRules)
    local name = "rules"
    local ruleList = nameOrRules

    if type(nameOrRules) == "string" then
        name = nameOrRules
        ruleList = maybeRules
    end

    assert(type(ruleList) == "table", "rules expects a rule list")

    return raknet.pipe(name, function(packet)
        local current = packet

        for i = 1, #ruleList do
            local rule = ruleList[i]
            assert(type(rule) == "table", "rule #" .. tostring(i) .. " must be a table")

            if makeMatcher(rule)(current) then
                if rule.action == "block" then
                    return false
                end

                if rule.action == "log" then
                    print(raknet.packettostring(current))
                end

                if rule.patch then
                    current = raknet.patch(current, rule.patch)
                end

                if type(rule.action) == "function" then
                    local result = rule.action(current)
                    if result == false then
                        return false
                    end

                    if type(result) == "table" then
                        current = result
                    end
                end
            end
        end

        return current
    end)
end

function raknet.watch(name: string, matcher: Matcher?, fn: CaptureCallback)
    assert(type(name) == "string" and name ~= "", "watch expects a name")
    assert(type(fn) == "function", "watch expects a callback")

    if namedWatches[name] then
        namedWatches[name]:Disconnect()
    end

    raknet.startcapture()
    namedWatches[name] = raknet.Capture:ConnectMatch(matcher, fn)

    return {
        Remove = function(_self)
            raknet.unwatch(name)
        end,
        Disconnect = function(_self)
            raknet.unwatch(name)
        end,
    }
end

function raknet.unwatch(name: string)
    assert(type(name) == "string" and name ~= "", "unwatch expects a name")

    local connection = namedWatches[name]
    if connection then
        connection:Disconnect()
        namedWatches[name] = nil
    end
end

function raknet.clearwatchers()
    local names = {}
    for name in pairs(namedWatches) do
        names[#names + 1] = name
    end

    for i = 1, #names do
        raknet.unwatch(names[i])
    end
end

function raknet.clearrecent()
    recentPackets = {}
end

function raknet.recent(limit: number?, source: string?): { PacketSnapshot }
    local maxCount = math.max(0, limit or #recentPackets)
    local out = {}

    if maxCount == 0 then
        return out
    end

    for i = #recentPackets, 1, -1 do
        local packet = recentPackets[i]
        if source == nil or packet.source == source then
            out[#out + 1] = clonePacketSnapshot(packet)
            if #out >= maxCount then
                break
            end
        end
    end

    return out
end

function raknet.setrecentlimit(limit: number)
    assert(type(limit) == "number" and limit >= 0 and limit % 1 == 0, "setrecentlimit expects a whole number")
    recentPacketLimit = limit

    while #recentPackets > recentPacketLimit do
        table.remove(recentPackets, 1)
    end
end

function raknet.getrecentlimit(): number
    return recentPacketLimit
end

function raknet.findrecent(matcher: Matcher?, source: string?): PacketSnapshot?
    local predicate = makeMatcher(matcher)

    for i = #recentPackets, 1, -1 do
        local packet = recentPackets[i]
        if (source == nil or packet.source == source) and predicate(packet) then
            return clonePacketSnapshot(packet)
        end
    end

    return nil
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

function raknet.hexdiff(left: PacketData | string, right: PacketData | string): string
    local a = type(left) == "string" and normalizeBytes(left) or copyBytes(left)
    local b = type(right) == "string" and normalizeBytes(right) or copyBytes(right)
    local maxLen = math.max(#a, #b)
    local lines = {}

    for i = 1, maxLen do
        local av = a[i]
        local bv = b[i]
        if av == bv then
            lines[#lines + 1] = string.format("%02d: %s", i, av ~= nil and string.format("%02X", av) or "--")
        else
            lines[#lines + 1] = string.format(
                "%02d: %s -> %s",
                i,
                av ~= nil and string.format("%02X", av) or "--",
                bv ~= nil and string.format("%02X", bv) or "--"
            )
        end
    end

    return table.concat(lines, "\n")
end

function raknet.inspect(value, limit: number?)
    local bytes = type(value) == "table" and value.data and copyBytes(value.data) or normalizeBytes(value)
    local asciiLimit = math.min(#bytes, limit or 64)
    local ascii = table.create(asciiLimit)

    for i = 1, asciiLimit do
        local b = bytes[i]
        ascii[i] = b >= 32 and b <= 126 and string.char(b) or "."
    end

    return {
        id = type(value) == "table" and value.id or bytes[1] or 0,
        size = #bytes,
        hex = raknet.tohex(bytes, limit or 64),
        ascii = table.concat(ascii),
        priority = type(value) == "table" and value.priority or nil,
        reliability = type(value) == "table" and value.reliability or nil,
        orderingChannel = type(value) == "table" and value.orderingChannel or nil,
        source = type(value) == "table" and value.source or nil,
        blocked = type(value) == "table" and value.blocked or nil,
    }
end

function raknet.diffpacket(left, right)
    local leftBytes = type(left) == "table" and left.data and copyBytes(left.data) or normalizeBytes(left)
    local rightBytes = type(right) == "table" and right.data and copyBytes(right.data) or normalizeBytes(right)
    local maxLen = math.max(#leftBytes, #rightBytes)
    local changes = {}

    for i = 1, maxLen do
        if leftBytes[i] ~= rightBytes[i] then
            changes[#changes + 1] = {
                index = i,
                left = leftBytes[i],
                right = rightBytes[i],
            }
        end
    end

    return {
        leftId = leftBytes[1] or 0,
        rightId = rightBytes[1] or 0,
        sameOpcode = (leftBytes[1] or 0) == (rightBytes[1] or 0),
        leftSize = #leftBytes,
        rightSize = #rightBytes,
        changed = #changes,
        changes = changes,
    }
end

function raknet.patch(value, edits)
    assert(type(edits) == "table", "patch expects an edits table")

    local isPacket = type(value) == "table" and value.data ~= nil
    local bytes = isPacket and copyBytes(value.data) or normalizeBytes(value)

    if edits.prepend ~= nil then
        local prefix = normalizeBytes(edits.prepend)
        local patched = table.create(#prefix + #bytes)
        for i = 1, #prefix do
            patched[#patched + 1] = prefix[i]
        end
        for i = 1, #bytes do
            patched[#patched + 1] = bytes[i]
        end
        bytes = patched
    end

    for key, valueAtIndex in pairs(edits) do
        if type(key) == "number" then
            bytes[key] = byte(valueAtIndex, "patch[" .. tostring(key) .. "]")
        end
    end

    if edits.insert ~= nil then
        assert(type(edits.insert) == "table", "patch.insert expects a table")
        local at = edits.insert.at or edits.insert.index or (#bytes + 1)
        assert(type(at) == "number" and at >= 1 and at % 1 == 0, "patch.insert.at expects a whole number")
        local insertBytes = normalizeBytes(edits.insert.bytes or edits.insert.data or {})

        for i = #insertBytes, 1, -1 do
            table.insert(bytes, at, insertBytes[i])
        end
    end

    if edits.remove ~= nil then
        if type(edits.remove) == "number" then
            table.remove(bytes, edits.remove)
        else
            assert(type(edits.remove) == "table", "patch.remove expects a number or table")
            local indexes = copyBytes(edits.remove)
            table.sort(indexes, function(a, b)
                return a > b
            end)

            for i = 1, #indexes do
                table.remove(bytes, indexes[i])
            end
        end
    end

    if edits.truncate ~= nil then
        assert(type(edits.truncate) == "number" and edits.truncate >= 0, "patch.truncate expects a number")
        while #bytes > edits.truncate do
            table.remove(bytes)
        end
    end

    if edits.append ~= nil then
        local suffix = normalizeBytes(edits.append)
        for i = 1, #suffix do
            bytes[#bytes + 1] = suffix[i]
        end
    end

    if isPacket then
        local packet = clonePacketSnapshot(value)
        packet.data = bytes
        packet.id = bytes[1] or 0
        packet.size = #bytes
        return packet
    end

    return bytes
end

function raknet.await(matcher: Matcher?, timeout: number?): PacketSnapshot?
    ensureHook()

    local wasCapturing = capturing
    capturing = true

    local predicate = makeMatcher(matcher)
    local deadline = os.clock() + (timeout or 5)
    local found: PacketSnapshot? = nil
    local connection

    connection = raknet.Capture:Connect(function(packet)
        if predicate(packet) then
            found = clonePacketSnapshot(packet)
            connection:Disconnect()
        end
    end)

    while os.clock() < deadline and found == nil do
        task.wait()
    end

    connection:Disconnect()
    if not wasCapturing then
        capturing = false
    end

    return found
end

function raknet.record(name: string?, source: string?)
    local recordName = name or "default"
    assert(type(recordName) == "string" and recordName ~= "", "record expects a name")

    recordings[recordName] = {
        active = true,
        packets = {},
        source = source,
    }

    raknet.startcapture()

    return {
        Stop = function(_self)
            return raknet.stoprecord(recordName)
        end,
    }
end

function raknet.stoprecord(name: string?): { PacketSnapshot }
    local recordName = name or "default"
    local recording = recordings[recordName]
    if not recording then
        return {}
    end

    recording.active = false

    local out = table.create(#recording.packets)
    for i = 1, #recording.packets do
        out[i] = clonePacketSnapshot(recording.packets[i])
    end

    return out
end

function raknet.replay(packets: { any }, delaySeconds: number?): { { ok: boolean, err: string? } }
    assert(type(packets) == "table", "replay expects a packet list")

    local results = table.create(#packets)
    for i = 1, #packets do
        local packet = packets[i]
        local ok, err = raknet.resend(packet)
        results[i] = { ok = ok, err = err }

        if delaySeconds and delaySeconds > 0 and i < #packets then
            task.wait(delaySeconds)
        end
    end

    return results
end

function raknet.waitfor(id: number?, timeout: number?): PacketSnapshot?
    return raknet.await(id, timeout)
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

function raknet.countopcodes(seconds: number?, source: string?): { [number]: number }
    local duration = math.max(0.05, seconds or 3)
    local previous = capturing
    local counts = {}
    local connection

    raknet.startcapture()
    connection = raknet.Capture:Connect(function(packet)
        if source == nil or packet.source == source then
            counts[packet.id] = (counts[packet.id] or 0) + 1
        end
    end)

    local deadline = os.clock() + duration
    while os.clock() < deadline do
        task.wait()
    end

    connection:Disconnect()
    if not previous then
        raknet.stopcapture()
    end

    return counts
end

function raknet.packetrate(seconds: number?, source: string?): number
    local duration = math.max(0.05, seconds or 3)
    local counts = raknet.countopcodes(duration, source)

    local total = 0
    for _, count in pairs(counts) do
        total += count
    end

    return total / duration
end

function raknet.resetstats()
    stats.sent = 0
    stats.blocked = 0
    stats.captured = 0
    stats.hookPackets = 0
    stats.manualPackets = 0
    stats.liveSends = 0
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
        sendErrors = stats.sendErrors,
        lastSendError = stats.lastSendError,
        byOpcode = opcodeStats,
    }
end

function raknet.teardown()
    local hook = rawget(nativeRakNet, "__wrapperHook")
    if type(hook) == "function" then
        pcall(nativeRemoveSendHook, hook)
        rawset(nativeRakNet, "__wrapperHook", nil)
    end

    hookRegistered = false
    capturing = false
    captureCallbacks = {}
    nextCallbackId = 0
    pendingManualSends = {}
    filterBytes = {}
    recordings = {}

    raknet.clearpipes()
    raknet.clearwatchers()
    raknet.clearrecent()
    raknet.resetstats()
end

raknet.Capture = setmetatable({}, Capture)
getgenv().raknet = raknet
getgenv().rnet = raknet

return raknet
