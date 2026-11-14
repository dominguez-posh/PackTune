# Plan: custom package repositories on GitHub

Status: built on branch feature/repositories (issue #21); the user approved all recommendations of section 14. Differences from the plan: PAT first (device flow and GitHub App later), tokens in DPAPI only (Keevault later), large files keep the store's manifest byte for byte and are found as release assets of the same file name (the index lists them under `assets`) so the Intune anchor does not change, Moved versions still need approval before a new deployment, the interface lives as a section of the Settings page. See docs/REPOSITORIES.md. Security-relevant (trust in third-party content that becomes an app for all devices, credentials of the user).
Branch: docs/plan-repositories. Issue: to be opened when work starts. Builds on `docs/plans/custom-applications.md` (package store, manifest, MSI/MSIX rules, certificates).

## 0. Summary and recommendations

PackTune can connect any number of **repositories on GitHub** as sources of custom applications, next to the SharePoint package store: public repositories without a sign-in, private ones after a GitHub sign-in in the tool. A repository holds apps with all their versions in the same layout and manifest format as the store. Apps from a repository appear in the Apps list as source **Repository: <name>** and deploy as Win32 apps exactly like custom applications. A **Move to repository** action copies an app with all versions from the SharePoint store into a connected repository, verifies it, and only after a confirmation removes it from SharePoint.

The decisions this plan recommends (details and alternatives in section 14):

| # | Recommendation |
|---|---|
| 1 | Layout: one `packtune.json` index at the repository root plus one folder per app and version (the store layout); the manifest format is unchanged. |
| 2 | Large installers (over 100 MB): **GitHub Releases assets** (2 GB each), not Git LFS. The index points to the asset, the manifest holds its SHA256. |
| 3 | Auth: **OAuth device flow** with a PackTune OAuth app (no client secret, no redirect); the token lives per user, DPAPI-encrypted. Fine-grained PAT as the advanced alternative. Keevault as storage later. |
| 4 | Scopes: reading needs `Contents: read` (public repositories: nothing). Move needs `Contents: write` on that one repository. A separate, explicit step asks for the write grant. |
| 5 | Trust: repositories are **pinned by owner/name** (and the id), a new version of an app never reaches devices without an explicit approval that shows the commit, its author and the file hashes; the manifest hash is written into the Intune notes as today. Signed commits/tags are shown and can be made mandatory per repository. |
| 6 | Move: copy, verify against the manifest, then (after a confirmation) remove from SharePoint; history is kept as Git history and as the SharePoint recycle bin. |
| 7 | Tests run against a fake GitHub API in memory; one optional live run against a throwaway repository of the user. |

## 1. Goals and non-goals

Goals
- Several repositories at once; public and private; each with its own pinned identity.
- A repository can be maintained by people (pull requests, review) and by tools, with the history of Git as the audit trail.
- A guide with a template repository so that anyone sets up their own in minutes.
- The same safety guarantees as the SharePoint store: nothing becomes an Intune app without the hashes matching the manifest, and Intune keeps the trust anchor.

Non-goals (first version)
- Writing to a repository from PackTune other than **Move** (and later **Save new version**): no editing of repository content in the tool.
- Hosts other than GitHub (GitLab, Azure DevOps): the layout and the verification do not depend on GitHub, only the transport does (section 5), so a second host is a later, separate piece of work.
- Package signing as a replacement for the store trust model: the MSIX certificates stay per version as in the custom applications plan.

## 2. Repository layout

One index file and the store layout underneath:

```
packtune.json                         index: format version, name, description, apps[]
apps/<app-id>/<version>/
    package.msix | package.intunewin  (or a reference to a release asset, see 3)
    installer.zip                     original installer files (optional in a repository: see 3)
    recipe.json                       how it was built (kind msi|msix, entry point, arguments, product code, identity)
    signing.cer                       public certificate of that version (msix)
    documentation.zip                 optional
    manifest.json                     SHA256 of every file, written last (same format as the store)
README.md                             human text, written by the guide/template
```

`packtune.json` (small, readable, diff-friendly):

```json
{
  "format": 1,
  "name": "Contoso packages",
  "apps": [
    { "id": "contoso-inventory-agent-1a2b3c4d", "name": "Contoso Inventory Agent", "publisher": "Contoso Ltd", "kind": "msi",
      "versions": [ { "version": "2.4.0", "path": "apps/contoso-inventory-agent-1a2b3c4d/2.4.0", "manifest": "<sha256 of manifest.json>", "released": "2026-11-02" } ] }
  ]
}
```

Rules
- The index is a convenience for listing. **Nothing in it is trusted**: the manifest of each version is fetched, hashed, and compared to the hash in the index and in the Intune notes; every file is hashed against the manifest. A repository whose index disagrees with its manifests is shown as damaged and cannot be deployed from.
- App ids follow the existing rule (name plus hash suffix), version folders are plain version strings. Path segments are validated like in the store (no `..`, no separators), zip entries are checked against zip slip.
- A repository can hold its own apps only; PackTune never executes anything from a repository (no scripts are run on the admin PC; device scripts are generated by PackTune from the recipe, never taken from the repository). A recipe is data.
- Template repository: `packtune-repo-template` (published under the project) with the index, an empty `apps/`, a README with the guide, a `.gitattributes`, a workflow that validates the index and manifests on every pull request (the same verification as the tool, as a GitHub Action that only reads).

## 3. Large files

GitHub rejects files over 100 MB in a normal push; a repository should stay under about 1 GB in total. Options:

| Option | For | Against |
|---|---|---|
| **Releases assets** (2 GB per file) | Large installers; downloads need no extra tooling; the asset URL is stable; assets can be attached to a tag per app version, which also gives a place for signed tags | The asset is not in the Git history; deleting a release deletes the file; a private repository needs the token for the download |
| Git LFS (2 GB per file on free, quota for storage and bandwidth) | The file is part of the repository history | Needs the LFS protocol (batch API) in the tool, quota costs, clones get pointers |
| Keep large files out | Simple | Defeats the purpose |

Recommendation: **Releases assets**. A version folder holds `manifest.json` and small files in Git; a file over 90 MB is stored as an asset of a release named `<app-id>/<version>` and `manifest.json` lists it with `"asset": "<name>"`, size and SHA256. Verification is identical (hash against the manifest); the transport differs. Above 2 GB a version is not possible and the tool says so before it starts.

## 4. Authentication

Public repository: unauthenticated requests (60 per hour per IP; see rate limits, section 12), no sign-in needed. Private repository: a GitHub identity.

| Way | Pros | Cons |
|---|---|---|
| **OAuth device flow** with a PackTune OAuth app (public client id, no secret) | The user signs in at github.com in the browser with their own account and 2FA, grants exactly the scopes asked for, can revoke it in GitHub settings; no secret to ship | One OAuth app has to be registered and maintained by the project; classic OAuth scopes are coarse (`repo` is all private repositories of the user) |
| **GitHub App** user-to-server token | Fine-grained permissions chosen per installation (single repository, `Contents`) | Installation step per account/organization, more moving parts |
| **Fine-grained PAT** pasted by the user | Per repository, `Contents` read or write, expires | The user creates and pastes a secret; handling and rotation are manual |

Recommendation: **device flow with a GitHub App** (user access token) as the standard: it gets per-repository, `Contents`-only permissions, which a classic OAuth app cannot give. If that is too heavy for phase 1, start with the fine-grained PAT (paste, validate, store) and add the device flow in phase 2. Either way PackTune requests nothing else than `Contents` (read, and write only when the user starts Move) and `Metadata` (implicit).

Token storage
- Per Windows user, encrypted with DPAPI (`ConvertFrom-SecureString`, same user and machine), in the PackTune work folder; never in the settings file, never in logs, never in Intune notes. A plain `Authorization` header is built at call time.
- Optional: stored in Keevault through the existing integration instead (the user decides; Keevault is the user's password manager).
- Sign-out per repository removes the token; the tool offers to revoke it at GitHub (link to the settings page).
- The token is passed to background jobs the same way as the Graph token today (in memory, via the job arguments), never written by the job.

## 5. Transport and API

Only HTTPS to `api.github.com` (and `github.com`/`objects.githubusercontent.com` for release assets and raw content, followed from API redirects; hosts allow-listed, other redirects refused).

| Need | Call |
|---|---|
| list tree, find the index | `GET /repos/{owner}/{repo}/contents/packtune.json` (or raw via the git blobs API for files over 1 MB) |
| read a file | `GET /repos/{owner}/{repo}/git/blobs/{sha}` (up to 100 MB) or contents API; the blob SHA is checked as well |
| a release asset | `GET /repos/{owner}/{repo}/releases/tags/{tag}`, then the asset with `Accept: application/octet-stream` |
| the commit and its author of a path | `GET /repos/{owner}/{repo}/commits?path=...&per_page=1`, with `verification` (signature state) |
| write (Move, later Save new version) | git data API (blobs, trees, commit, ref update) in one commit per version, or contents API for single small files; release assets via the uploads host |

Everything goes through one function (like `Invoke-PackTuneStoreGraph`) so that tests replace it with a fake. Retries with `Retry-After`/`X-RateLimit-Reset`, never retry a body upload without the session logic.

## 6. How repositories appear in PackTune

- Settings or a dialog on the Apps page: **Repositories**, with Add (owner/name or URL, public or sign in), a list with status, last refresh, and Remove. The pinned identity is the **owner/name and the numeric repository id**; a repository that is renamed or transferred keeps working only after the user confirms the new identity.
- Apps list: a new source **Repository: <name>** per connected repository, a filter entry per source (the existing source filter gets the repository names), cards show the version, the repository and a small lock for private ones. The app is deployable like any other card.
- Deployment: a repository app behaves like a custom application. MSI: the existing MSI scripts and product-code detection. MSIX (captured): the Win32 wrapper with the per-version certificate inside (certificate from the repository version, verified against the manifest, never generated by the tool for a repository version; a new version captured by PackTune is a different flow, section 8). Intune notes carry the custom marker with `repo=<owner/name>;commit=<sha>;manifest=<sha256>`; updates use the supersedence logic as today.
- An app that exists in two sources is not merged: sources stay separate (a repository app is never replaced silently by a catalog app).

## 7. Integrity and trust

The repository content ends up as software on every device, so the model is **fail closed**:

1. **Pin.** A repository is identified by owner/name and repository id. Forks, renames and transfers are detected and need a confirmation.
2. **Verify.** For every file: SHA256 against the manifest; the manifest against the hash in the index and, once deployed, against the hash in the Intune notes (the anchor). Sizes are checked before downloading; limits per file and per version; nothing is unpacked outside the work folder (zip slip checks as in the store).
3. **Approve new versions.** A new version, or any change of an existing manifest hash, is **not** deployable until the user approves it in a dialog that shows: app, version, repository, commit (sha, author, date, message), signature state of the commit/tag ("verified by GitHub" or not), file list with sizes and hashes, and what changed against the last approved version (new files, changed files). An unapproved version is visible but marked "needs approval". Approvals are stored locally and in the Intune notes of the deployed app, so another administrator sees what was approved.
4. **Signed history (optional per repository).** The repository can require verified commits (GitHub's verification) or signed tags for versions; unverified ones are then refused, not just shown.
5. **Writers.** Everyone who can push to the repository can publish an installer. The guide says: protect the default branch (pull requests, required reviews, no force pushes), keep the repository private unless the content is meant to be public, and give write access only to Intune administrators. The tool shows the repository's visibility and, when readable, a warning for repositories whose default branch is not protected.
6. **No execution.** Nothing from a repository runs on the admin PC; recipes are parsed as data with strict schema checks; strings from the repository are escaped in the interface and in the generated scripts exactly like other external input (app names in toasts and scripts already follow that rule).
7. **Public repositories** are read only and unauthenticated; a public repository of someone else is a third-party software source and is labeled as such in the list and in the approval dialog.

## 8. Move to repository

Action in the custom application details: **Move to repository ...** (needs a connected repository with write access).

Semantics
1. Choose the target repository. If write access is missing, ask for the write grant (device flow with `Contents: write`, or a PAT with write) in a clearly labeled step.
2. Plan: list all versions of the app in the SharePoint store (the store manifest lists them), their size, which need release assets.
3. **Copy** every version: download from SharePoint (verified against its manifest, as today), upload to the repository in one commit per version (message `Add <app> <version>`, author is the signed-in GitHub user), big files as release assets; the index is updated in the same commit series.
4. **Verify**: read everything back from the repository and compare hashes against the manifests. Any mismatch stops here and nothing is removed.
5. **Switch**: the Intune apps keep their manifest anchor (hashes did not change); their notes get `repo=...` next to the store information, so exports and updates read from the repository from then on.
6. **Remove from SharePoint** only after an explicit confirmation that lists what will be removed. SharePoint keeps it in its recycle bin (93 days); the Git history keeps the content. A failed or cancelled move leaves both copies; running Move again continues (idempotent: existing identical versions are skipped).
7. Not offered for apps that exist partly (a version missing in the store) until the user decides how to proceed.

New version of a repository app (later phase): the existing capture/build flow produces the version, the repository receives it as a pull request or a direct commit (user choice, default: branch plus pull request), and the version needs approval (section 7) before it reaches devices, even when the user made it.

## 9. Rate limits, size, failure handling

- Unauthenticated: 60 requests per hour per IP; authenticated: 5,000 per hour per user. The tool caches the index and manifests by ETag (`If-None-Match`, 304 does not count against the limit for authenticated requests), refreshes at start and on request, and shows the remaining budget when it gets low. Without a sign-in a public repository with many apps may need a token; the tool says so instead of failing silently.
- Secondary limits and 403/429: back off with `Retry-After`; a clear short cause (the existing cause mapping) and Details.
- Offline or GitHub down: the list shows the last known index as stale (like the Graph-down banner), deployment from a stale repository is refused, nothing is half done. Downloads resume at file level; partial files are removed.
- Limits: file 2 GB (release asset), manifest and index size capped; a repository with an index above the cap is refused with a message.

## 10. Checks without real GitHub

- A fake GitHub API in memory (like the fake SharePoint): repositories, contents, blobs, commits with verification flags, releases and assets, rate limit headers, ETags, auth (public/private/forbidden).
- Checks: index parsing and damaged indexes; manifest and file hash mismatches (each refuses); path traversal and zip slip; pinning (rename, transfer, fork); approval required for a new version and for a changed manifest; unsigned commit refused when required; rate-limit handling and ETag caching; token handling (never in logs, notes, settings; DPAPI round trip); Move: copy, verify mismatch stops, idempotent re-run, removal only after confirmation, large file path via release asset; deployment of a repository MSI and MSIX app through the existing fakes (Intune notes carry repo and commit).
- Smoke: repositories dialog (add public, add private with sign-in stub, remove), the source filter, the approval dialog, the Move dialog with its confirmations.
- One optional live run (a script, never part of the checks) against a throwaway private repository of the user.

## 11. Guide for users (to be shipped in the README and the template repository)

1. Create a repository from the template (private unless the content is public).
2. Protect the default branch: require pull requests and reviews, block force pushes; limit write access to administrators.
3. In PackTune: Apps > Repositories > Add: owner/name; for a private repository sign in to GitHub in the browser (device code) and grant read access to that repository.
4. Put apps there: either **Move to repository** from the store, or (later) **Save new version to repository** from the tool, or by hand following the layout and `Check-PackTuneRepository` (a command that validates a local clone: index, manifests, hashes).
5. Approve new versions in the tool before they are deployed.
6. How to rotate or revoke the token, how to rename or transfer the repository (re-confirm in the tool).

## 12. Phases and effort (rough, one developer)

| Phase | Content | Effort |
|---|---|---|
| 0 | Decisions of section 14; register the GitHub App/OAuth app; create the template repository | 1 day |
| 1 | Read only: connect public repositories, index/manifest parsing and verification, fake GitHub API, checks, Apps list source and filter | 4-5 days |
| 2 | Private repositories: device flow or PAT, DPAPI token storage, scopes UI, rate limit and ETag cache, stale/offline handling | 3 days |
| 3 | Deploy from a repository (MSI, MSIX), approval dialog, pinning, signed commits option, Intune notes | 4 days |
| 4 | Move to repository (copy, verify, switch, confirmed removal), release assets for large files, idempotence | 4 days |
| 5 | Guide, template repository with the validation workflow, README, smoke, live run, docs screenshots | 2 days |
| Later | Save new version to repository (pull request flow), second host (GitLab/Azure DevOps), Keevault token storage | open |

Total about 18-20 days for phases 1-5; the work splits cleanly after phase 1 so that review and release can follow phase by phase.

## 13. Risks

- A compromised repository account publishes a malicious installer: mitigated by pinning, approval of every new version with commit author and signature state, branch protection guidance, Intune anchor. The approval is the key control and must not be skippable by a setting; a repository may only require more, never less.
- Token theft from the user profile: DPAPI protects against other users and offline reads, not against code running as the user (same as every token PackTune holds). Minimal scope and per-repository tokens limit the damage; the tool never asks for write unless Move is started.
- Rate limits make public repositories flaky without a token: caching and a clear message.
- GitHub policy or API changes (device flow, fine-grained permissions): isolated in one transport module with a fake for tests.
- Large repositories become slow or hit size limits: release assets for big files, index paging if needed.

## 14. Open questions, each with a recommendation

1. **Device flow with a GitHub App, or PAT first?** Recommendation: PAT in phase 2 (fast, no project-side registration), GitHub App device flow in a follow-up if users ask; the storage and scopes model is the same.
2. **LFS or release assets for big files?** Recommendation: release assets (section 3).
3. **Is installer.zip (original installer files) stored in a repository?** Recommendation: yes, optional per version, because export/edit needs it; for repositories with size pressure it can be a release asset too.
4. **May a repository require signed commits only for new versions, or always?** Recommendation: a per-repository switch, default off, shown prominently; approval of new versions is always on.
5. **Who owns the OAuth/GitHub App and the template repository?** Recommendation: the PackTune project owner; the client id is public, no secrets.
6. **Does Move delete from SharePoint at all?** Recommendation: yes but only after a confirmation and after verification; default answer "keep".
7. **Several repositories with the same app id?** Recommendation: allowed, shown as separate sources, never merged; deploying from one does not update from another.
8. **Private repositories of organizations (SSO enforced)?** Recommendation: document that the token must be authorized for the organization's SSO; the tool shows the GitHub error text as Details.
9. **Mixed trust: a public third-party repository.** Recommendation: allowed, read-only, with the approval dialog and a label "third-party source"; no Move target.
10. **Where do approvals live?** Recommendation: locally in the work folder and as a short record in the Intune notes of the deployed app (who approved which commit), so another administrator can see it.
