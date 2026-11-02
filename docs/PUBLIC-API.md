# AltStable's public API

A small API for other addons that want to show AltStable's characters — first asked for
by GlassPanel's **[AltStable]** block (#123). It is read-only, apart from the own-account
channel (#281) a consumer uses to send its own data. Build on these functions, never on
`AltStableDB`: its layout is internal and changes without notice.

```toc
## OptionalDeps: AltStable
```

AltStable is not load-on-demand, so with that line these exist by the time your addon's
files run. Check before calling anyway — the player may not have AltStable installed:

```lua
if AltStable and AltStable.PUBLIC_API_VERSION then ... end
```

## `AltStable.PUBLIC_API_VERSION`

`1`. It changes on **any incompatible change**: a field's meaning or type, a removed field
or function, a function's arguments, the callback's behaviour. **Adding** a field or a
function does not change it, so read the fields you know and ignore the rest.

**Functions existing is not data being ready.** Right after login the logged-in character
may still hold what it had last session: AltStable rescans it about two seconds later, and a
`CharactersChanged` follows. Paint what you get, then repaint on the callback.

Not `AltStable.API` — that is AltStable's internal adapter for the Retail API, a
different table entirely.

## `AltStable.PUBLIC_API_FEATURES`

What this AltStable offers beyond version 1's first functions. They are additions, so the
version stays `1` and you check the flag instead:

```lua
local F = AltStable and AltStable.PUBLIC_API_FEATURES
if F and F.ownAccountChannel then ... end
```

| Flag | Since | Gives |
|---|---|---|
| `provenance` | #281 | `GetCharacterProvenance`, the `provenance*` fields on `GetCharacters`, `"ProvenanceChanged"` |
| `ownAccountChannel` | #281 | `SendToOwnAccounts`, `RegisterOwnAccountHandler`, `GetOwnAccountPeers`, `"OwnAccountPeersChanged"` |
| `gear` | #281 (AS-003) | `GetCharacterGear`, `"GearChanged"` |

An older AltStable has no table, or no flag. Treat that as "not available", not as an error.

## `AltStable.GetCharacters()` → `{ character, ... }`

Every character AltStable knows, sorted by realm, then name (a plain byte-wise, case-sensitive
comparison; the order of ties is unspecified). Each entry is a **fresh copy**: change it however
you like, it is not AltStable's data.

| Field | Type | Meaning |
|---|---|---|
| `guid` | string | The character's GUID - its identity. Names are not unique. |
| `name` | string | The best name known: normally the full name with its surname (`"Karuzo Elegia"`); a record from an older peer can lack the surname. |
| `realm` | string or nil | nil only on a record too old or too partial to carry it. |
| `faction` | string or nil | `"Alliance"` / `"Horde"`. |
| `class` | string or nil | Class file token, `"PRIEST"` - use it with `RAID_CLASS_COLORS`, and guard the nil. |
| `level` | number or nil | |
| `money` | number or nil | Copper. **nil means unknown** (the client would not say), never 0. |
| `account` | string | The number the player gave that WoW account in AltStable's options, as a string (`"2"`); `""` when unset. |
| `lastUpdate` | number or nil | The record's update stamp, `time()` on the client that last changed it - the character's own client, not when this client received it. A scan that learned nothing new can leave it unchanged. Good for "how old is this"; not a receive time. |
| `hidden` | boolean | The player hid it from AltStable's sheet. Yours to show dimmed or skip. |
| `current` | boolean | It is the character logged in right now. |
| `provenance` | string | Whose character it is: `"self"`, `"own-account"` or `"third-party"`. See `GetCharacterProvenance`. |
| `provenanceAt` | number or nil | When that was established (`time()` on this client); nil when not known. |
| `provenanceVia` | string or nil | For `"own-account"`, the name of the own account's character that said so. |

These are the characters AltStable's sheet lists: every one it has a record for. A character
the player **forgot** has no record, so it is not here - unless the player has logged into it
since, in which case it is back on the sheet and here too. **Hidden** ones are included,
flagged; `GetTotals` leaves them out, as the sheet's footer does.

## `AltStable.GetTotals()` → table

The numbers AltStable's own sheet footer shows — the footer computes itself with this
function, so a bar that shows "total gold" shows the same figure.

| Field | Meaning |
|---|---|
| `money` | Copper across the characters that count, known amounts only. |
| `unknown` | How many of those have no readable money. They are not counted as 0 — say so, e.g. `12,345g (+1 unknown)`. |
| `characters` | How many count: every character the sheet lists, less the hidden ones. Low-level bank alts count; they hold gold. |
| `hidden` | How many were left out for being hidden. |
| `levels` | Their levels summed. |

## `AltStable.GetCharacterProvenance(guid)` → `kind, at, via`

Whether a character is the player's own, for one GUID; `nil` for a character AltStable has
no record of. The same three values as the `provenance*` fields above.

| `kind` | Means |
|---|---|
| `"self"` | This client scans it: a character of the WoW account logged in here. |
| `"own-account"` | The player's own other WoW account said it scans it there. That account was proven the player's own by LibAccountSync, over Battle.net, and said so first-hand. |
| `"third-party"` | Anything else: a whitelisted friend's character, a record relayed by anyone (the player's own other account included), a sender AltStable could not prove. |

