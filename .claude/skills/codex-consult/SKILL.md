---
name: codex-consult
description: Consult the Codex CLI (OpenAI) non-interactively for an adversarial design review, code/plan critique, or independent second opinion. Use when the user asks to "rubber-duck with Codex", get Codex's take on a design/plan, or run Codex headlessly to double-check work.
version: 1.0.0
allowed-tools: [Bash, Write, Read]
---

# Consult Codex CLI (headless)

Run OpenAI's `codex` CLI non-interactively to get a second opinion (design review, plan
critique, adversarial check) from a *different model family* than Claude — the point is
decorrelated blind spots, not raw capability.

> Requires the `codex` CLI installed and OpenAI-authenticated on this machine. If `codex`
> isn't found, say so and fall back to Fable for the adversarial pass (see `CLAUDE.md`).

## The invocation

1. **Write the prompt to a file** (use the scratchpad dir, not a bash heredoc — more reliable):
   `…/scratchpad/codex-prompt.txt`
2. **Run**, feeding the prompt via stdin redirect and capturing the answer with `-o`:

```bash
timeout 300 codex exec \
  -c model_reasoning_effort=medium \
  --ephemeral \
  --skip-git-repo-check \
  -s read-only \
  -o "<scratchpad>/codex-verdict.md" \
  < "<scratchpad>/codex-prompt.txt" \
  > "<scratchpad>/codex-progress.log" 2>&1
```

3. **Read the answer** from the `-o` file (`codex-verdict.md`). `stdout` is only progress.

## Why each flag (these are the gotchas that will bite you)

- **Prompt via `< promptfile` (stdin), NOT as a bare argument.** In a piped/non-TTY
  environment, `codex exec "my prompt"` prints *"Reading additional input from stdin…"* and
  **hangs forever** waiting for EOF. Redirecting a file to stdin gives the EOF.
- **`--ephemeral`** — no session persistence. Without it, a long or looping run can balloon a
  session-log JSONL under `~/.codex/sessions/` to **hundreds of MB** and never return.
- **`-o <file>`** — the final agent message is written here. **Do not parse stdout for the
  answer** — stdout is progress noise only.
- **`-s read-only`** — advisory/design use: Codex can read but not edit the tree. Use
  `-s workspace-write` only when you actually want it to make changes.
- **`--skip-git-repo-check`** — safe to run regardless of git state.
- **`-c model_reasoning_effort=medium`** — the default. Bumping to `high` costs more and runs
  longer; **ask the owner before using `high`**, then pass it for that one run. Add
  `-c web_search=live` if it needs the web. Add `-m <model>` to pin a model (else default).
- **`timeout <sec>`** — always wrap it (300–420s is typical) so a stuck run can't hang forever.

## Prompt shape — pick the mode

Codex answers a numbered list of specific questions well; a wall of prose less so. Two modes,
depending on whether the evidence is in the prompt or in the repo:

- **Design-prose mode** (the design/plan is described *inline* in the prompt — nothing to inspect):
  lead with *"OPINION ONLY — do NOT read files, edit, or run commands. Answer from the description
  below."* This keeps it fast and stops Codex wandering the tree. (Still run with `-s read-only`.)
- **Code / repository review mode** (the request references a diff, file paths, or "review the
  code"): **do NOT forbid reading** — Codex must inspect the evidence. Lead with *"Review the code.
  Read these files: <paths>. Do NOT edit anything or run commands — read-only advice only."* The
  `-s read-only` sandbox already blocks edits; the prompt just scopes what to read.

Never tell Codex to both "review the code" and "do not read files" — that contradiction produces a
critique of nothing. Match the instruction to the mode.

For AltStable specifically, good things to hand Codex: the `Core.lua` sync/wire-protocol logic,
a serialization-format or protocol-version change, an adapter mapping in `Compat.lua` (especially
anything struct-vs-tuple), a scanner change, or a plan that touches SavedVariables shape — paste
the relevant code/paths and ask what breaks. Hand it `docs/forever-api-notes.md` alongside the
diff: those findings are measured on the live client, and a cold reviewer will otherwise argue
from Classic-era API behaviour that no longer holds.

The PR review loop in `docs/WORKFLOW.md` is this skill's main use here — that doc has the
diff-capture and posting steps that wrap the invocation below.

## Concurrency / safety

- The owner may run **their own Codex sessions concurrently**. Multiple sessions on one account
  can serialize/slow each other.
- **Never kill Codex processes by pattern/name** — you may terminate the owner's sessions. If you
  must kill a stuck run, kill **only the exact PID you started** (`taskkill //PID <pid> //F`), and
  prefer just letting the `timeout` wrapper end it.
