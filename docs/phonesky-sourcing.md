# Phonesky (Google Play Store) Sourcing -- Decision / Research

- Status: Decision record for Phase 2 open question
- Date: 2026-06-20
- Scope: How (and whether) to source the real Google Play Store APK
  (Phonesky, package `com.android.vending`) for the installer's optional store
  variant, mutually exclusive with microG Companion (FakeStore).
- Resolves: design spec section 12 open question -- "Phonesky has no stable
  redistributable URL and licensing is gray; CI sourcing may need a maintained
  mirror."
- Constraints: research + decision only. No code, manifest, or build changes
  are made by this document.

This doc distinguishes VERIFIED facts (with a source URL) from ASSESSMENT (my
analysis / recommendation). Sources are listed at the end and referenced inline
as [n].

---

## 1. The problem

The other components this installer bundles (GmsCore, GsfProxy, FakeStore,
MapsV1) are microG-project software. GmsCore / GsfProxy / FakeStore are free
software (Apache-2.0) published by microG with a stable, well-known signing key
and stable release URLs (GitHub releases + the F-Droid repo). The build pins
three trust anchors per component -- versionCode, APK sha256, signer-cert
sha256 -- and a signer-cert change is a hard CI failure (design spec sec 6.2).
That model works because microG controls the publishing channel and the key is
a stable trust root.

Phonesky is different on every axis:

- VERIFIED: Phonesky is Google's proprietary Play Store client
  (`com.android.vending`). There is no official Google channel that distributes
  it as a standalone, hotlinkable APK -- Google ships it preinstalled on
  GMS-certified devices and updates it in-place via the Play Store itself.
- VERIFIED: "GApps" packages (Open GApps, MindTheGapps, NikGApps) exist
  precisely because AOSP cannot legally bundle Google's proprietary apps;
  their build *scripts* are often open source, but the Google apps they package
  are proprietary and are redistributed without a Google license -- the
  acknowledged source of the legal gray area. microG is the legally clean
  option specifically because it is a clean reimplementation that redistributes
  no Google code. [5]
- ASSESSMENT: redistributing the Phonesky APK from this project's own
  release artifacts would mean this repo directly hosts/serves Google
  proprietary binaries without authorization. That is a materially different
  legal posture from shipping microG's own Apache-2.0 apps, and it is the kind
  of unauthorized-redistribution exposure (DMCA takedown, ToS breach) that the
  rest of the design deliberately avoids. I am not a lawyer; this is a risk
  assessment, not a legal opinion. [5]

So the question is not just "where is a URL" -- it is "can the project pin and
trust a Phonesky source without (a) hosting Google's binary itself, (b)
depending on an unstable/ToS-violating link, or (c) breaking the 3-anchor
model."

---

## 2. Sourcing options surveyed

### (a) APKMirror / well-known APK mirrors

- VERIFIED: APKMirror has a no-piracy / no-paid-apps policy, manually reviews
  every APK, and honors developer takedown / redirect requests. [3]
- VERIFIED: APKMirror deliberately does NOT expose a stable, hotlinkable direct
  download URL. Downloads route through dynamic, session/Cloudflare-gated
  intermediate pages; third-party scrapers exist but are explicitly
  unaffiliated and "as is." [3]

Tradeoffs:
- Redistribution legality: this project would not host the binary, but
  programmatically scraping APKMirror in CI is against the spirit of their flow
  and is fragile by design; APKMirror itself is redistributing Google's
  proprietary APK, so the gray area is inherited, not removed.
- URL stability: poor. No durable URL; Cloudflare/session gating breaks
  unattended CI; layout/token changes break scrapers without notice.
- Fit with 3-anchor pinning: technically the pinned `sha256` would still
  guarantee we got exactly the reviewed bytes, and `apksigner` would still
  verify Google's cert -- BUT the `url` is not durable, so a hermetic rebuild
  from the same manifest could 404. That violates the build's "same manifest in
  -> identical zip out" invariant.
