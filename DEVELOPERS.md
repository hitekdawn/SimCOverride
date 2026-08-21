# Release management

Pushing a tag triggers a GitHub action that packages the addon, uploads it to
CurseForge and Wago, and creates a GitHub release with the zip attached. Nothing
is published on an ordinary push to `main`, so you can commit freely and release
when you're ready.

BigWigs packager does the work. It reads `.pkgmeta` for the layout and the
`X-Curse-Project-ID` and `X-Wago-ID` fields in the TOC for where to upload.

## Cutting a release

1.  Bump `## Version:` in `SimCOverride.toc`.
2.  Commit and push everything to `main`.
3.  Tag that commit with the same version, `v` in front, and push the tag.
4.  Watch the run in the repository's Actions tab.

        # 1. bump the TOC, then
        git add .
        git commit -m "Fix talent string parsing for hero talents"
        git push

        # 2. tag and push to trigger the release
        git tag v12.1.0-02
        git push --tags

The tag is what starts the release. Pushing the commit on its own does nothing.

Wait for the run to go green before you announce anything. CI checks both
project IDs and both tokens before it packages anything, so a missing one stops
the release rather than publishing to only one site.

## Versions

`## Version:` is the WoW patch the build targets, plus a build number:

    12.1.0-01, 12.1.0-02, 12.1.0-03, ...

Tags are the same string with a `v` in front, so `12.1.0-02` is tagged `v12.1.0-02`.

The two have to agree. CI compares them and fails the release if they don't, so
forgetting to bump the TOC costs you a re-tag rather than a bad upload. Bump the
TOC first, tag second.

When the game moves to a new patch, update `## Interface:` to the new build number
and restart the build count:

    ## Interface: 120200
    ## Version: 12.2.0-01

`## Interface:` can list several patches separated by commas if a build works on
more than one. The packager reads it to decide which game versions to list the
file under on CurseForge and Wago.

## Prereleases

Put `alpha` or `beta` in the version and the packager marks the upload as a
prerelease instead of a release. Everything else is the same:

    ## Version: 12.1.0-alpha-01   ->   tag v12.1.0-alpha-01
    ## Version: 12.1.0-beta-01    ->   tag v12.1.0-beta-01

Anything without those words is a full release.

## Release notes

The packager writes `CHANGELOG.md` from the commit messages between the previous
tag and this one, ships it inside the zip, and uses it for the release notes on
GitHub, CurseForge and Wago.

Your commit subjects are what users read, so write them for that audience. There's
no separate changelog file to maintain.

## When something goes wrong

If the version check failed, the tag and the TOC disagree, and the error names
both. Delete the tag, fix the TOC, and tag again:

    git tag -d v12.1.0-02
    git push --delete origin v12.1.0-02
    # fix ## Version:, commit, push, then re-tag

If a site didn't get the file, open the run's log and look for a "Skipping upload
to ..." line. The check above refuses to start a release when a token or project ID
is missing, so a skip past that point usually means the site rejected the token or
didn't recognise the ID.

If the upload already happened and the build is wrong, don't reuse the version.
Bump to the next build number and release again. CurseForge and Wago both keep the
bad file otherwise.

## Secrets

Set these in the repository's Settings, under Secrets and variables > Actions.
GitHub provides `GITHUB_TOKEN` automatically, so it needs nothing.

    CF_API_TOKEN      https://legacy.curseforge.com/account/api-tokens
    WAGO_API_TOKEN    https://addons.wago.io/account/apikeys

The workflow passes the CurseForge secret under two names. `packager@v2` reads
`CF_API_KEY` and ignores `CF_API_TOKEN`, which is the name its master branch uses.
Setting both means the upload keeps working whichever version the action resolves to.

## Testing the packaging locally

You can run the packager by hand to see what would end up in the zip, without
uploading anything:

    curl -s https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh > release.sh
    bash release.sh -d -l

`-d` skips every upload. `-l` skips `@localization@` keyword replacement, which
would otherwise want a CurseForge token. Output lands in `.release/`, which is
gitignored.

The script needs `bash` and `zip` on PATH. Without `zip` it still builds the
folder and stops short of the archive, which is enough to check what is and
isn't included.
