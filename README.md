# <p align="center"> raknet wrapper <p>

<p align="center">

  <a href="https://github.com/xaviersupreme/NBF9000/graphs/contributors">
    <img alt="Contributors" src="https://img.shields.io/github/contributors/xaviersupreme/NBF9000" />
  </a>

  <a href="https://github.com/xaviersupreme/NBF9000/issues">
    <img alt="Issues" src="https://img.shields.io/github/issues/xaviersupreme/NBF9000?color=0088ff" />
  </a>

  <a href="https://github.com/xaviersupreme/NBF9000/pulls">
    <img alt="Pull Requests" src="https://img.shields.io/github/issues-pr/xaviersupreme/NBF9000?color=0088ff" />
  </a>

  <a href="https://github.com/xaviersupreme/NBF9000/stargazers">
    <img alt="Stars" src="https://img.shields.io/github/stars/xaviersupreme/NBF9000?style=flat" />
  </a>

  <a href="https://github.com/xaviersupreme/NBF9000/network/members">
    <img alt="Forks" src="https://img.shields.io/github/forks/xaviersupreme/NBF9000?style=flat" />
  </a>

  <a href="https://github.com/xaviersupreme/NBF9000">
    <img alt="Last Commit" src="https://img.shields.io/github/last-commit/xaviersupreme/NBF9000" />
  </a>

  <a href="https://github.com/xaviersupreme/NBF9000">
    <img alt="Repo Size" src="https://img.shields.io/github/repo-size/xaviersupreme/NBF9000" />
  </a>
</p>

## added funcs:

- `raknet.sendraw(...)`
- `raknet.sendhex(...)`
- `raknet.sendstring(...)`
- `raknet.sendopcode(...)`
- `raknet.resend(...)`
- `raknet.sendlike(...)`
- `raknet.startcapture()`
- `raknet.stopcapture()`
- `raknet.setfilter(...)`
- `raknet.clearfilter()`
- `raknet.blockopcode(...)`
- `raknet.clearrecent()`
- `raknet.recent(...)`
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
- `raknet.countopcodes(...)`
- `raknet.packetrate(...)`
- `raknet.stats()`
- `raknet.resetstats()`

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
- `payload`: `{number}?`
- same return values as `sendraw`

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

- `prefix`: `{number}`
- `fn`: `(packet) -> ()`

`raknet.Capture:ConnectMatch(predicate, fn) -> { Disconnect: (self) -> () }`

- `predicate`: `(packet) -> boolean`
- `fn`: `(packet) -> ()`

`raknet.waitfor(id?, timeout?) -> packet?`

- `id`: `number?`
- `timeout`: `number?`

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

### Replay/history helpers

`raknet.clearrecent() -> ()`

`raknet.recent(limit?, source?) -> {packet}`

- `limit`: `number?`
- `source`: `string?`

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

### Stats helpers

`raknet.stats() -> table`

Returns a table containing:

- `sent: number`
- `blocked: number`
- `captured: number`
- `hookPackets: number`
- `manualPackets: number`
- `liveSends: number`
- `dryrunSends: number`
- `sendErrors: number`
- `lastSendError: string?`
- `mode: string`
- `byOpcode: { [number]: { sent: number, blocked: number, captured: number } }`

`raknet.resetstats() -> ()`

`raknet.getlasterror() -> string?`

`raknet.countopcodes(seconds?, source?) -> { [number]: number }`

- `seconds`: `number?`
- `source`: `string?`

`raknet.packetrate(seconds?, source?) -> number`

- `seconds`: `number?` — observation window length (default 3)
- `source`: `string?` — optional filter: `"hook"`, `"manual"`, `"manual-dryrun"`
- returns total packets per second seen during the window
- returns `0` if no packets were captured

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

## Return values

Most send helpers return:

```luau
local ok, err = raknet.sendopcode(0x83, { 0x00, 0x01 })
```

Possible outcomes:

- `true` when the packet was accepted by the wrapper
- `false, "blocked by filter"` when the local filter blocked it
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

 `sendBytes` - `stats.sent` counted dry-run sends

`stats.sent` and `stats.manualPackets` were incremented before the dryrun early-return,
so every dryrun send was double counted in both `stats.sent` and `stats.dryrunSends`.
They are now only incremented on the live path.

 `clearfilter` - unnecessary table allocation

`clearfilter()` called `setfilter({})` instead of `setfilter(nil)`,
causing `setfilter` to copy an empty table rather than using the nil handled path.

## Note

- markdown template made by @dodger1911#0