- The `account` label, a field on a received record and roster membership are **never**
  ownership: a peer can type or send any of them.
- It only moves up. `"third-party"` can become `"own-account"` or `"self"`. Nothing moves
  it back except the player forgetting the character.
- Own accounts on another Battle.net account are not proven, so their characters stay
  `"third-party"`. So do the characters of an own account that runs an AltStable older than
  #281, until it updates.
- `at` is nil for a `"self"` record not scanned since the update, and `via` is nil except
  for `"own-account"`.

## `AltStable.GetCharacterGear(guid)` → table

One character's equipped gear, as a copy; `nil` for a character AltStable has no record of.

| Field | Type | Meaning |
|---|---|---|
| `guid` | string | |
| `capturedAt` | number or nil | The latest time the record is known to show what was worn: the record's stamp (`lastUpdate`), or `gearAt` when that is later. It is not always a gear read. A plugin's change (bags, bank, recipes) moves the stamp too, but only while that character is played, and AltStable rescans the gear within about 3 seconds of any equipment change then. A scan holds `lastUpdate` back while an item is still uncached, but the item strings come from the links and are exact already. It is not a receive time. |
| `gearAt` | number or nil | When the worn items last changed, `time()` on the character's own client. It is separate from `lastUpdate`, which plugins move for their own data. nil on a record from an AltStable before #281. |
| `provenance` | string | As `GetCharacterProvenance`. |
| `slots` | table | Keyed by inventory slot id: 1-3 and 5-18. The shirt (4) and tabard (19) are not gear slots. |

Each slot is `{ slot, key, state, itemID, itemString, itemLevel }`:

| Field | Meaning |
|---|---|
| `state` | `"occupied"`, `"empty"` or `"unknown"`. |
| `itemString` | Given exactly when the slot is `"occupied"`: `"item:..."`, with the random suffix, the enchant and the gems. |
| `itemID` | Given for an occupied slot. For an `"unknown"` one too, when known, as a hint only. |
| `itemLevel` | nil when the scanning client had not cached the item. |

A slot is `"unknown"` when the record can't say which item is worn:

- the record has nothing for the slot;
- the record is from an AltStable before #281, which sent no item string;
- the record's string disagrees with its item id, enchant or gems. An older AltStable can relay a string it can't clear, so a mismatch is treated as stale.

`"unknown"` is never a guess at the item.

About the item string:

- **On Forever a random suffix is a bonus ID,** not the classic suffix field, which is always empty. This was measured on 205 stored links. *Beaded Wraps of the Sorcerer* is `item:14094::::::::::::1:12745`. The string keeps the bonus and modifier block.
- **It blanks the link level and spec,** which belong to the character that scanned the item, not to the item. A level-up therefore doesn't change it.
- **It drops what follows the modifiers,** such as a crafter's GUID.
- **Whether `GetItemStats` and `GetItemInfo` read such a trimmed string the same as the full link is not measured yet.** Glass Gear's GG-103 probe covers it.

## `AltStable.ToggleSheet()` / `AltStable.OpenSheet()`

`ToggleSheet` is what a click on an info-bar block should do: open the sheet, or close it if
it is open. `OpenSheet` only ever opens. Neither asks other accounts for a sync.

## `AltStable.GetPortraitStatus()` → `{ due, reason, changedSlots }`