- Maintenance burden: high and adversarial -- scraper maintenance plus risk of
  IP blocking / ToS escalation. ASSESSMENT: reject.

### (b) Extract from a GApps package

- VERIFIED: Open GApps is effectively dead. The last automated builds across
  all architectures (arm, arm64, x86, x86_64) are dated 3 May 2022; no builds
  since. The project had infrastructure/maintainer-time problems as far back as
  2019. [4]
- VERIFIED: MindTheGapps is the de facto successor and the package LineageOS
  recommends; NikGApps is the actively maintained, customizable alternative
  (Basic/Core/Full variants). [2]
- VERIFIED: in all of these the packaging tooling may be open source, but the
  payload (Play Store etc.) is Google proprietary, redistributed without a
  Google license. [5]

Tradeoffs:
- Redistribution legality: same proprietary-redistribution gray area; we would
  also be a second-order redistributor (extracting from a third party that is
  itself an unauthorized redistributor).
- URL stability: Open GApps is a dead end (do not pin a 2022 artifact as the
  "current" Play Store). MindTheGapps/NikGApps publish dated package bundles
  (often on SourceForge / their own mirrors), not a single stable
  "latest Phonesky.apk" URL; the inner APK path inside the bundle changes
  across releases. [2][4]
- Fit with 3-anchor pinning: we would have to pin the *bundle* hash and a path
  to the inner APK, then re-extract and re-pin the inner APK's sha256 + signer
  cert. Doable but indirect, and the signer cert is still Google's (see sec 3).
- Maintenance burden: medium-high. Tracking a third-party packager's release
  cadence and internal layout, plus an extraction step in CI. ASSESSMENT:
  acceptable only as a documented manual-pin fallback, not as an automated
  `bump` source.

### (c) Project-maintained mirror

ASSESSMENT (no external source needed -- this is a design choice):
- Redistribution legality: WORST option. The project would itself host and
  serve Google's proprietary APK from its own infrastructure -- the most direct
  unauthorized-redistribution exposure, exactly what microG's clean-room posture
  exists to avoid. A takedown would hit the project directly.
- URL stability: good (we control it) -- but bought at the cost above.
- Fit with 3-anchor pinning: clean (stable url + sha256 + Google signer cert).
- Maintenance burden: high -- hosting, bandwidth, and ongoing legal exposure
  for a single optional component. ASSESSMENT: reject. The pinning benefit does
  not justify turning the project into a distributor of Google binaries.

### (d) User-supplied APK (installer detects a user-dropped Phonesky)

ASSESSMENT (this is the design lever the manifest already hints at):
- The build/ZIP ships NO Phonesky binary. The Phonesky manifest entry stays
  deferred (`url = ""`, `signer_cert_sha256 = "TODO-phase2"`), so `bump` and
  `components.conf` emission both skip it -- which is already how the current
  manifest is written (see `manifest.toml`, Phonesky block).
- Activation is opt-in: the user obtains their own Play Store APK (from their
  device, their own backup, or a source they trust) and drops it at a
  documented path the installer looks for at flash time. The installer detects
  it, and only then places it -- mutually exclusive with FakeStore.
- Redistribution legality: BEST. The project never hosts or ships Google's
  binary; the user supplies a copy they are already entitled to (typically
  pulled from their own GMS device). No project-side redistribution.
- URL stability: not applicable -- nothing is downloaded by the build.
- Fit with 3-anchor pinning: the project pins NOTHING for Phonesky in the
  hermetic build (it has no bytes to pin). Authenticity instead moves to an
  ON-DEVICE check at flash time (see sec 3): verify the user-dropped APK is
  package `com.android.vending` and is signed by Google's cert before placing
  it; refuse otherwise. This keeps the build hermetic and the manifest entry
  permanently deferred.
- Maintenance burden: LOW. No URL to track, no scraper, no hosting, no signer
  bump churn. Only the on-device detect+verify path and docs need maintenance.

---

## 3. Signer / authenticity

