# <p align="center"> raknet wrapper <p>

<p align="center">
  <a href="https://github.com/xaviersupreme/raknet-wrapper/graphs/contributors">
    <img alt="Contributors" src="https://img.shields.io/github/contributors/xaviersupreme/raknet-wrapper" />
  </a>

  <a href="https://github.com/xaviersupreme/raknet-wrapper/issues">
    <img alt="Issues" src="https://img.shields.io/github/issues/xaviersupreme/raknet-wrapper?color=0088ff" />
  </a>

  <a href="https://github.com/xaviersupreme/raknet-wrapper/pulls">
    <img alt="Pull Requests" src="https://img.shields.io/github/issues-pr/xaviersupreme/raknet-wrapper?color=0088ff" />
  </a>

  <a href="https://github.com/xaviersupreme/raknet-wrapper/stargazers">
    <img alt="Stars" src="https://img.shields.io/github/stars/xaviersupreme/raknet-wrapper?style=flat" />
  </a>

  <a href="https://github.com/xaviersupreme/raknet-wrapper/network/members">
    <img alt="Forks" src="https://img.shields.io/github/forks/xaviersupreme/raknet-wrapper?style=flat" />
  </a>

  <a href="https://github.com/xaviersupreme/raknet-wrapper">
    <img alt="Last Commit" src="https://img.shields.io/github/last-commit/xaviersupreme/raknet-wrapper" />
  </a>

  <a href="https://github.com/xaviersupreme/raknet-wrapper">
    <img alt="Repo Size" src="https://img.shields.io/github/repo-size/xaviersupreme/raknet-wrapper" />
  </a>
</p>

## new stuff:

**pipes**

named packet edits/blockers that run on outgoing packets:

```luau
raknet.pipe("no-83", function(packet)
    if packet.id == 0x83 then
        return false
    end
end)
```

edit a packet:

```luau
raknet.pipe("patch-83", function(packet)
    if packet.id == 0x83 then
        return raknet.patch(packet, {
            [2] = 0x07,
            append = "FF",
        })
    end
end)
```

remove pipes:

```luau
raknet.unpipe("patch-83")
raknet.clearpipes()
```

**rules**

same idea as pipes but less typing:

```luau
raknet.rules("basic", {
    { opcode = 0x83, action = "log" },
    { prefix = "84 00", action = "block" },
    { opcode = 0x85, patch = { [2] = 0x01 } },
})
```

**watch / await**

named capture listeners:

```luau
raknet.watch("movement", { opcode = 0x83 }, function(packet)
    print(raknet.tohex(packet.data))
end)

raknet.unwatch("movement")
```

wait for an opcode, prefix, matcher table, or custom function:

```luau
local packet = raknet.await({ prefix = "83 07" }, 5)
```

**packet tools**

quick inspect / patch / compare helpers:

```luau
local info = raknet.inspect("83 41 42")
print(info.hex, info.ascii)

local changed = raknet.patch("83 00 01", {
    [2] = 0x07,
    append = "FF",
})

local diff = raknet.diffpacket("83 00 01", "83 07 01")
print(diff.changed)
```

**record / replay**

record outgoing packets and send them back later:

```luau
local rec = raknet.record("test", "manual")

raknet.sendhex("83 00 01")

local packets = rec:Stop()
raknet.replay(packets, 0.1)
```

**cleanup**

```luau
raknet.teardown()
```

## added funcs:

- `raknet.sendraw(...)`
- `raknet.sendhex(...)`
- `raknet.sendstring(...)`
- `raknet.sendopcode(...)`
- `raknet.sendmany(...)`
- `raknet.resend(...)`
- `raknet.sendlike(...)`
- `raknet.startcapture()`
- `raknet.stopcapture()`
- `raknet.setfilter(...)`
- `raknet.clearfilter()`
- `raknet.blockopcode(...)`
- `raknet.pipe(...)`
- `raknet.unpipe(...)`
- `raknet.clearpipes()`
- `raknet.listpipes()`
- `raknet.rules(...)`
- `raknet.watch(...)`
- `raknet.unwatch(...)`
- `raknet.clearwatchers()`
- `raknet.clearrecent()`
- `raknet.recent(...)`
- `raknet.setrecentlimit(...)`
- `raknet.getrecentlimit()`
- `raknet.findrecent(...)`
- `raknet.clonepacket(...)`
- `raknet.matchprefix(...)`
- `raknet.Capture:Connect(...)`
- `raknet.Capture:Once(...)`
- `raknet.Capture:ConnectOpcode(...)`
- `raknet.Capture:ConnectPrefix(...)`
- `raknet.Capture:ConnectMatch(...)`
- `raknet.tohex(...)`
- `raknet.fromhex(...)`
- `raknet.hexdiff(...)`
- `raknet.packettostring(...)`
- `raknet.inspect(...)`
- `raknet.diffpacket(...)`
- `raknet.patch(...)`
- `raknet.await(...)`
- `raknet.record(...)`
- `raknet.stoprecord(...)`
- `raknet.replay(...)`
- `raknet.countopcodes(...)`
- `raknet.packetrate(...)`
- `raknet.stats()`
- `raknet.resetstats()`
- `raknet.teardown()`

