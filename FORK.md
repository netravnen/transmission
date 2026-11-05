# Fork branch model

This repository is a fork of
[transmission/transmission](https://github.com/transmission/transmission).
It carries fixes that upstream has not released yet, and builds Debian
packages from them for hosts that run the trixie-backports package.

| Branch | Content |
| --- | --- |
| `main` | Identical to upstream `main`. Never commit to it. |
| `patches/main` | Our patch set, stacked on the newest upstream release tag. |

`patches/main` is a linear series of commits on top of the newest stable
upstream release tag (`x.y.z`, no `-beta` or `-rc`), not on upstream
`main`. A release tag is what Debian packages, so the packages are exactly
Debian's release plus our patches. `git describe --tags --abbrev=0` on
`patches/main` names the tag the series is stacked on.

## The patch set

| Commit | Upstream reference |
| --- | --- |
| `fix(libtransmission): keep magnet webseeds in the synthetic .torrent` | Regressed in 55da783e8 (4.1.0). No upstream issue or pull request yet. |
| `fix(libtransmission): re-locate the info dict after a tracker edit` | [transmission/transmission#9151](https://github.com/transmission/transmission/issues/9151) |

The remaining commits are fork tooling: this file, `.github/workflows/`
files whose names are not upstream's, and `packaging/`. The package build
leaves commits that touch only those paths out of the package.

## Rules for a patch

1. Open a topic branch from `patches/main`, and open a pull request into
   `patches/main`. Merge it with "Rebase and merge", so the series stays
   linear.
2. Make one commit per fix, with the fix and its test together. A fix
   without a test is not accepted: the package build runs every test the
   series adds, by name.
3. Base the fix on the release tag, not on upstream `main`. If upstream
   `main` needs the fix too, open the upstream pull request from a
   separate branch.
4. Every commit on this fork uses this identity, as author and committer:

   ```
   netravnen <1938389+netravnen@users.noreply.github.com>
   ```

   Set it in your clone with:

   ```bash
   git config user.name netravnen
   git config user.email 1938389+netravnen@users.noreply.github.com
   ```

   The sync workflow rewrites commits with the same identity, and fails if
   a patch commit carries another one.
5. When upstream releases a fix from the series, the next sync drops the
   commit, because the rebase finds it already applied. Remove its row from
   the table above in the same change.

## Workflows

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `upstream-sync.yml` | every day, and on demand | Rebases `patches/main` onto the newest release tag when upstream tags one, tests it with `patch-ci.yml`, force-pushes it and starts the package build. Moves `main` to upstream `main`. |
| `patch-ci.yml` | push or pull request to `patches/**` | Builds with sanitizers, runs all of `ctest`, then runs each test that the series adds by name. |
| `deb-ntrv.yml` | push or pull request to `patches/main`, weekly, on demand | Builds Debian's trixie-backports package for the tag with the series as quilt patches, installs it over the official backport, runs the reproduction of #9151, and publishes a release for a push. |

If the rebase or the tests fail, the sync run fails and pushes nothing.
GitHub sends a failure notification for the scheduled run.

`deb-ntrv.yml` stops with an error when Debian has not yet published a
trixie-backports source package for the new tag. The weekly run builds it
once Debian publishes it. It also rebuilds when Debian publishes a new
revision for the same tag. It does not publish the same commit on the same
Debian base twice.

Upstream's own workflows (`actions.yml`, `codeql.yml`, `webapp.yml`) run
only on upstream's branch names, so a push to `patches/main` does not start
them.

## Setup

Do these once, as the repository owner:

1. Make `patches/main` the default branch. Scheduled workflows run only
   from the default branch, so the daily sync needs this.
2. Add a `SYNC_TOKEN` secret: a fine-grained personal access token for this
   repository with Contents, Workflows and Actions read and write access.
   `GITHUB_TOKEN` cannot push commits that change `.github/workflows/`,
   and a rebase onto a new tag carries upstream's workflow changes.
3. Optional: disable upstream's `CodeQL` and `Update copyright` schedules
   in the Actions settings, if you do not want them to run on this fork.

## Manual sync

Do this when the automatic rebase fails:

```bash
git fetch --tags https://github.com/transmission/transmission.git
git switch patches/main
old=$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' --exclude '*-*')
new=$(git tag -l | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
git rebase --onto "$new" "$old"
git push --force-with-lease origin patches/main
```

Rebase open topic branches onto the new `patches/main` after each sync.

## Installing the packages

Each release holds `transmission-common`, `transmission-daemon` and
`transmission-cli` for amd64. On a host that runs the official
trixie-backports package:

```bash
apt-get install ./transmission-common_*.deb ./transmission-daemon_*.deb ./transmission-cli_*.deb
apt-mark hold transmission-common transmission-daemon transmission-cli
```

Expected result: `dpkg-query -W 'transmission*'` shows a version that ends
in `+ntrvN`.

Hold the packages. The version is Debian's version with `+ntrvN` added, so
it sorts above the backport it is built from. A newer Debian revision or
upstream release sorts above it, and `apt upgrade` would then replace the
patched build with an unpatched one. Release the hold
(`apt-mark unhold ...`) only to install the next release from this fork.

`transmission-daemon --version` cannot tell the two apart: both report the
upstream tag's commit. Check the package version with `dpkg-query`.
