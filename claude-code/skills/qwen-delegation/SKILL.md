---
name: qwen-delegation
description: Brief, launch and check the local qwen-worker subagent (sessions started with claude-qwen). Use whenever you are about to hand a task to qwen-worker, when checking or following up on work it reported, or when it made a mistake the skill should learn from.
---

qwen-worker is a fast, competent mid-level engineer that follows written rules well. Left alone it makes decisions that were yours, tidies away things that look like junk (uncommitted work included), invents causal explanations, tests only the reported case (L8), and says `STATUS: DONE` when a metric was met through a loophole (L7).

The worker rules fix the first three. The spec fixes the last two: success is defined as commands you run yourself, agreed before the work starts, so no report can claim a success your run doesn't confirm. Put your effort into the spec, not into review.

`<skill dir>` is this skill's base directory, shown when it loads; write it out in full in commands and briefs.

Run one worker at a time. This machine serves one Qwen conversation at a time, and a second one evicts the first's cache. Never start or resume a qwen-worker while another is running, in the foreground or the background.

## 1. Choose the path

- **Two phases** is the default for a bug whose cause you don't know, a feature, and speed work. Qwen reads the code and proposes the spec as runnable tests, you review it, then it implements. Reviewing a spec costs far less than learning the code to write one.
- **One phase** only when you can write the acceptance lines from the task text alone: a named edit, a rename, a known failing test, repo housekeeping.

Deciding needs only the task text and a file listing. If you notice yourself reading source to write the brief, stop: that reading is phase 1's job.

## 2. Snapshot and baseline

```bash
<skill dir>/scripts/snapshot.sh save <workdir>
```

Note the test count from the brief's exact command; runners disagree (L12).

## 3. Brief

```
<Task in 1–3 sentences: what, where, why.>

Work only inside <workdir>. First read and follow
<skill dir>/worker-rules.md; this brief overrides it where they differ.

Acceptance (I will rerun exactly this):
- <command + passing result, e.g. "python3 -m unittest: all pass, more than N tests">
- <edge cases that must have tests, named: None items, empty input, ...>
- <metric + the command that measures it, cold, on fresh input>
Protected (do not modify): <files>
Decisions reserved for me: <the actual decision, e.g. "which discount applies first" | none>
Commit: <one commit, message format, any trailer lines your session requires> | <no commit>
Report: at most <N> lines.
```

For two phases, replace the Acceptance block with this and add no Commit line:

```
Phase 1 of 2: specify, don't implement. Change no code. Add acceptance tests in
<test file> that fail now for the right reason. Report: the plan, the files you
will change, the acceptance commands and their expected results after the fix,
the edge cases your tests cover, and the decisions you need from me. Then stop
and wait for approval.
```

Writing the brief:
- **Name the edge cases.** It covers exactly what is listed (L8).
- **Reserve precisely.** Name the decision, not a category like "business logic", and no more than you mean: "deleting anything" stopped it untracking `.pyc` files (L11).
- **Say what a metric means** ("cold, on the given corpus", L7), and for open-ended work what the report must cover ("customer AND revenue effects"). It neglects what you don't name.

## 4. Launch, and review the spec

Launch with the Agent tool, `subagent_type: qwen-worker`. If requirements change mid-run, SendMessage it; it reads the message at its next tool call. To wait in an interactive session, end your turn: its report wakes you. In a non-interactive one (`claude -p`), ending the turn ends the task before your check, so wait with one blocking command on something observable, such as its commit (`until git log -1 | grep -q <subject>; do sleep 10; done`).

For two phases, review what phase 1 returns before approving:
1. `snapshot.sh diff` shows only the new test file.
2. Run the tests, and check that they fail for the stated reason.
3. Ask what is missing. The gaps you're looking for are edge cases near the change, interactions with other methods that share the changed state (L13), falsy and empty inputs, cold measurement, and decisions it made that were yours.

Then SendMessage the same worker "approved" or "approved with: <changes>". It resumes with its context. Before it starts, run `snapshot.sh save` again and treat the acceptance tests as protected.

## 5. Check

By default the check is mechanical and skips the diff.

1. **Scope.** `snapshot.sh diff <workdir>`. Every change must be explained by the task and protected files unchanged. Anything else is a finding, lost uncommitted work and stray temp files included.
2. **Acceptance.** Rerun the agreed commands yourself; your run is the evidence, not its report. Both passing means done.

Go deeper only when a trigger fires:

| trigger | then also |
|---|---|
| `STATUS: BLOCKED`, or caveats in the report | read the whole report and check the claims it rests on |
| changes outside the expected files | read those parts of the diff |
| a reserved decision, stored data, security or a public API was touched | read the diff |
| a metric target | time it yourself on varied inputs (e.g. the text plus `' ' * i`), so a cache can't hide the real number (L7); correctness is in the acceptance tests, so build no harness for it |

**Spot-check** about one untriggered task in five: read the diff and probe inputs near the change.

On a failure, SendMessage only the symptom: the repro command, what you saw and what you expected. It finds the cause fast. Then check again. Keep push, publish, deletions it proposed and history rewrites for yourself.

## 6. Maintain

Log every finding from a check, a spec review or a spot-check in [`ledger.md`](ledger.md). Then fix the part of the skill it points at:

| finding | fix in |
|---|---|
| avoidable behaviour that no rule covers | a new rule in `worker-rules.md` |
| a rule it ignored | a more concrete wording that names the case that slipped |
| a gap in the brief or the spec | the step 3 template or the step 4 review questions |
| unfixed after two logged attempts | a trigger in step 5, or a script in `scripts/` |
| a one-off (environment, your own brief) | the ledger only |

- Every rule or check names the ledger entry behind it (`L7`).
- Phrase rules as the behaviour you want; it follows them literally.
- **Watch the size.** Merge rules about the same thing. Keep `worker-rules.md` to about ten rules and this file under about 1,200 words; add a line only by shortening another.
- After each check, run `scripts/tick.sh` (add the ids of entries that recurred; add `--deep` after a spot-check or deep check). It bumps the counters and marks an entry `held` after 5 clean checks. Once all of a rule's entries are `held`, shorten the rule.
- Tell the user in one line what you changed and why. Don't edit while a worker is running; it may still be reading `worker-rules.md`.
