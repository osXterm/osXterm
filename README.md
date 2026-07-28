# osXterm

osXterm is a native macOS SSH terminal with the Ghostty VT engine and an SFTP sidebar.
The first release is `0.1.0` and requires macOS 26 or later.

## Install from the GitHub tap

The repository itself is used as a Homebrew tap. Because its name is not prefixed
with `homebrew-`, add it with the explicit repository URL:

```sh
brew tap osXterm/osXterm https://github.com/osXterm/osXterm.git
brew install --cask osxterm
```

The Cask downloads the matching `osXterm-0.1.0.zip` asset from the GitHub release.

## Build and package locally

```sh
swift build
Scripts/package-app.sh
Scripts/create-release-archive.sh 0.1.0
```

The package script creates `.build/app/osXterm.app`. The release script writes the
Homebrew release asset to `dist/osXterm-0.1.0.zip` and prints its SHA256 value.

## Licensing

osXterm source code is licensed under the MIT License. The app embeds the
Ghostty VT engine, which is also distributed under the MIT License. The
copyright and license notices for both osXterm and Ghostty are included in the
app bundle under `Contents/Resources` and in `THIRD_PARTY_NOTICES.md`.

## Settings migration

Current settings are stored under `~/.config/osXterm/`. On first launch after an
upgrade, the app reads the previous product's settings and encrypted password key,
then writes them to the new directory without storing plaintext passwords.
