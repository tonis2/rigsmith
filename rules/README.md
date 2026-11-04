# Rules

What Rigsmith promises, and why. Each rule has:

- **Rule:** the behaviour, in plain words.
- **Why:** the real case behind it.
- **Tests:** where it is checked.
- **Tried and rejected:** what was tried and why it was dropped.

Rule tests live in `test/rules/`, as tables of real cases. The pre-commit hook
refuses a change there unless a file here changes too, so a reversed rule says
so. Rules can change; they just can't change by accident.

Before changing a rule, read its "Tried and rejected" lines. If a fix needs a
rule test changed, that is a rule change: stop and ask the owner.

- [Clips](clips.md)
- [Editing](editing.md)
- [Weights](weights.md)
- [Files](files.md)
- [Shortcuts](shortcuts.md)
- [Posing](posing.md)
- [Rigging](rigging.md)