- VERIFIED (spec): the Google signing cert SHA-1 the design references (for the
  spoofing guide, not used by the installer) is
  `38918a453d07199354f8b19af05ec6562ced5788` (design spec sec 4). ASSESSMENT:
  this is widely recognized in the Android community as Google's platform/system
  signing cert used for core Google system apps; the web search could not pin a
  single authoritative source mapping it specifically to `com.android.vending`,
  so treat the exact cert-to-Phonesky mapping as "verify on the actual APK"
  rather than a hardcoded constant. [1]
- VERIFIED: a Play Store APK is signed by Google, NOT by microG. This is the
  whole point: every other bundled component carries the microG signer cert
  `9bd06727e62796c0130eb6dab39b73157451582cbd138e86c468acc395d14165`
  (`manifest.toml` header); Phonesky carries Google's. [1]

How this interacts with the pinning gate:
- The build's signer-cert gate (`signer_cert_sha256`, hard-fail on change) is
  designed around ONE stable trust root -- microG's -- so that "one check
  defends all of /system/priv-app" (design spec sec 3, 6.2). Phonesky breaks
  that single-root assumption: it would introduce a SECOND, foreign trust root
  (Google's) into the same gate.
- ASSESSMENT: do not weaken or special-case the build's signer gate to admit a
  second cert. Instead, because the recommended path is user-supplied (option
  d), the cert check is enforced on-device at flash time, not in the hermetic
  build:
  - the installer should run an `apksigner`-equivalent / cert-fingerprint check
    on the user-dropped APK, assert package == `com.android.vending` and
    signer == Google's cert, and refuse to place anything that fails. Phonesky
    must not be replaced by an arbitrary unsigned/foreign-signed APK on a
    priv-app path.
  - use the cert SHA-256 digest from `apksigner --print-certs` (the v3-aware
    label), not the public-key digest, and not a v1/JAR-only reader -- the same
    discipline the build uses for microG components (design spec sec 6).
  - the exact expected Google cert fingerprint should be derived once from a
    known-good Play Store APK and recorded in the on-device check + docs, with
    a clear note that a future Google key rotation is a documented manual
    update, not an auto-bump.

---

## 4. Recommendation

ADOPT option (d): user-supplied Phonesky, with option (b) extraction documented
ONLY as a manual fallback for advanced users. Reject (a) and (c).

Rationale:
- Keeps the project out of the proprietary-redistribution gray area entirely --
  no project-hosted Google binary, no scraping a mirror's ToS-gated flow. [3][5]
- Preserves both core build invariants: the build stays hermetic (it downloads
  nothing for Phonesky) and "same manifest in -> identical zip out" holds
  because no unstable URL is pinned.
- Preserves the single-trust-root signer gate: Google's cert never enters the
  build's `signer_cert_sha256` gate; authenticity is enforced on-device instead.
- Lowest maintenance: no mirror, no scraper, no signer-bump churn for a foreign
  key on a dead-since-2022 / takedown-prone supply chain. [4]
- FakeStore (microG Companion) remains the shipped default, so the out-of-box
  experience needs no Google binary at all.

Implication for `manifest.toml` (NOT changed by this doc -- this is the
proposed end state):
- The Phonesky `[[apk]]` entry stays DEFERRED exactly as it is today:
  `url = ""`, `sha256 = "PENDING-BUMP"`, `signer_cert_sha256 = "TODO-phase2"`,
  `conflicts = ["FakeStore"]`. `bump` and `components.conf` emission both skip
  it. The TODO comment can be updated to point here and state the decision
  ("user-supplied; never pinned in-build") so a future maintainer does not try
  to fill in a URL.
- ASSESSMENT: optionally record the expected Google signer-cert fingerprint as
  a documented constant for the ON-DEVICE check only (clearly separate from the
  build's `signer_cert_sha256` field, which must stay microG-only).

Implication for the Phase 2 build:
- Phase 2 still delivers the things it should: the `type=framework` MapsV1 path
  and the FakeStore<->Phonesky conflict-resolution logic across place + perms +
  cleanup. The conflict logic is exercised by the user-supplied Phonesky path
  the same way it would be by a bundled one -- it just triggers off a detected
  user-dropped APK instead of a build-time asset.
- The installer gains: a detection step for the user-dropped Phonesky (a
  documented drop path), an on-device package + signer-cert verification, and
  the atomic mutual-exclusion with FakeStore (placing Phonesky removes / does
  not place FakeStore, and vice versa). No build-time download path is added.

---

## 5. Verification + pitfalls

- VERIFIED: Phonesky is only useful with microG Device Registration
  (check-in) enabled -- you must enable Google device registration in microG
  settings before you can log into Phonesky; the supported setup enables the
  background-services checkboxes (device registration + Cloud Messaging). In
  microG, check-in identifiers (phoneInfo / deviceIdent) are faked. [6]
- VERIFIED: the microG Self-Check item for Phonesky's signature commonly stays
  red unless signature spoofing is actually working and the real Play Store APK
  is installed; this is separate from enabling device registration. [6]
- VERIFIED: Phonesky additionally depends on signature spoofing being granted
  by the ROM/add-on -- which this installer deliberately does NOT bundle
  (design spec sec 1, 9). So Phonesky is a no-op without the separately
  documented spoofing setup. [6]
- VERIFIED: the microG/Phonesky client repo is archived (read-only since
  2021-05-06) with no releases -- it is NOT a usable source of a redistributable
  Play Store APK and should not be mistaken for one. [7]
- Must NOT coexist with real GMS: if real Google Play Services is present and
  active, microG + Phonesky auth breaks (design spec sec 7 checklist).
- FakeStore <-> Phonesky mutual exclusion: same package `com.android.vending`;
  exactly one may be placed. The conflict must be resolved atomically across
  placement, permissions, and cleanup (design spec sec 7) so a half-applied
  swap never leaves two `com.android.vending` owners or a stale perms XML.
- Re-flash / upgrade: placement must be idempotent and replace (not merge) the
  prior store's perms XML when switching between FakeStore and Phonesky.

Suggested test coverage (host-side, no device needed for the logic):
- detection: given a present/absent user-dropped APK at the documented path,
  the interpreter selects Phonesky vs FakeStore correctly.
- mutual exclusion: selecting Phonesky must un-select FakeStore in
  `components.conf` interpretation, and vice versa; never both.
- signer-cert verify: a non-Google-signed `com.android.vending` APK is refused.
Device-side (user-deployed; the agent does not flash): confirm self-check shows
Phonesky present at the right versionCode with spoofing + device registration
enabled, and no bootloop.

---

## Sources

- [1] com.android.vending is signed by Google / verifying APK signer certs:
  https://github.com/spytrap-org/spytrap-adb/issues/34 ;
  https://github.com/talsec/Free-RASP-Community/wiki/Getting-your-signing-certificate-hash-of-app
- [2] GApps successors -- MindTheGapps (LineageOS-recommended) and NikGApps:
  https://alternativeto.net/software/mindthegapps ;
  https://alternativeto.net/software/nikgapps
- [3] APKMirror policies + no stable hotlink (Cloudflare/session-gated):
  https://www.apkmirror.com/faq/ ;
  https://github.com/illogical-robot/apkmirror-public/issues/304 ;
  https://github.com/tanishqmanuja/apkmirror-downloader
- [4] Open GApps last builds 3 May 2022 (effectively dead):
  https://github.com/opengapps/arm64/releases/ ;
  https://opengapps.org/blog/post/2019/02/17/github-situation/
- [5] GApps repackage proprietary Google apps without a Google license; microG
  is the clean-room legal alternative:
  https://grokipedia.com/page/Comparison_of_NikGApps_Core_and_MindTheGapps ;
  https://support.corellium.com/features/apps/install-gapps
- [6] microG device registration / Phonesky setup + self-check behavior:
  https://github.com/microg/GmsCore/wiki/Installation ;
  https://xdaforums.com/t/no-gapps-guide-tutorial-microg.3771483/
- [7] microG/Phonesky client repo is archived, no releases:
  https://github.com/microg/Phonesky
