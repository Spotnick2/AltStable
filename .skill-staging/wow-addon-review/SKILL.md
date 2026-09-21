---
name: wow-addon-review
description: "Review committed changes in World of Warcraft addon repositories. Use for pull-request and code reviews when the repository is identified by a WoW .toc manifest or project instructions, including Retail/Mainline, Classic variants, and WoW: Forever; do not use for ordinary implementation work or generic Lua repositories."
---

# WoW Addon Review

Review the actual change against the exact client it targets. Find actionable correctness and compatibility defects without replacing repository-specific design choices with generic addon advice.

Repository instructions remain authoritative for project facts, commands, posting requirements, and local invariants. This skill supplies the shared review method so those instructions do not need to repeat it.

## Confirm the target

Treat a repository as a WoW addon when project instructions say so or when a `.toc` addon manifest and WoW Lua/XML sources establish it. Do not classify a generic Lua project from filenames alone.

Before judging code, determine from repository evidence:

- supported game product or products, client build, and `.toc` `## Interface` value;
- API codebase or project ID separately from content/expansion rules;
- embedded Lua version, manifest load order, dependencies, load-on-demand boundaries, and SavedVariables declarations;
- the project's authoritative API dump, measured client notes, adapters, and validation commands.

Do not reduce the target to “Retail or Classic.” WoW: Forever combines Vanilla content rules with the Mainline UI code family, and future products may combine dimensions differently. Never infer content semantics solely from `WOW_PROJECT_ID`, an Interface number, or an API family name. For a Forever target, read [forever.md](references/forever.md).

If the target or matching evidence cannot be established, state the limitation and avoid confident compatibility claims. Read [client-evidence.md](references/client-evidence.md) whenever the change calls WoW APIs, handles events or widgets, depends on client behavior, or makes persistence claims.

## Route substantive reviews

Before starting a substantive review, assess its shape and consequence and recommend an appropriate model/effort pair. Do not silently switch the session configuration.

- `gpt-5.6-sol` / `medium`: routine substantive reviews.
- `gpt-5.6-sol` / `high`: bounded surfaces with dense or subtle localized logic.
- `gpt-6-astra` / `medium`: broad, ambiguous, or cross-component behavior needing stronger overall judgment.
- `gpt-6-astra` / `high`: broad and high-consequence work involving security/privacy boundaries, destructive behavior, concurrency, identity, or silent-corruption risk.

Documentation-only, generated, or obviously mechanical reviews do not need this substantive baseline unless repository policy says otherwise. A dedicated Codex Security scan is separate from ordinary correctness review; use its documented model/effort only with the required explicit approval.

## Review the committed change

For a pull request, inspect the committed merge-base diff rather than treating unrelated working-tree changes as part of the PR. Verify the repository and PR identity before using a bare issue or PR number, especially when reviewing a shared library from a consumer repository. Preserve unrelated local edits.

Read enough surrounding code to understand load order, callers, state ownership, migrations, tests, and packaging. Review by reachable behavior, not changed lines alone. Apply [review-checklist.md](references/review-checklist.md) selectively; it is a defect checklist, not a requirement to discuss every item.

Prioritize:

1. silent wrong behavior, data loss/corruption, security or protected-action failures;
2. client/build incompatibility, manifest/load-order breakage, and protocol incompatibility;
3. event-order, caching, lifecycle, and SavedVariables defects;
4. missing regression coverage for behavior changed by the patch;
5. maintainability issues only when they create a concrete defect or meaningful near-term risk.

Respect intentional project scope. Do not report style preferences, speculative future extensibility, or a different architecture as findings unless they cause an actionable problem in the reviewed change.

## Validate evidence

Check every WoW API used by the changed behavior against the build-matched client evidence declared by the repository. Verify argument order, optionality, return shape, event payloads, enums, widget ownership, and availability on the relevant surface. Tests and stubs are not independent proof if they merely repeat an incorrect API assumption.

Run the repository's proportionate review validations when authorized: syntax checks with the declared Lua version, focused tests, then the normal suite when warranted. Check `.toc` entries and packaging inputs for added, removed, or renamed files. Do not mutate code merely because a review found a defect.

For claims that require in-game confirmation, distinguish declared API shape from measured behavior and say exactly what remains unverified.

## Report and conclude

Lead with actionable findings ordered by severity. Each finding should identify the affected file/line or smallest useful location, the concrete failing scenario, why the target client reaches it, and the minimal direction for correction. Separate findings from questions and validation limitations.

If there are no findings, give a concise review summary with validations performed and material limitations. For every pull-request review and follow-up review, end with exactly one merge-readiness verdict:

- `Ready for merge` — no required corrective work remains.
- `Not ready for merge` — list the remaining required work.

Post the review to the PR only when the user or repository instructions require it and the available integration is authorized. Link the posted review in the final response.
