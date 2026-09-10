KEQDIS for macOS — installation and recovery

The app and executables are ad-hoc signed; the PKG installers are unsigned.
This build has no Apple Developer ID and is not notarized.
Install only a release you trust from https://github.com/caocaocc/keqdroid/releases .
Compare the downloaded DMG SHA-256 with its .sha256 sidecar before opening it.

1. Quit any existing KEQDIS instance from its menu.
2. Open Install KEQDIS.pkg and follow macOS Installer. Administrator permission
   installs /Applications/KEQDIS.app and the protected network service.
3. If macOS blocks the downloaded package, use System Settings > Privacy &
   Security > Open Anyway for that package, then retry. On macOS 12 this is
   System Preferences > Security & Privacy. Do not disable Gatekeeper globally.
4. Open KEQDIS from Applications. Proxy connects and switches the system proxy
   without an administrator prompt; its cores run as the current user. TUN asks
   for administrator authorization once per account and installed version.
   Updates require the complete installer and administrator authorization.

Closing the window keeps the connection in the menu bar when enabled.
Quit / Cmd+Q restores network settings before the app exits.

To uninstall, quit KEQDIS and run Uninstall KEQDIS.pkg. This first restores
network settings and stops the service; subscriptions and user settings remain.

If an upgrade reports a .previous directory, do not delete it. It holds rollback
components. Consult docs/MACOS.md in the source repository for the recovery
procedure; never delete a network recovery journal before restoration succeeds.
The installer validates the complete replacement before stopping the old service.
Ordinary startup failures restore the old application, runtime, launch configuration
and journal. If recovery itself fails, both versions and the journal remain for
repair; the installer does not delete them to force the upgrade through.
An interrupted upgrade can also leave a rollback-network-service.plist inside
the .incoming staging directory. Keep it with the .previous directories until
the recovery procedure has completed.

macOS 12 and both architectures require real-device acceptance before a release
is marked supported. Development/CI artifacts are unvalidated builds.
