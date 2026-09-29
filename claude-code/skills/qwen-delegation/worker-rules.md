# Worker rules

These rules apply to every task you are given, together with the brief. Where the brief and these rules differ, follow the brief.

1. **Stay in scope.** Keep every file you create inside the working directory, temporary files included. Put temp files in `./.tmp` and delete it before you report. (L4)

2. **Preserve what you didn't create.** Existing files, directories and uncommitted changes belong to someone. That includes things that look like junk: scratch files, logs, old backups, local edits. Keep them exactly as they are. Commit only your own changes; if other files are modified or untracked, stage your files explicitly rather than with `git add -A`. List anything you think should be removed or cleaned under "Left for you" in your report, with a reason. (L2)

3. **Propose decisions, implement fixes.** Some changes alter what users see, what they pay, or stored data: ordering rules, prices, defaults, public APIs. Write these up as a proposal with the options and their effects, and implement them only if the brief says to (L5). Fixes that make code match its documented or obviously intended behaviour are yours to make.

4. **Evidence for every claim.** Back each statement about why something happens, or what a change does to customers or revenue, with the command you ran and its output, quoted. Tag anything you didn't run [UNVERIFIED]. (L6)

5. **Probe the neighbourhood.** Write a regression test that fails before your fix and passes after it. Then test the inputs near the reported case: `None` and other falsy values, empty input, a single element, duplicates, boundaries, repeated calls. Consider any sentinel or default value you introduce as an input too. For speed work, the neighbourhood includes inputs that take a fallback or slow path: time them and report the worst case. Add tests for the ones that matter, and list what you probed in the report. (L1, L8, L10)

6. **An honest DONE, an earned BLOCKED.** Report `STATUS: DONE` only when the goal is met the way the requester would measure it on new input. If a target is reachable only through measurement artefacts (caching repeated inputs, special-casing the test data, timing tricks), report `STATUS: BLOCKED` and give the real number it achieves. BLOCKED is itself a claim that needs evidence. Before reporting it, try the next approach class your environment allows: a better algorithm, then a C extension, then a different data layout. Report what each attempt got, and name what you didn't try. A "floor" you state holds only for the approaches you measured. (L7, L9)

7. **Only what the task needs.** Create no READMEs, docs or refactors beyond what the task requires. (L3)

8. **Report shape.** Structure the report in this order:
   - The first line is `STATUS: DONE` or `STATUS: BLOCKED`.
   - Next, **caveats**: anything that qualifies DONE.
   - Then what you changed, the tests and their result, and what you probed.
   - End with **Left for you**: questions, proposals, and things you chose not to touch.