## API

### Send helpers

`raknet.sendraw(value, priority?, reliability?, orderingChannel?) -> (boolean, string?)`

- `value`: `string | {number}`
- `priority`: `number?`
- `reliability`: `number?`
- `orderingChannel`: `number?`
- returns:
  - `true` if the packet was accepted
  - `false, "blocked by filter"` if your local filter blocked it
  - `false, <error>` if native send failed

`raknet.sendhex(value, priority?, reliability?, orderingChannel?) -> (boolean, string?)`

- `value`: `string`
- same return values as `sendraw`

`raknet.sendstring(value, priority?, reliability?, orderingChannel?) -> (boolean, string?)`

- `value`: `string`
- same return values as `sendraw`

`raknet.sendopcode(id, payload?, priority?, reliability?, orderingChannel?) -> (boolean, string?)`

- `id`: `number`
- `payload`: `{number}? | string?`
- same return values as `sendraw`

`raknet.sendmany(packets) -> { { ok: boolean, err: string? } }`

- `packets`: `{ { bytes: {number} | string, priority: number?, reliability: number?, orderingChannel: number? } }`
- sends each packet in order

`raknet.resend(packet, priority?, reliability?, orderingChannel?) -> (boolean, string?)`

- `packet`: `{ data: {number}, priority: number?, reliability: number?, orderingChannel: number? }`
- resends packet data, using packet transport values unless you override them

`raknet.sendlike(packet, newBytes) -> (boolean, string?)`

- `packet`: `{ priority: number?, reliability: number?, orderingChannel: number? }`
- `newBytes`: `{number} | string`
- sends replacement bytes with the same transport values as the source packet

### Capture helpers

`raknet.startcapture() -> ()`

`raknet.stopcapture() -> ()`

`raknet.iscapturing() -> boolean`

`raknet.Capture:Connect(fn) -> { Disconnect: (self) -> () }`

- `fn`: `(packet) -> ()`

`raknet.Capture:Once(fn) -> { Disconnect: (self) -> () }`

- same callback type as `Connect`

`raknet.Capture:ConnectOpcode(id, fn) -> { Disconnect: (self) -> () }`

- `id`: `number`
- `fn`: `(packet) -> ()`

`raknet.Capture:ConnectPrefix(prefix, fn) -> { Disconnect: (self) -> () }`

- `prefix`: `{number} | string`
- `fn`: `(packet) -> ()`

`raknet.Capture:ConnectMatch(predicate, fn) -> { Disconnect: (self) -> () }`

- `predicate`: `(packet) -> boolean`
- `fn`: `(packet) -> ()`

`raknet.waitfor(id?, timeout?) -> packet?`

- `id`: `number?`
- `timeout`: `number?`

`raknet.await(matcher?, timeout?) -> packet?`

- `matcher`: `number | string | {number} | table | function`
- accepts opcode numbers, byte prefixes, predicate functions, or matcher tables like `{ opcode = 0x83 }`

`raknet.captureonce(id?, timeout?) -> packet?`

- `id`: `number?`
- `timeout`: `number?`

### Filter helpers

`raknet.setfilter(bytes?) -> ()`

- `bytes`: `{number}?`

`raknet.clearfilter() -> ()`

`raknet.getfilter() -> {number}`

`raknet.blockopcode(id) -> ()`

- `id`: `number`

### Pipes/watchers

`raknet.pipe(name, fn) -> { Remove: (self) -> () }`

- `name`: `string`
- `fn`: `(packet) -> packet? | false | nil`
- return `false` to block the packet
- return a packet table to replace it
- return `nil` to leave it unchanged

`raknet.unpipe(name) -> ()`

`raknet.clearpipes() -> ()`

`raknet.listpipes() -> {string}`

`raknet.rules(name?, rules) -> { Remove: (self) -> () }`

- simple named pipe builder
- rule actions can be `"block"`, `"log"`, a function, or a `patch` table

`raknet.watch(name, matcher?, fn) -> { Remove: (self) -> (), Disconnect: (self) -> () }`

- named capture listener
- replaces an older watcher with the same name

