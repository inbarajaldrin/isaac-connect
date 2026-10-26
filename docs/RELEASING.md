# Releasing Isaac Connect

## Source candidate

Review the Swift app, Linux launcher, selected `Assets/Icon/AppIcon.svg` and
`AppIcon.icns`, renderer lock/importer, license notices, and documentation together.
Local icon explorations remain on disk and are ignored by Git. Imported NVIDIA
renderer files are also ignored; only the integration README in that directory
belongs to the source candidate.

Before committing:

```sh
python3 -m unittest discover -s Tests -v
for script in Scripts/*.sh linux/isaac-ctl; do bash -n "$script"; done
python3 Scripts/import-renderer.py --check
git diff --check
./Scripts/build.sh
```

On a Linux host, run `python3 linux/test-isaac-ctl.py`. Its temporary processes,
runtime directories, and config files are isolated from the real sim.

CI compiles the native app using the tracked renderer integration directory. It
does not import proprietary assets or produce a distributable app.

## Verified runtime

The review used an Apple Silicon Mac and an RTX 6000 Ada Linux workstation with
Isaac Sim 6.1. The native Linux window and Mac viewer showed the same test scene.
The generic launcher's headless launch, stop, relaunch, session detachment, and
client reconnect were exercised. The native-window review used a custom profile
with `isaacsim.exp.full.streaming` and the desktop session's display environment.

ROS 2 startup errors in that workstation's 6.1 installation were observed during
the review. These checks do not establish ROS 2 readiness.

## Signed Mac download

1. Finish the renderer licensing review using `docs/renderer-provenance.md` and
   the referenced NVIDIA agreement. Preserve the upstream notices in the app.
2. Create a **Developer ID Application** certificate for the release account in
   Xcode's certificate manager. Apple Development signing is for the local build.
3. Store notarization credentials in the keychain under `isaac-connect-notary`:

   ```sh
   xcrun notarytool store-credentials isaac-connect-notary
   ```

4. From a clean, reviewed commit on `main`, prepare the artifact:

   ```sh
   ./Scripts/release.sh v0.1.0 --no-upload
   ```

The script verifies the signature, submits for notarization, staples and validates
the ticket, and requires Gatekeeper acceptance before it makes the final ZIP and
SHA-256 file. The filename identifies the architecture actually built.

## Publication

After the source and artifact review, create the `isaac-connect` GitHub repository
and push the approved `main` commit. Run the release script without `--no-upload`
to publish against that exact commit; it refuses an existing release version.

Once the repository and release links work, publish the corresponding fuzzydroid
Isaac Connect references and pending plugin changes to `main`.
