# Working on AltStable

Single maintainer, so this is deliberately light. The one non-obvious part is the Codex review
step, which is worth doing properly because it has already paid for itself twice.

## The loop

```
issue  ->  branch  ->  PR  ->  Codex review  ->  address  ->  merge
```

1. **Pick an issue.** Milestones map to the plan phases. Everything in
   `docs/forever-api-notes.md` is measured on the live client — treat it as fact and don't
   re-derive it.
2. **Branch off `main`**, named for the issue: `phase2/api-adapters`, `phase4/warband-containers`.
   Never commit directly to `main`.
3. **Before pushing**, per `AGENTS.md`:
   - `luac -p` clean on every changed Lua file (`C:\Program Files (x86)\Lua\5.1\luac`)
   - `pwsh tests/run.ps1` green
4. **Open a PR** with `Closes #N`.
5. **Run the Codex review** (below) and post its findings as a PR comment.
6. **Address or rebut** each finding in the thread, then merge.

## Codex review on a PR

Codex is a *different model family*, so the value is decorrelated blind spots rather than raw
capability — it argues in directions Claude won't. It is a local CLI, not a GitHub App, so the
review is generated locally and posted to the PR for the record.

```bash
# 1. capture the diff the PR actually contains
git fetch origin main
git diff origin/main...HEAD > /tmp/pr.diff

# 2. write a prompt naming the files to read and the questions to answer
#    (see "prompt shape" below)

# 3. run it read-only
timeout 420 codex exec \
  -c model_reasoning_effort=medium \
  --ephemeral --skip-git-repo-check -s read-only \
  -o /tmp/codex-verdict.md \
  < /tmp/codex-prompt.txt > /tmp/codex-progress.log 2>&1

# 4. post the verdict to the PR
gh pr comment <N> --body-file /tmp/codex-verdict.md
```

Gotchas that will bite you, all learned the hard way:

- **Feed the prompt via `< file` on stdin.** `codex exec "prompt"` in a non-TTY prints
  *"Reading additional input from stdin…"* and hangs forever.
- **Read the answer from `-o`, not stdout.** stdout is progress noise.
- **`--ephemeral`**, or a long run balloons a session log under `~/.codex/sessions/`.
- **Never say "review the code" and "do not run commands" in the same prompt.** Codex reads files
  *through* shell commands, so that contradiction makes it refuse and you burn a run. Say:
  *"You may run read-only shell commands (cat, grep, rg, ls) to read the files listed. You may not
  edit anything or run builds/tests."*

### Prompt shape

Codex answers a numbered list of specific questions well and a wall of prose badly. Give it:

- The **established facts** it must not re-litigate — interface 16001, Vanilla content on the
  Retail API, measured return shapes. Otherwise it wastes the run rediscovering them.
- The **files to read**, by path.
- **Numbered questions**, ordered so silent-wrong-behaviour comes before style.
- A closing note that this is a single-maintainer personal addon and
  `AGENTS.md` says *right-size for a single maintainer* — otherwise fresh models ratchet complexity
  and propose rigor nobody asked for.

### Reconciling its findings

Take the bug-catching seriously; be skeptical when it wants to add abstraction. It comes in cold
to this codebase, so the things it cannot know are: the sync wire protocol's constraints, the
`gearmod_` four-state contract, SavedVariables shape, and what is deliberately deferred. Feed those
in, and don't let a blind reviewer override them.

Track record so far, for calibration:

- Caught a real bug before it shipped — `C_Item.GetItemIcon` takes an ItemLocation, so the
  same-name alias would have been silently wrong. Later confirmed in-game.
- Found three more hardcoded level-70 caps beyond the obvious one.
- Spotted that the item-level colour ramp is TBC-scaled, so Vanilla epics would render as junk.
  Confirmed in-game: Thunderfury is ilvl 80.
- Talked us out of a false dichotomy — adapters go in `AltStable.API` with file-local aliases,
  not injected globals.
- Also produced two corrections that were themselves wrong, and one "simplification" that ignored
  a deferred feature. It is a reviewer, not an oracle.

## Fallback

If the `codex` CLI is unavailable, use Fable for the adversarial pass — same family, so a weaker
adversary, but better than no independent review. Lean on its long context (old and new state at
once) rather than expecting it to break shared blind spots.