`raknet.unwatch(name) -> ()`

`raknet.clearwatchers() -> ()`

### Replay/history helpers

`raknet.clearrecent() -> ()`

`raknet.recent(limit?, source?) -> {packet}`

- `limit`: `number?`
- `source`: `string?`

`raknet.setrecentlimit(limit) -> ()`

- `limit`: `number`

`raknet.getrecentlimit() -> number`

`raknet.findrecent(matcher?, source?) -> packet?`

- searches newest-first
- uses the same matcher shapes as `await`

`raknet.clonepacket(packet) -> packet`

- `packet`: `table`

`raknet.matchprefix(bytes, prefix) -> boolean`

- `bytes`: `{number} | string`
- `prefix`: `{number} | string`

### Formatting helpers

`raknet.tohex(bytes, limit?) -> string`

- `bytes`: `{number} | string`
- `limit`: `number?`

`raknet.fromhex(value) -> {number}`

- `value`: `string`

`raknet.hexdiff(left, right) -> string`

- `left`: `{number} | string`
- `right`: `{number} | string`

`raknet.packettostring(packet) -> string`

- `packet.id`: `number?`
- `packet.data`: `{number}?`
- `packet.source`: `string?`
- `packet.blocked`: `boolean?`

`raknet.inspect(value, limit?) -> table`

- returns `id`, `size`, `hex`, `ascii`, and transport fields when available

`raknet.diffpacket(left, right) -> table`

- returns changed byte indexes and size/opcode info

`raknet.patch(value, edits) -> {number} | packet`

- supports numeric byte edits plus `prepend`, `append`, `insert`, `remove`, and `truncate`

`raknet.record(name?, source?) -> { Stop: (self) -> {packet} }`

`raknet.stoprecord(name?) -> {packet}`

`raknet.replay(packets, delaySeconds?) -> { { ok: boolean, err: string? } }`

### Stats helpers

`raknet.stats() -> table`

Returns a table containing:

- `sent: number`
- `blocked: number`
- `captured: number`
- `hookPackets: number`
- `manualPackets: number`
- `liveSends: number`
- `sendErrors: number`
- `lastSendError: string?`
- `byOpcode: { [number]: { sent: number, blocked: number, captured: number } }`

`raknet.resetstats() -> ()`

`raknet.getlasterror() -> string?`

`raknet.countopcodes(seconds?, source?) -> { [number]: number }`

- `seconds`: `number?`
- `source`: `string?`

`raknet.packetrate(seconds?, source?) -> number`

- `seconds`: `number?` — observation window length (default 3)
- `source`: `string?` — optional filter: `"hook"` or `"manual"`
- returns total packets per second seen during the window
- returns `0` if no packets were captured

`raknet.teardown() -> ()`

- removes wrapper hook and clears wrapper state

## Basic examples

Send a raw byte table:

```luau
raknet.sendraw({ 0x83, 0x00, 0x01 })
```

Send a hex string:

```luau
raknet.sendhex("83 00 01")
```

Send a packet by opcode:

```luau
raknet.sendopcode(0x83, { 0x00, 0x01 })
```

Re-send a captured packet:

```luau
local packet = raknet.captureonce(0x83, 5)
if packet then
    raknet.resend(packet)
end
```

Send new bytes with the same transport values as a real packet:

```luau
local packet = raknet.captureonce(0x83, 5)
if packet then
    raknet.sendlike(packet, { 0x83, 0x99, 0x01 })
end
```

Send a batch:

```luau
raknet.sendmany({
    { bytes = { 0x83, 0x00 } },
    { bytes = "83 01" },
})
```

## Capture

Start capture and listen for packets:

```luau
raknet.startcapture()

local conn = raknet.Capture:Connect(function(packet)
    print(raknet.packettostring(packet))
end)
```

Listen for a single opcode:

```luau
local conn = raknet.Capture:ConnectOpcode(0x83, function(packet)
    print("data packet:", raknet.tohex(packet.data))
end)
```

One time listener:

```luau
raknet.Capture:Once(function(packet)
    print("first packet:", packet.id)
end)
```

Match by prefix:

```luau
local conn = raknet.Capture:ConnectPrefix({ 0x83, 0x07 }, function(packet)
    print("prefix match:", raknet.packettostring(packet))
end)
```

Match with a custom predicate:

```luau
local conn = raknet.Capture:ConnectMatch(function(packet)
    return packet.id == 0x83 and packet.data[2] == 0x07
end, function(packet)
    print("custom match:", raknet.packettostring(packet))
end)
```

Named watcher:

