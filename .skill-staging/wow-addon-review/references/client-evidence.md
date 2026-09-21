# Client and API Evidence

Use this reference to decide what the target client actually declares and does. A familiar API name is not enough: WoW products reuse names while changing owners, signatures, return shapes, availability, and semantics.

## Identify the client on separate axes

Establish each axis from repository evidence rather than collapsing them into a single flavor label:

- product/distribution and supported branches;
- exact client build and `.toc` Interface value;
- API codebase or `WOW_PROJECT_ID`;
- content/expansion rules and data;
- embedded Lua version;
- enabled Blizzard systems and protected-action behavior.

Classic Era, anniversary/progression clients, Retail/Mainline, and other Blizzard game types can differ on more than one axis. Do not map an Interface number to a product from memory. Read the `.toc`, project instructions, build constants, and measured notes together. If the project supports multiple products, review every changed branch and its packaging metadata.

## Evidence order

Prefer evidence in this order for the question it can answer:

1. measurements from the exact build, recorded in project or shared reference notes, for runtime behavior;
2. a client-generated API dump stamped for the exact build, for declared names and shapes;
3. the repository's compatibility layer and strict stubs, after checking that they cite or match the first two sources;
4. official documentation for the exact product/build when local evidence is absent;
5. reasoned inference, clearly labeled as unverified.

Do not silently use an older dump when its build does not match the project's measured build. Report the dump as stale and the affected API claims as unverified.

An API dump proves only what it contains: documented signatures, optional markers, returns, events, enums, globals, namespaces, or widget methods according to that dump's generator. It does not prove that a present API behaves usefully on the target content client.

## Check the right surface

For every API reached by changed behavior, verify the relevant surfaces:

- global functions and values;
- `C_*` namespaces and prefix-less namespace tables;
- widget methods, including the owning widget/system and overload-specific signature;
- events and their ordered payloads;
- enums and constants;
- internal event systems or mixins when the project deliberately uses them.

The same method name may belong to several widget types with different signatures. Use the documented owner, not name-only search results.

Absence from one surface is strong evidence, not proof of global absence. Before reporting a missing API, search all plausible surfaces and state which ones were checked. Conversely, presence proves declaration and shape, not runtime semantics, content availability, combat safety, or useful results.

## Shape and lifecycle traps

Check for tuple-versus-struct changes, renamed fields, nil/uncached returns, asynchronous item or spell data, and callbacks that can fire before addon state or frames exist. Confirm event payload order rather than borrowing it from another client flavor.

When a project wraps APIs in an adapter, review both the adapter contract and the target-client call. Prefer existing adapters at call sites when repository architecture requires them.

Mocks can conceal incompatibility by returning an old tuple, accepting any widget method, or defining globals absent from the client. A useful stub should fail loudly for unknown globals/methods and model the exact target shape, but only where the project's harness supports that strictness.

## Persistence evidence

`/reload` does not prove SavedVariables persist across client processes: memory remains alive and can make a failed load appear successful. A persistence claim requires a full client exit, relaunch, and an in-addon observation that distinguishes loaded state from defaults or freshly rescanned state.

Seeing a value written to disk does not alone prove the next process loaded it. Treat file inspection as evidence of writing, not reading.