Whether a new portrait capture is worth taking for the character being played (#128) -
the same answer that makes the sheet's capture button glow.

| field | |
|---|---|
| `due` | `true` when a capture is worth taking |
| `reason` | `"missing"` (no portrait, nothing captured), `"changed"` (the gear the portrait shows changed since the last capture), `"pending"` (captured, not yet turned into a portrait - **not** due) or `"none"` |
| `changedSlots` | for `"changed"`, the slot names that differ: `"Chest"`, `"Main Hand"`, ... |

Only the slots a portrait shows count - not rings, trinkets, the neck or the ranged slot (a relic as
often as a weapon) - and showing or hiding the helm or cloak counts as a change. A capture taken
before AltStable recorded looks never reads as `"changed"`. The action is
`AltStable.CapturePortrait()`, which refuses on its own in combat, in a dungeon, dead or
moving. Each call returns a new table.

## `AltStable.RegisterCallback("CharactersChanged", fn)` / `UnregisterCallback`

`fn("CharactersChanged")` is called after the characters change — a scan, a sync arriving,
the player forgetting or hiding a character. Read `GetCharacters`/`GetTotals` again then;
the callback carries nothing else.

- A burst of changes (a sync delivers many records at once) is **one** call, on the next frame.
- It can also fire when nothing you show changed. Repainting is cheap; missing a change is not.
- Your function runs under `pcall`: an error in it is reported through the normal error
  handler and does not stop AltStable or other listeners.
- A refresh you make from INSIDE the callback (keeping AltStable's sheet in step, say) is
  not a new change and does not call you again.
- Registering does not call you; the first call is the next change. A listener registered
  from inside a callback is called from the next change on. One unregistered from inside a
  callback may still receive the call already in progress.
- The events are `"CharactersChanged"`, `"PortraitStatusChanged"`, `"ProvenanceChanged"`,
  `"OwnAccountPeersChanged"` and `"GearChanged"` (below). Registering anything else is an
  error.

## `AltStable.RegisterCallback("PortraitStatusChanged", fn)`

`fn("PortraitStatusChanged")` is called when `GetPortraitStatus()` would answer
differently - gear changed, a capture was taken, the first look after logging in. One
call per change, on the next frame, with the same rules as above.

## `AltStable.RegisterCallback("ProvenanceChanged", fn)`

`fn("ProvenanceChanged")` is called when a character's provenance changes: a scan marks it
`"self"`, or a sync from an own account marks it `"own-account"`. Read
`GetCharacterProvenance` or `GetCharacters` again. Coalesced, with the same rules as above.

## `AltStable.RegisterCallback("GearChanged", fn)`

`fn("GearChanged", guids)` is called when a character's worn items change. That can be this
client's own scan, or a sync that brings a record whose gear differs from the one held.

- `guids` lists the characters that changed during the burst, sorted. Each listener gets its
  own list.
- A level-up alone is not a change. Neither is a newer record with the same gear.
- A sync that changes only a slot's enchant or gems is a change, since it can change the slot's
  state.
- The first scan after updating AltStable also reports one, with nothing changed.
- Changes made while nobody is registered are not collected.
- Otherwise it follows the same rules as the other callbacks.

## The own-account channel

A consumer's own data, sent between the player's own WoW accounts over AltStable's
LibAccountSync connection (Battle.net: any ruleset, any faction). AltStable checks both
directions **before** your code runs:

- **Out**, it goes only to accounts LibAccountSync proved the player's own, that the library
  lists right now and that run AltStable. An AltStable from before #281 drops the message
  unread, so it counts as sent but never arrives.
- **In**, it is accepted only from those accounts. It never goes over a whisper.
- An own account the player **refused** in AltStable's sync options is left out in both
  directions.
- A whitelisted friend is not an own account and never sends or receives any of it.

It is a transport, not a sync: it carries one message, with no retry, ordering or
acknowledgement. If you need to know that a message arrived, have the other side answer.

### `AltStable.SendToOwnAccounts(namespace, payload [, guid])` → `count [, why]`

Sends `payload` (any string, binary included) to every own account, or only to the one
whose character is `guid`.

- It returns how many accounts the library took the message for. With `0` it also returns
  why: `"no-peers"`, `"too-large"`, `"not-ready"`, `"unavailable"` (Battle.net sync is off or
  down) or another library reason.
- Taken is not delivered.
- `namespace` is 1-32 letters, digits, `_`, `.` or `-`; use your addon's name. The whole
  message, `EXT1|<namespace>|` included, is at most 32768 bytes.
- A bad namespace or a payload that is not a string is an error.

### `AltStable.RegisterOwnAccountHandler(namespace, fn)` / `UnregisterOwnAccountHandler(namespace)`

`fn(payload, sender)` runs once for each message to `namespace`.

- `sender` is the character it came from, as LibAccountSync proved it:
  `{ name, guid, realm, faction }`. The table is yours.
- There is one handler per namespace, and registering again replaces it.
- A message for a namespace with no handler is dropped.
- `fn` runs under `pcall`, as the callbacks do.

### `AltStable.GetOwnAccountPeers()` → `{ { name, guid, realm, faction }, ... }`

The own accounts a send would reach right now, as copies sorted by name. Each is the
character logged in on that account.

### `AltStable.RegisterCallback("OwnAccountPeersChanged", fn)`

`fn("OwnAccountPeersChanged")` is called when that list may have changed:

- an own account was found;
- the library stopped listing one;
- the player refused one in the sync options, or took the refusal back;
- Battle.net disconnected, or the player turned Battle.net sync off.

Send what the other side needs then, for example your data's version. It is coalesced like
the other callbacks.

## Example — a GlassPanel-style block

```lua
local function Gold(copper) return math.floor(copper / 10000) .. "g" end

local function Paint(block)
    local t = AltStable.GetTotals()
    block:SetText(Gold(t.money) .. (t.unknown > 0 and (" (+" .. t.unknown .. " ?)") or ""))
end

local function Tooltip(tip)
    for _, c in ipairs(AltStable.GetCharacters()) do
        if not c.hidden then
            local color = RAID_CLASS_COLORS[c.class]
            tip:AddDoubleLine(c.name, c.money and Gold(c.money) or "?",
                color and color.r or 1, color and color.g or 1, color and color.b or 1)
        end
    end
end

AltStable.RegisterCallback("CharactersChanged", function() Paint(myBlock) end)
myBlock:SetScript("OnClick", function() AltStable.ToggleSheet() end)
```
