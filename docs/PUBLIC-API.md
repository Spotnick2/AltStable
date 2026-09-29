# AltStable's public API

A small, read-only API for other addons that want to show AltStable's characters —
first asked for by GlassPanel's **[AltStable]** block (#123). Build on these functions,
never on `AltStableDB`: its layout is internal and changes without notice.

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

## `AltStable.ToggleSheet()` / `AltStable.OpenSheet()`

`ToggleSheet` is what a click on an info-bar block should do: open the sheet, or close it if
it is open. `OpenSheet` only ever opens. Neither asks other accounts for a sync.

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
- `"CharactersChanged"` is the only event. Registering anything else is an error.

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
