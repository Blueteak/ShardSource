# Publishing to CurseForge

This repository uses CurseForge's built-in packager. No GitHub Actions upload workflow is needed.

CurseForge project: [Shard Source, 1702078](https://authors.curseforge.com/#/projects/1702078/source). The project is connected to this GitHub repository with packaging set to tagged commits.

## One-time project setup

1. In the CurseForge project's source settings, select the Git repository `https://github.com/Blueteak/ShardSource.git` and enable packaging for tags only. A source-code link on its own does not configure packaging.
2. Follow [CurseForge's webhook instructions](https://support.curseforge.com/support/solutions/articles/9000197281-automatic-packaging) to create an API token, then [add a GitHub webhook](https://github.com/Blueteak/ShardSource/settings/hooks/new) with payload URL `https://www.curseforge.com/api/projects/1702078/package?token=YOUR_TOKEN`. Replace `YOUR_TOKEN` with the token and keep the other defaults: push events, Active checked, and SSL verification enabled. If a working webhook already exists, keep it instead of adding another.
3. Keep the API token in the webhook configuration. Do not commit it to this repository.
4. Select the project's license on CurseForge. The packager writes that license into `LICENSE.txt` inside the download.

## Publishing an update

1. Update `CHANGELOG.md` with notes for the version being released.
2. Update the interface number in `ShardSource.toc` only when required by a new client version. It is currently `16001` for Forever 1.60.1.
3. Commit the changes and push the release commit to `origin/master`.
4. Tag that commit and push the new tag. For the first testing build:

   ```sh
   git tag -a v2.0.0-beta.1 -m "ShardSource 2.0.0 beta 1 for WoW Forever"
   git push origin v2.0.0-beta.1
   ```

   When ready for a release, use `v2.0.0` instead. Use a new version for each subsequent upload; do not move a published tag.

Tags containing `alpha` produce Alpha files, tags containing `beta` produce Beta files, and ordinary version tags produce Release files. If packaging all commits is enabled on CurseForge, untagged commits produce Alpha files as well.

## What the packager does

- `.pkgmeta` puts the addon in a folder named `ShardSource`, matching `ShardSource.toc`.
- The tag replaces the version token in `ShardSource.toc`. The addon reads that version for its loading message and `/ssrc status`. An unpackaged checkout displays `development`.
- `CHANGELOG.md` supplies the upload's release notes.
- The generated archive includes the Lua file, TOC, changelog, and license. Repository instructions and dotfiles are excluded.

## Verify the first upload

Check GitHub's webhook delivery status and CurseForge's packaging result. In the generated file, confirm the flavor is Forever and the supported game version is 1.60.1. Download the ZIP and check that it contains `ShardSource/ShardSource.toc`, with the tag substituted for the version token.

The first package may require CurseForge moderation before it becomes available. CurseForge's submission guide says a project needs at least one Release file for normal app visibility; a Beta upload is useful for the initial packaging check.

References: [Automatic Packaging](https://support.curseforge.com/support/solutions/articles/9000197281-automatic-packaging), [PackageMeta configuration](https://support.curseforge.com/support/solutions/articles/9000197952-preparing-the-packagemeta-file), [Project submission](https://support.curseforge.com/support/solutions/articles/9000197241).
