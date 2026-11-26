# Contributing

This repo is where the Manalens Godot SDK is developed. Open issues and pull requests here.

## Test

You need Godot 4.5 or later and Node 20 or later.

```bash
GODOT=/path/to/godot node test_project/run-tests.mjs
```

This runs the shared fixture scenario against a capture server on 127.0.0.1, and the modes that need no network. CI (`.github/workflows/ci.yml`) runs the same file with a pinned Godot build on each pull request.

If you change a request body on purpose, write the fixtures again and review the diff:

```bash
UPDATE_FIXTURES=1 GODOT=/path/to/godot node test_project/run-tests.mjs
```

## Release

1. In a pull request, set the new version in `addons/manalens/plugin.cfg` (`version="X.Y.Z"`) and put a `## X.Y.Z (YYYY-MM-DD)` section at the top of `CHANGELOG.md` (rename `## Unreleased` if it is there). CI checks that the two are the same. Between releases, CI allows a `## Unreleased` section above the newest version; the release workflow does not.
2. Merge it to `main`.
3. Tag that commit and push the tag:

   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

The release workflow (`.github/workflows/release.yml`) checks the tag, runs the tests, builds the zip, `SHA256SUMS`, and the provenance attestation, and makes the GitHub release.

4. Update the Godot Asset Library listing by hand. It does not follow the repo. Open the asset, click **Edit**, and set the new version and the release commit. A moderator approves the edit.

## The delivery contract

The SDK sends app events to the Manalens collector (`POST /v0/events`). The contract (the request shape, the retry and batch defaults, and the shared fixture scenario) is `sdks/SPEC.md` in the private Manalens monorepo, next to the collector. The monorepo pins a commit of this repo in `sdks.lock.json`. Its tests check the fixtures and the source of the pinned commit against the collector schema, and run the SDK end to end against a local collector and Tinybird.

So a change that also needs a collector change takes two pull requests:

1. This repo first. Merge it to `main`.
2. Then the monorepo: bump the pin (`pnpm sdks:bump <engine>`) together with the collector change.

A change to the request body changes the fixtures. Write them again (see Test), review the diff, and commit them with the change.

## Commits

This repo is public, and its history shows each commit's author and committer.

- Use your GitHub noreply email (`<id>+<user>@users.noreply.github.com`) for both. Set it with `git config user.email` in this clone.
- Do not add AI attribution lines (`Co-Authored-By: Claude ...`, `Claude-Session: ...`, or "Generated with Claude Code") to commit messages or pull request descriptions.
- Merge after CI passes. Use a fast-forward push of the reviewed branch (`git push origin <branch>:main`), or a squash merge on GitHub. Both keep noreply emails in the history.
