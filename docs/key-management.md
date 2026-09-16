# Signing key

The repository is signed by a dedicated ed25519 key with **no passphrase and no
expiry**. The original justification for a passphrase-less key (reprepro signing
via gpgme, which ignores `--passphrase-fd`) no longer applies, since signing now
calls `gpg` directly. Adding a passphrase would be a small change if wanted, but
the decision stands on the weaker argument: a passphrase stored in the same secret
store as the key it protects defends against nothing.

No expiry is deliberate. An expired repository key breaks `apt update` on every
client simultaneously, with an error that reads like a compromise rather than a
configuration issue.

- Private key: the `APT_SIGNING_KEY` secret, armoured. Nowhere else.
- Public key: `packaging/keys/unison-deb.asc`, also published at
  `$REPO_URL/unison-deb.asc` and shipped dearmoured inside `unison-deb-keyring`.

## Rotation, including after a compromise

1. Generate the new key.
2. Publish an `unison-deb-keyring` that contains **both** the old and new public
   keys, and bump `packaging/keyring-revision`. A keyring can hold several keys;
   apt accepts a Release signed by any of them.
3. Keep signing with the old key until clients have had time to upgrade.
4. Switch `APT_SIGNING_KEY` to the new key and re-run the workflow.
5. Once satisfied, publish a keyring with only the new key and bump the revision
   again.

Skipping step 2 breaks `apt update` for every client until each one manually
reinstalls the keyring. The transitional dual-key package is what makes rotation
non-disruptive.