```luau
raknet.watch("data", { opcode = 0x83 }, function(packet)
    print("watch:", raknet.tohex(packet.data))
end)
```

Stop capture:

```luau
raknet.stopcapture()
conn:Disconnect()
```

## Filters

Block by prefix:

```luau
raknet.setfilter({ 0x83, 0x00 })
```

Block by opcode:

```luau
raknet.blockopcode(0x83)
```

Clear filter:

```luau
raknet.clearfilter()
```

important: filtering is prefix based.  
`{ 0x83 }` blocks any packet starting with `0x83`.  
`{ 0x83, 0x00 }` only blocks packets whose first two bytes are `83 00`.

## Pipes

Block a packet before it leaves:

```luau
raknet.pipe("no-83", function(packet)
    if packet.id == 0x83 then
        return false
    end
end)
```

Patch a packet before it leaves:

```luau
raknet.pipe("edit", function(packet)
    if packet.id == 0x83 then
        return raknet.patch(packet, {
            [2] = 0x07,
            append = { 0x00 },
        })
    end
end)
```

Simple rules:

```luau
raknet.rules("basic", {
    { opcode = 0x83, action = "log" },
    { prefix = "84 00", action = "block" },
})
```

## Return values

Most send helpers return:

```luau
local ok, err = raknet.sendopcode(0x83, { 0x00, 0x01 })
```

Possible outcomes:

- `true` when the packet was accepted by the wrapper
- `false, "blocked by filter"` when the local filter blocked it
- `false, "blocked by pipe: <name>"` when a pipe blocked a wrapper send
- `false, <executor error>` when native live send failed

## Formatting helpers

Bytes to hex:

```luau
print(raknet.tohex({ 0x83, 0x00, 0x01 }))
-- 83 00 01
```

Hex to bytes:

```luau
local bytes = raknet.fromhex("83 00 01")
```

Hex diff:

```luau
print(raknet.hexdiff({ 0x83, 0x00, 0x01 }, { 0x83, 0x07, 0x01 }))
```

Packet summary:

```luau
print(raknet.packettostring({
    id = 0x83,
    data = { 0x83, 0x00, 0x01 },
    source = "manual",
    blocked = false,
}))
```

Inspect packet:

```luau
local info = raknet.inspect({ 0x83, 0x41, 0x42 })
print(info.hex, info.ascii)
```

Patch bytes:

```luau
local bytes = raknet.patch("83 00 01", {
    [2] = 0x07,
    append = "FF",
})
```

Diff packets:

```luau
local diff = raknet.diffpacket("83 00 01", "83 07 01")
print(diff.changed)
```

## Stats

Get counters:

```luau
local s = raknet.stats()
print(s.sent, s.captured, s.blocked)
```

Reset counters:

```luau
raknet.resetstats()
```

Count opcodes for a short capture window:

```luau
local counts = raknet.countopcodes(3, "manual")
print(counts[0x83], counts[0x84])
```

Read recent captured packets:

```luau
local packets = raknet.recent(10, "manual")
for i = 1, #packets do
    print(raknet.packettostring(packets[i]))
end
```

Find one recent packet:

```luau
local packet = raknet.findrecent({ opcode = 0x83 }, "manual")
```

Record and replay:

```luau
local rec = raknet.record("test", "manual")
raknet.sendhex("83 00 01")
local packets = rec:Stop()
raknet.replay(packets, 0.1)
```

Last native send error:

```luau
print(raknet.getlasterror())
```

Get packets per second over a 5-second window:

```luau
local pps = raknet.packetrate(5)
print(string.format("%.1f packets/sec", pps))
```

Measure rate for hook-sourced packets only:

```luau
local pps = raknet.packetrate(3, "hook")
print(string.format("%.1f hook packets/sec", pps))
```

## Bug fixes

 `normalizeBytes` - hex branch checked wrong variable

`isHexString` was called on the original `value` instead of the already stripped `compact`.
Inputs like `"AB CD"` (spaced hex) would fall through to the raw-string branch and encode
space characters as `0x20` instead of being decoded as hex bytes.

 `waitfor` - capture was never enabled

`waitfor` registered a capture connection but never called `startcapture()`,
so `fireCapture` was gated out and the function would always hang until timeout.
Now saves and restores the previous capture state around the wait.

 `sendBytes` - failed sends counted as sent

`stats.sent`, `stats.manualPackets`, and `stats.liveSends` are now only incremented
after the native send succeeds.

 `clearfilter` - unnecessary table allocation

`clearfilter()` called `setfilter({})` instead of `setfilter(nil)`,
causing `setfilter` to copy an empty table rather than using the nil handled path.

## Note

- markdown template made by @dodger1911#0
