# microG Universal Installer

A single flashable ZIP that installs microG as privileged system apps on stock
Android, working across Magisk / KernelSU / APatch as a systemless module overlay.
No signature spoofing is bundled (see the spoofing guide). Design spec:
`docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md`.

## Long-Running Project

This project uses session-persistent tracking. At the start of every session:
1. Read `claude/progress.md` silently for a full catch-up -- do not ask the user to re-explain anything.
2. Do NOT automatically continue working -- wait for the user to indicate they want to proceed.
3. After each completed task, update `claude/progress.md` immediately (mark `[x]`, recount Status Summary, update date).
4. `claude/progress.md` is the primary task tracker. Use `claude/tasks.md` only for ad-hoc items outside the long-running plan.
