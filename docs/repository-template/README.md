# PackTune packages

This repository holds custom applications for [PackTune](https://github.com/dominguez-posh/PackTune): each app with all its versions, a manifest with the SHA256 of every file, and one index.

```
packtune.json                              index (name, apps, versions, manifest hash)
apps/<app-id>/<version>/                   package.intunewin | package.msix, installer.zip, recipe.json,
                                           signing.cer, documentation.zip, manifest.json
tools/Check-PackTuneRepository.ps1         the check that runs on every pull request
```

Rules

- Keep this repository private unless the content is meant to be public.
- Protect the default branch: require pull requests and at least one review (Code Owners), block force pushes. Whoever can push here can publish software to your devices.
- Give write access only to Intune administrators.
- Never edit a file of a published version: add a new version folder instead. PackTune asks for approval of every new version and of every changed manifest.
- Files over 90 MB are attached to a release named `<app-id>/<version>` (same file name) instead of being committed; the manifest still lists them.

Add apps with PackTune (Move to repository) or by hand following the layout, then run `./tools/Check-PackTuneRepository.ps1 -Path .`.

Full guide: docs/REPOSITORIES.md in the PackTune repository.
