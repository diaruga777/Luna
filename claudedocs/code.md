# Orbit extraction

Luna Code is once again the standalone [Orbit](https://github.com/diaruga777/Orbit)
app. The local checkout is `/Users/hsp/Desktop/Orbit`. Orbit owns its iOS editor,
Mac build/install host, transport, agent tools and app identities. Luna Mac keeps
Vault and Music; it no longer links or stages Code services.

Orbit now also includes phone-side cached-build renewal, a resumable Mac setup
wizard with a bundled phone installer, and JavaScript Home Screen/Lock Screen
widgets. See Orbit’s `docs/local-refresh.md`, `docs/distribution.md` and
`docs/widgets/README.md`. Existing Luna Code app data and credentials are preserved
on disk/Keychain, without automatic adoption by the standalone Orbit app.
