#!/usr/bin/env bash
# Bring every library (git submodule, at any depth) up to its remote and record
# the new pointers, deepest first, so a parent never points at a commit its own
# submodule has not got.
#
#   tools/sync_libs.sh            fetch, fast-forward, commit pointer bumps
#   tools/sync_libs.sh --check    only report what is behind or ahead
#   tools/sync_libs.sh --push     after syncing, push every repo that is ahead,
#                                 deepest first
#
# It never stashes, resets or discards anything. A library with uncommitted
# file edits, or one whose history has diverged from its remote, is reported
# and left alone; so is everything above it, since its pointer cannot move.
set -uo pipefail

mode=sync
case "${1:-}" in
	--check) mode=check ;;
	--push) mode=push ;;
	"") ;;
	*) echo "usage: $0 [--check|--push]" >&2; exit 2 ;;
esac

root=$(git rev-parse --show-toplevel) || exit 1
failed=0

say() { printf '%s\n' "$*"; }

default_branch() {
	local head
	head=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
	if [[ -n $head ]]; then echo "${head#origin/}"; return; fi
	for b in main master; do
		if git rev-parse -q --verify "origin/$b" >/dev/null; then echo "$b"; return; fi
	done
}

submodule_paths() {
	[[ -f .gitmodules ]] || return 0
	git config -f .gitmodules --get-regexp '\.path$' | awk '{ print $2 }'
}

# Fast-forward one submodule checkout onto its remote branch. Returns 1 when it
# cannot be done safely.
advance() {
	local name=$1 branch
	branch=$(default_branch)
	if [[ -z $branch ]]; then say "  ! $name: no origin/main or origin/master"; return 1; fi

	if [[ -n $(git status --porcelain -uno --ignore-submodules=all) ]]; then
		say "  ! $name: has uncommitted edits, left as is:"
		git status --short -uno --ignore-submodules=all | sed 's/^/      /'
		return 1
	fi

	local current before
	before=$(git rev-parse --short HEAD)
	current=$(git symbolic-ref -q --short HEAD)
	if [[ $current != "$branch" ]]; then
		# A pinned checkout sits on a detached HEAD. Put it on the branch, as
		# long as nothing made on the detached HEAD would be dropped.
		if ! git merge-base --is-ancestor HEAD "origin/$branch"; then
			say "  ! $name: HEAD has commits not on origin/$branch, left as is"
			return 1
		fi
		if git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
			git checkout -q "$branch" || return 1
		else
			git checkout -q -b "$branch" "origin/$branch" || return 1
		fi
	fi

	if ! git merge -q --ff-only "origin/$branch" 2>/dev/null; then
		say "  ! $name: $branch has diverged from origin/$branch, left as is"
		return 1
	fi
	local after
	after=$(git rev-parse --short HEAD)
	[[ $before != "$after" ]] && say "  $name: $before -> $after"
	return 0
}

# Sync one repo and everything below it. $1 is its path from the top, "" for
# the top itself. Returns 1 when something below could not be brought up.
sync_repo() {
	local path=$1 name=${1:-$(basename "$root")} ok=0
	(
		cd "$root/${path:-.}" || exit 1
		git fetch -q origin 2>/dev/null || say "  ! $name: fetch failed"
		if [[ -n $path ]]; then advance "$name" || exit 1; fi

		# New pins may have brought new submodules; check those out first.
		git submodule update -q --init 2>/dev/null

		local changed=() sub
		while read -r sub; do
			[[ -z $sub ]] && continue
			sync_repo "${path:+$path/}$sub" || ok=1
			if ! git diff --quiet --ignore-submodules=dirty -- "$sub"; then changed+=("$sub"); fi
		done < <(submodule_paths)

		if (( ${#changed[@]} )); then
			git add -- "${changed[@]}"
			git commit -q -m "Update libs" -- "${changed[@]}" \
				&& say "  $name: committed $(git rev-parse --short HEAD) Update libs (${changed[*]})"
		fi
		exit $ok
	)
}

check_repo() {
	local path=$1 name=${1:-$(basename "$root")}
	(
		cd "$root/${path:-.}" || exit 0
		git fetch -q origin 2>/dev/null
		local branch behind ahead
		branch=$(default_branch)
		if [[ -n $branch ]]; then
			behind=$(git rev-list --count "HEAD..origin/$branch")
			ahead=$(git rev-list --count "origin/$branch..HEAD")
			if (( behind || ahead )); then say "  $name: behind $behind, ahead $ahead"; fi
		fi
		if [[ -n $(git status --porcelain -uno --ignore-submodules=all) ]]; then
			say "  $name: has uncommitted edits"
		fi
		local sub
		while read -r sub; do
			[[ -n $sub ]] && check_repo "${path:+$path/}$sub"
		done < <(submodule_paths)
	)
}

push_repo() {
	local path=$1 name=${1:-$(basename "$root")}
	(
		cd "$root/${path:-.}" || exit 1
		local sub ok=0
		while read -r sub; do
			[[ -n $sub ]] && { push_repo "${path:+$path/}$sub" || ok=1; }
		done < <(submodule_paths)
		(( ok )) && exit 1
		local branch
		branch=$(default_branch)
		[[ -z $branch ]] && exit 0
		if (( $(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0) )); then
			if git push -q origin "HEAD:$branch"; then say "  $name: pushed"; else say "  ! $name: push failed"; exit 1; fi
		fi
		exit 0
	)
}

case $mode in
	check)
		say "Libraries not in step with their remote:"
		check_repo ""
		;;
	sync)
		say "Syncing libraries under $root"
		sync_repo "" || failed=1
		if (( failed )); then say "Some libraries were left as they were; see the ! lines above."; else say "All libraries are on their latest commit."; fi
		;;
	push)
		say "Pushing, deepest first"
		push_repo "" || failed=1
		;;
esac
exit $failed
