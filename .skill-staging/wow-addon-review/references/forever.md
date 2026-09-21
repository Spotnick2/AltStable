# WoW: Forever Review Context

Read this reference only for projects targeting World of Warcraft: Forever.

## Product model

Blizzard's WoW UI team described Forever and modern WoW as separate game types within the Mainline code family: Forever's pre-launch game-type name was `Camelot`, while modern WoW's is `Standard`. Blizzard said Forever shares Mainline's UI architecture and the vast majority of APIs available in 12.1.5.

Treat that as an architecture baseline, not proof of API identity. Forever combines Vanilla content with a Mainline-derived client, so review content assumptions and API assumptions separately. The exact build's client-generated dump and in-game measurements remain authoritative for the actual surface and behavior.

Do not describe Forever simply as Classic, ordinary Retail, or a Classic client with Retail shims. Do not infer Vanilla-era globals from its content, or modern expansion data from its code family.

## Shared UI restrictions

Blizzard said the addon-disarmament changes introduced for Midnight, including secrets, are active in Forever. Blizzard also said the 12.1.0 `AuraContainer`/`AuraButton` changes are available there and that similar future UI changes should be expected in both Standard and Forever.

Accordingly, review Forever changes for:

- secret values crossing comparison, formatting, table-key, serialization, logging, or other restricted boundaries;
- protected-action and combat-lockdown behavior inherited from the Mainline UI architecture;
- aura code that assumes legacy button ownership, enumeration, templates, or data flow;
- new shared Mainline restrictions that the repository's last measured build may not yet document.

Do not turn announced shared direction into a claim that every Standard API or behavior exists in Forever. Require build-matched evidence, and mark claims unverified when the project dump or measurements predate the target build.

## Evidence provenance

The architecture and shared-restriction statements above come from Blizzard UI-team communication supplied by the skill owner in September 2026. They establish platform direction but are not a substitute for a build-stamped dump or reproducible client probe.
