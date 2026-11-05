# Fork branch model

This repository is a fork of
[transmission/transmission](https://github.com/transmission/transmission).
It carries fixes that upstream has not merged yet, and builds Debian
packages from them for hosts that run the trixie-backports package.

| Branch | Content |
| --- | --- |
| `main` | Identical to upstream `main`. Never commit to it. |
| `patches/main` | Our patch set, stacked on upstream `main`. |
| `backport/<tag>` | The code commits of the patch set, ported to a release tag (see [below](#when-a-patch-does-not-apply-to-the-release-tag)). |

No other branches are kept. Work in progress goes on a topic branch that
is deleted once it is in `patches/main`.

`patches/main` is a linear series of commits on top of upstream `main`.
`git merge-base patches/main upstream/main` names the upstream commit the
series is stacked on.

Debian packages release tags, not `main`. The package build therefore
replays the code commits of the series onto the release tag that Debian's
newest trixie-backports source package was made from (see
[Workflows](#workflows)).

## The patch set

| Commit | Upstream reference |
| --- | --- |
| `fix(libtransmission): keep magnet webseeds in the synthetic .torrent` | Regressed in 55da783e8 (4.1.0). No upstream issue or pull request yet. |
| `feat(libtransmission): put magnet webseed keeping behind a setting` | Fork only. `keep_magnet_webseeds`, default true. |
| `fix(libtransmission): re-locate the info dict after a tracker edit` | [transmission/transmission#9151](https://github.com/transmission/transmission/issues/9151) |
| `feat(libtransmission): put the info dict relocation behind a setting` | Fork only. `relocate_info_dict_after_tracker_edit`, default true. |
| `fix(libtransmission): accept only http, https and ftp webseeds` | BEP 19. No upstream pull request yet. |
| `fix(libtransmission): let ftp webseeds pass the partial-content check` | BEP 19. No upstream pull request yet. |
| `fix(libtransmission): fetch webseed files by their metainfo names` | BEP 19. No upstream pull request yet. |
| `fix(libtransmission): percent-encode reserved chars in webseed paths` | BEP 19. No upstream pull request yet. |
| `fix(libtransmission): restore trailing slash on multi-file webseeds` | BEP 19. No upstream pull request yet. |
| `fix(libtransmission): accept IPv6 external ip from trackers` | No upstream pull request yet. |
| `build(submodules): fetch dht and libutp from the Gitea copies` | Fork only. Not part of the package. |
| `build(dht): bump dht to 0.28 from the forge's dht fork` | [transmission/transmission#9097](https://github.com/transmission/transmission/issues/9097). Not part of the package. |
| `fix(dht): bump dht to the bencoding-reader message parser` | Not part of the package. |

Set either key to false in `settings.json` to get upstream's behaviour back
on one node.

The remaining commits are fork tooling: this file, `.github/workflows/`
files whose names are not upstream's, and `packaging/`. The package build
leaves commits that touch only those paths, `.gitmodules` or the
`third-party/` submodules out of the package: a submodule bump cannot be a
quilt patch. The two dht commits therefore reach CI builds from this
branch, but not the Debian packages.

The submodule commit makes CI fetch `dht` and `libutp` from the Gitea
copies. When upstream moves either submodule, update the Gitea copy before
the next sync, or CI cannot fetch the new commit.

## Rules for a patch

1. Open a topic branch from `patches/main`, and open a pull request into
   `patches/main`. Merge it with "Rebase and merge", so the series stays
   linear.
2. Make one commit per fix, with the fix and its test together. A fix
   without a test is not accepted: CI and the package build run every test
   the series adds, by name.
3. Base the fix on upstream `main`. The package build checks that it also
   applies to the release tag.
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
5. When upstream merges a fix from the series, the next sync drops the
   commit, because the rebase finds it already applied. Remove its row from
   the table above in the same change.

## When a patch does not apply to the release tag

The package build stops with "backport needed" and the subject of the
commit when `git am -3` cannot apply it to the release tag. Upstream `main`
has then moved too far from the release for that file. Do this:

1. Make a branch `backport/<tag>` from the tag, for example
   `backport/4.1.4`.
2. Put every code commit of the series on it, in the same order. Use the
   release variant, with the same test, for each commit that does not
   apply.
3. Push it, and start `deb-ntrv.yml` on `patches/main`.
   Expected result: the plan step says it uses `backport/<tag>`, and the
   package builds.

While `backport/<tag>` exists, the build uses it instead of the replay for
that tag. Keep it in step with the series when the series changes. Delete
it when Debian packages a newer release.

## Workflows

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `upstream-sync.yml` | every day, and on demand | Rebases `patches/main` onto upstream `main` when it moves, tests it with `patch-ci.yml`, force-pushes it and starts the package build. Moves `main` to upstream `main`. |
| `patch-ci.yml` | push or pull request to `patches/**` | Builds with sanitizers, runs all of `ctest`, then runs each test that the series adds by name. |
| `deb-ntrv.yml` | push or pull request to `patches/main`, weekly, on demand | Replays the code commits onto the release tag of Debian's newest trixie-backports source package, builds that package with them as quilt patches, installs it over the official backport, runs the reproduction of #9151, and publishes a release for every event except a pull request. |

If the rebase or the tests fail, the sync run fails and pushes nothing.
GitHub sends a failure notification for the scheduled run.

`deb-ntrv.yml` names a release by the Debian base and the tree of the
replayed commits. It builds again only when Debian publishes a new
revision or release, or when the code commits change. A sync that only
moves upstream `main` publishes nothing new. When upstream tags a release
that Debian has not packaged yet, the build stays on the older tag and
shows a warning.

Upstream's own workflows (`actions.yml`, `codeql.yml`, `webapp.yml`) do not
run on `patches/main`. A push to `main` by `mirror-main` with `SYNC_TOKEN`
starts upstream's `Sanity` workflow and CodeQL on this fork (see Setup,
step 4).

## Setup

Do these once, as the repository owner:

1. Make `patches/main` the default branch. Scheduled workflows run only
   from the default branch, so the daily sync needs this.
2. Add a `SYNC_TOKEN` secret: a fine-grained personal access token for this
   repository with Contents, Workflows and Actions read and write access.
   `GITHUB_TOKEN` cannot push commits that change `.github/workflows/`,
   and upstream `main` changes them. Without the token, the push of
   `patches/main` and `main` fails whenever upstream changes a workflow.
3. Add the `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` secrets:
   the two halves of a Cloudflare Access service token that the forge's
   Access application accepts with a "Service Auth" policy. `patch-ci.yml`
   sends them as headers to the forge, so that the runner can clone the
   `dht` and `libutp` submodules. Without them, patch CI fails at its
   first step. `packaging/ci/cf-service-token.sh` makes the token, adds
   the policy and sets both secrets, without printing the values:

   ```bash
   export CLOUDFLARE_API_TOKEN CF_ACCOUNT_ID CF_ACCESS_APP_ID
   packaging/ci/cf-service-token.sh create
   ```

   Expected result: it names the new token, and `gh secret list` shows
   both secrets. Run `packaging/ci/cf-service-token.sh rotate` to replace
   the client secret, and `status` to see when the token expires.
4. Optional: disable upstream's `Sanity`, `CodeQL` and `Update copyright`
   workflows in the Actions settings, if you do not want them to run on
   this fork.

## Manual sync

Do this when the automatic rebase fails:

```bash
git fetch https://github.com/transmission/transmission.git main
git switch patches/main
git rebase --onto FETCH_HEAD "$(git merge-base HEAD FETCH_HEAD)"
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
