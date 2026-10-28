# Releasing CarbonCC

Releases are built, signed with Aqalpi Technologies' Developer ID, notarized by Apple and published by GitHub Actions (`.github/workflows/release.yml`) whenever a version tag is pushed. The workflow also updates the Homebrew tap.

## Making a release

```bash
echo 1.1.0 > VERSION
git commit -am "Release 1.1.0"
git tag v1.1.0
git push origin main v1.1.0
```

That's it. In about 5–10 minutes the release appears under **Releases** and `brew upgrade --cask carboncc` picks it up. The tag must match `VERSION`, or the workflow stops.

---

## One-time setup

### 1. Developer ID Application certificate

Only the Apple Developer **Account Holder** can create this.

1. On a Mac signed in to the Aqalpi Technologies team: **Xcode → Settings → Accounts →** select the team **→ Manage Certificates → + → Developer ID Application**.
2. Check it's in **Keychain Access → login → My Certificates** as *Developer ID Application: Aqalpi Technologies (TEAMID)*, with a private key under it (▸ arrow).
3. Export it for CI: right-click the certificate → **Export…** → save as `developer-id.p12` with a strong password.
4. Copy it as base64:
   ```bash
   base64 -i developer-id.p12 | pbcopy
   ```
   Then delete `developer-id.p12` from disk. Never commit it.

### 2. App Store Connect API key (for notarization)

1. **App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → +**.
2. Name it `CarbonCC notarization`, access **Developer**.
3. Download the `AuthKey_XXXXXX.p8` file. It can only be downloaded once. Note the **Key ID** and the **Issuer ID** shown at the top of the page.
4. Copy the key as base64:
   ```bash
   base64 -i AuthKey_XXXXXX.p8 | pbcopy
   ```

### 3. Token for the Homebrew tap

GitHub → your profile → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**:

- **Resource owner:** Aqalpi-Technologies
- **Repository access:** Only select repositories → `homebrew-tap`
- **Permissions:** Contents → **Read and write**
- **Expiration:** up to you. Set a reminder to renew it.

If the organization requires approval for fine-grained tokens, approve it under the organization's **Settings → Personal access tokens → Pending requests**.

### 4. Repository secrets

In `Aqalpi-Technologies/carboncc` → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | base64 of the `.p12` (step 1) |
| `DEVELOPER_ID_P12_PASSWORD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any random string (used for a temporary keychain on the build machine) |
| `NOTARY_KEY_P8_BASE64` | base64 of the `.p8` (step 2) |
| `NOTARY_KEY_ID` | the Key ID |
| `NOTARY_ISSUER_ID` | the Issuer ID |
| `HOMEBREW_TAP_TOKEN` | the token from step 3 |

### 5. Make both repositories public before the first release

`carboncc` and `homebrew-tap` must be public for downloads and `brew install` to work: **Settings → General → Danger Zone → Change visibility**.

---

## Releasing from your own Mac (optional)

If CI is unavailable, the same script works locally with the Developer ID certificate in your keychain.

Store the notarization credentials once:

```bash
xcrun notarytool store-credentials carboncc-notary \
  --key ~/path/to/AuthKey_XXXXXX.p8 --key-id XXXXXX --issuer YOUR-ISSUER-ID
```

Then:

```bash
NOTARY_PROFILE=carboncc-notary scripts/release.sh
```

The result is `build/CarbonCC-<version>.zip`. Upload it to a GitHub release by hand.

## If notarization fails

`scripts/release.sh` prints Apple's log. The usual causes are:

- **Signed without hardened runtime or timestamp.** The script always adds both, so this means something else re-signed the app.
- **An expired or revoked certificate.** Create a new one and update the two `DEVELOPER_ID_P12_*` secrets.
- **The API key was revoked, or doesn't have Developer access.**
