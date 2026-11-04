#!/bin/sh
# Run by .git/hooks/pre-commit. Install it with:
#   echo 'tools/pre-commit.sh || exit 1' >> .git/hooks/pre-commit

fail=0

tools/check_layers.sh || fail=1

# A rule test changes only together with the rule it stands for: a reversed rule
# has to say so, rather than pass as a fix.
staged=$(git diff --cached --name-only)
if echo "$staged" | grep -q '^test/rules/' && ! echo "$staged" | grep -q '^rules/'; then
	echo "pre-commit: test/rules changed but rules/ did not." >&2
	echo "  Changing a rule test changes a rule. Update its file in rules/ too." >&2
	fail=1
fi

exit $fail
