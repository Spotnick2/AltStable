# WoW Addon Review Checklist

Use only the sections touched by the change. These prompts help find defects; they are not mandatory architecture or reporting headings.

## Manifest, load, and packaging

- Does every runtime file appear in the correct `.toc` order, and do XML/script references resolve with the packaged path and case?
- Are `## Interface`, dependencies, optional dependencies, load-on-demand metadata, SavedVariables, and per-flavor manifests consistent with the supported client?
- Can a module run before its namespace, library, database, localization, or adapter exists?
- Will release/deploy rules include new files and exclude tools, tests, fixtures, and local artifacts?
- For embedded libraries or plugin addons, are version negotiation, dependency boundaries, and duplicate-copy behavior preserved?

## Lua runtime and state

- Is syntax and library usage valid for the client's embedded Lua version rather than the developer's system Lua?
- Are globals accidental, file-local captures stale, closures retaining obsolete state, or tables aliased where a copy was intended?
- Are nil, false, zero, empty string, unknown, and absent values semantically distinct in this project?
- Does initialization tolerate disabled dependencies, partial SavedVariables, first run, schema upgrades, and logout/reload ordering?
- Could iteration order, sparse arrays, locale-specific strings, or character/realm identity produce silent misassociation?

## API, events, and cached game data

- Is every changed API call verified against the exact client/build and correct owner?
- Are argument order, optional values, tuple/struct shape, enum values, event payload order, and widget method signatures correct?
- Does code distinguish “not cached yet” from “does not exist,” and schedule a refresh when data becomes available?
- Can events arrive before login/world readiness, after frames are hidden/destroyed, or in bursts that expose stale state?
- Are unit, GUID, name-realm, specialization/class, item/spell, bag, reputation, profession, and difficulty assumptions valid for the target content as well as its API codebase?

## UI, secure execution, and combat

- Could the change create, reparent, resize, show/hide, or change attributes on protected frames during combat lockdown?
- Does it taint secure templates, protected actions, bindings, unit attributes, or click-casting paths?
- Are scripts hooked without replacing Blizzard behavior unintentionally, and are callbacks registered/unregistered with stable identities?
- Do frame ownership, anchoring, strata/level, scaling, scrolling, tooltip cleanup, and pooled-widget reuse remain correct?
- Are hardware-event requirements respected for spell, item, macro, targeting, trade, mail, or other protected actions?

## SavedVariables, migrations, and protocols

- Does new state preserve old schemas and distinguish absent legacy fields from explicit empty/unknown values?
- Are reset, copy, delete, serialization, deserialization, merge, and sync paths updated together?
- Can malformed, partial, oversized, duplicated, reordered, or version-mismatched messages corrupt state or leave a transfer stuck?
- Are addon-message prefixes, channel rules, byte limits, encoding expansion, throttling, checksums, sender identity, and trust boundaries handled by the established protocol?
- Does a wire-format change have the required protocol/version migration and clean old-client behavior?

## Performance and user-visible behavior

- Does work scale with combat-log/event frequency, raid size, bag size, or UI refresh rate?
- Are scans, sorting, serialization, texture/item lookups, and frame creation repeated in hot paths without invalidation or throttling?
- Could timers outlive the state they mutate, coalesce incorrectly, or reorder user-visible actions?
- Are locale, surname/spaced-name, realm, faction, class, and content-cap assumptions hardcoded where the target makes them dynamic?

## Tests and validation

- Is the regression test capable of failing when the changed behavior is deliberately broken?
- Do stubs reproduce the exact target-client shape and reject unsupported globals or methods where practical?
- Are protected/combat, uncached, nil, legacy-data, malformed-message, and load-order branches covered when the patch changes them?
- Were changed Lua files parsed with the declared Lua interpreter/compiler, and were the repository's focused and full tests run?
- Which conclusions still require an exact-build in-game probe, a full client restart, or packaging/deploy verification?
