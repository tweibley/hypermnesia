# Homebrew cask

`brew install --cask` downloads a **prebuilt** app — it never compiles from source. So shipping a
cask means three things: (1) a notarized `Hypermnesia.app` zipped and attached to a GitHub Release,
(2) a cask file pointing at that zip with its `sha256`, and (3) a **tap** (a repo named
`homebrew-<something>`) that hosts the cask.

[`hypermnesia.rb`](hypermnesia.rb) here is the source-of-truth cask. The published copy lives in the
tap repo. End users then run:

```bash
brew install --cask tweibley/tap/hypermnesia
```

## One-time: create the tap

A tap is just a GitHub repo whose name starts with `homebrew-`. `brew tap tweibley/tap` resolves to
`github.com/tweibley/homebrew-tap`.

```bash
gh repo create tweibley/homebrew-tap --public \
  --description "Homebrew tap for Hypermnesia"
git clone https://github.com/tweibley/homebrew-tap && cd homebrew-tap
mkdir -p Casks
cp /path/to/hypermnesia/packaging/homebrew/hypermnesia.rb Casks/hypermnesia.rb
git add Casks/hypermnesia.rb && git commit -m "Add hypermnesia cask" && git push
```

## Each release

You need a **Developer ID Application** certificate + notarytool credentials set up once — see
[`../../docs/PACKAGING.md`](../../docs/PACKAGING.md).

**Automated (recommended).** [`.github/workflows/release.yml`](../../.github/workflows/release.yml)
does the whole thing on a tag push — build (universal), sign, notarize, staple, create the release,
and commit the new `version` + `sha256` to the tap. After adding the secrets that workflow lists:

```bash
# bump VERSION, commit, then:
git tag v0.1.0 && git push origin v0.1.0
```

**Manual.** Same steps by hand:

```bash
NOTARY_PROFILE=hypermnesia-notary bash Scripts/release.sh   # prints the sha256
gh release create v0.1.0 dist/Hypermnesia-0.1.0.zip --title v0.1.0 --notes-file CHANGELOG.md
# edit Casks/hypermnesia.rb in the tap: set version + the printed sha256, commit, push
```

Verify before announcing:

```bash
brew install --cask tweibley/tap/hypermnesia   # add --force to reinstall
brew audit --cask --online tweibley/tap/hypermnesia
```

## Later: the official `homebrew-cask`

Once the project clears Homebrew's notability bar (roughly 75+ stars, 30+ forks, or 30+ watchers on
the repo) you can submit `hypermnesia.rb` to [homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask)
so `brew install --cask hypermnesia` works with no tap. Requirements there are stricter: a stable
versioned release and a signed **and notarized** app. Until then, the tap above is the way.
