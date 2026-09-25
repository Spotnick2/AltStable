# CLAUDE.md — Claude-specific overlay

`AGENTS.md` is the shared, cross-agent baseline (project layout, build/test/deploy, conventions,
review policy, and the **model tiers + cost discipline**). This file only adds the
Claude-specific bits that don't belong in the cross-agent baseline. When the two overlap,
AGENTS.md is the source of truth.

## Model, in one line

On Max, usage isn't the constraint, so **the latest Opus is the default for direct work in the
main thread** — not just architecture calls. Subagents still default to the latest Sonnet
(routine implementation, tests) or Haiku (exploration, file-finding, deploy/file-copy). See the
tier table in `AGENTS.md`. Always use the newest version of each family; don't pin a version
number here.

**Code review is carved out of this.** The shared `$wow-addon-review` skill governs (see "Review
policy" in `AGENTS.md`): model and effort routing, recommended per review before starting and
never switched silently. That rule beats the Opus default whenever the task is a review.

## Adversarial review — prefer a *different* family

When the user asks for a second opinion, a critique, or an adversarial review of a **plan or
design**, the value is decorrelated blind spots, not raw capability. A same-family reviewer (Opus
reviewing Opus, or Fable — still an Anthropic model) shares training priors and nods along at the
same mistakes. Default to a **different family** as the adversary:

1. **First choice: Codex / GPT (OpenAI)** via the `/codex-consult` skill. Different family, fresh
   eyes, argues in directions Claude wouldn't. This is also the PR-review step already baked into
   `docs/WORKFLOW.md`. (Requires the `codex` CLI on this machine.)
2. **Fallback when Codex is unavailable** (OpenAI usage limits, or it's disabled): use **Fable**
   for the adversarial pass. Same-family, so a weaker adversary — lean on its long-context
   strength (hold old + new code state at once) and don't expect it to break family blind spots.
   Better than no independent pass.
3. **Stay in the main Opus thread** when the "second opinion" is really about *this codebase's*
   specifics (below) — a cold cross-family model comes in blind to them. Feed it context in the
   prompt to narrow the gap, but codebase-consistency judgment stays here.

**Strongest loop:** Claude drafts (knows the repo) → cross-family attacks (`/codex-consult`, Fable
fallback) → Claude reconciles (tells real objections from context-gaps). Take its bug-catching
seriously; be skeptical when a cold model wants to **ratchet complexity** — this is a single-owner
WoW addon (see "right-size for a single maintainer" in AGENTS.md). Fresh models love adding rigor
and edge cases nobody asked for. Codex on this repo has already produced real catches *and* two
confident corrections that were themselves wrong — it is a reviewer, not an oracle.

### This codebase's specifics (where local judgment beats a cold reviewer)

Feed these into any external review, and don't let a blind reviewer override them:

- **The Retail-API adapter** (`Compat.lua` → `AltStable.API`): aliases are deliberately *not*
  injected into `_G`, and the struct-vs-tuple split is load-bearing. A reviewer who doesn't know
  `docs/forever-api-notes.md` will suggest both "just make it a global" and "these aliases are
  redundant" — both are wrong here.
- **Sync wire protocol** (`Core.lua`): the `PROTOCOL_VERSION` / `CHUNK*`/`DONE*`/`REQ*` command
  strings, chunking under the 255-byte cap, base64 + checksum, and **cross-version
  compatibility** (old clients must cleanly ignore, not misparse). A format change means a
  version bump.
- **SavedVariables shape** — `AltStableDB` / `AltStableConfig` are persisted and, since client
  1.60.1.70009, are read back again (#23 is fixed); don't break the shape on disk, because now
  there is real data out there in it. "It persisted" still needs a **full client exit**, not a
  `/reload`, and the file on disk only proves the write half.
- **Forever, not TBC.** Vanilla content on the Mainline codebase. Suggestions citing TBC/WotLK
  Classic API behaviour are usually stale; Lua 5.1 semantics still apply.
- **Test stubs model Forever.** `tests/wow_stubs.lua` returning a Classic-shaped tuple would make
  a broken port pass — stub fidelity is part of the review surface, not scaffolding.

These are the same areas that warrant Opus's own attention (see the model tiers in AGENTS.md) and
that are worth handing to Codex with the relevant code pasted in.

## Fable usage

Fable's advantage is context, not caution: it holds old and new code in view at once and runs long
agentic sequences across many interconnected files. Use it for:

- Adversarial plan critique **only as the fallback when Codex is unavailable** (above — a
  different family is the preferred adversary).
- Post-phase diff review.
- Large migrations/refactors touching many interconnected files at once — the port itself is the
  obvious candidate.

Don't use Fable for single-file/single-module work regardless of stakes — that's Opus's job. Fable
needs **explicit per-turn user approval for any implementation use**; critique/review stays
default-on.
