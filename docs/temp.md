● Apologies -- "Deja Vu" slipped in with accents. Re-sending with ASCII only.

  1. Component comparison matrix

  + = shipped/default, o = optional/variant, - = absent.

  ┌──────────────────────────────────────────────┬───────────────────┬─────────────────┬──────────────────┬──────────────────┬───────────────┬────────────────────────────┐
  │               Component (pkg)                │       Ours        │     micro5k     │    MinMicroG     │    NanoDroid     │ nift4-revived │ Lineage4microG (canonical) │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ GmsCore c.g.a.gms                            │ +                 │ +               │ +                │ +                │ + (harvested) │ +                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ GsfProxy c.g.a.gsf                           │ +                 │ +               │ +                │ +                │ +             │ +                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ FakeStore/Companion c.a.vending              │ +                 │ +               │ + (most)         │ +                │ +             │ +                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ Real Play Store / Phonesky                   │ o (deferred)      │ o (full ed.)    │ + (Std/Phonesky) │ o                │ o             │ -                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ MapsV1 framework c.g.a.maps                  │ +                 │ +               │ +                │ o                │ +             │ +                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ Contacts sync ...syncadapters.contacts       │ -                 │ -               │ o (Std default)  │ o (Google ed.)   │ -             │ -                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ Calendar sync ...syncadapters.calendar       │ -                 │ -               │ o (Std default)  │ o (Google ed.)   │ -             │ -                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ DroidGuard helper                            │ - (in GmsCore)    │ -               │ - (legacy)       │ o                │ -             │ -                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ F-Droid + Priv-Extension                     │ -                 │ + (priv-ext)    │ - (dropped)      │ +                │ -             │ +                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ Aurora Store / Services                      │ -                 │ o (services)    │ + (NoGoolag)     │ o                │ -             │ -                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ Location backends (DejaVu/Mozilla/Nominatim) │ -                 │ o (legacy only) │ - (dropped '23)  │ o                │ -             │ o (build)                  │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ WebView (Bromite)                            │ -                 │ -               │ -                │ o                │ -             │ -                          │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ Sig-spoofing patcher                         │ - (by design)     │ -               │ -                │ + (services.jar) │ -             │ + (native ROM)             │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ OTA survival (addon.d)                       │ - (module-only)   │ +               │ +                │ +                │ -             │ n/a (ROM)                  │
  ├──────────────────────────────────────────────┼───────────────────┼─────────────────┼──────────────────┼──────────────────┼───────────────┼────────────────────────────┤
  │ Stock-GApps debloat                          │ partial (we mask) │ +               │ +                │ +                │ -             │ n/a                        │
  └──────────────────────────────────────────────┴───────────────────┴─────────────────┴──────────────────┴──────────────────┴───────────────┴────────────────────────────┘

  Read: our 5-component set (GmsCore, GsfProxy, FakeStore, MapsV1, deferred Phonesky) is exactly the canonical Lineage4microG core minus F-Droid. We're not missing anything load-bearing on the package axis. The
  differences are add-ons and the spoofing story.

  2. What microG requires to work -- and where we stand

  The official requirements (GmsCore wiki + the canonical Lineage4microG packaging), checked against our repo:

  ┌──────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────┐
  │                         Requirement                          │                                 Status in our repo                                  │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Privileged placement + privapp-permissions on same partition │ OK -- place.sh + per-partition perms                                                │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ privapp allowlist covers every priv perm GmsCore requests    │ GAP -- see below                                                                    │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ sysconfig allow-in-power-save                                │ OK (genperms emits it)                                                              │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ sysconfig allow-unthrottled-location                         │ OK                                                                                  │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ sysconfig allow-in-data-usage-save                           │ MISSING -- canonical has 3 entries, we emit 2                                       │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ FAKE_PACKAGE_SIGNATURE in allowlist                          │ OK                                                                                  │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Signature spoofing in framework                              │ Not provided (by design) -- the one hard requirement an APK installer can't satisfy │
  ├──────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Battery-opt exemption, checkin, mtalk.google.com reachable   │ runtime/user concerns, fine                                                         │
  └──────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────┘

  The one real correctness gap (bootloop class)

  The canonical microG privapp-permissions is exactly four perms:
  FAKE_PACKAGE_SIGNATURE, INSTALL_LOCATION_PROVIDER,
  CHANGE_DEVICE_IDLE_TEMP_WHITELIST, UPDATE_APP_OPS_STATS
  Our data/privileged-perms-30/34.txt superset has FAKE, INSTALL_LOCATION_PROVIDER and UPDATE_APP_OPS_STATS -- but CHANGE_DEVICE_IDLE_TEMP_WHITELIST is absent from both files (I grepped; it's not there).

  Why this matters: genperms builds the allowlist as requested(APK) INTERSECT our_superset. If the bundled GmsCore requests CHANGE_DEVICE_IDLE_TEMP_WHITELIST (the canonical file strongly implies it does), the
  intersection silently drops it because it's not in our superset -- and on Android 9+ in enforce mode, a requested-but-not-allowlisted privileged permission is exactly the bootloop this whole project exists to 
  prevent (it's the MANAGE_USB-bootloop story from 2022, same mechanism). And our invariant can't catch it, because the invariant decides "is this perm privileged?" using the same incomplete superset.

  Two fixes, both cheap and safe (over-listing the superset is harmless -- it only matters when also requested):
  - Add CHANGE_DEVICE_IDLE_TEMP_WHITELIST to both perms files now.
  - Structurally: in CI, derive "privileged" from the real AOSP frameworks/base manifest (genperms already supports --aosp-manifest) instead of a hand-curated list -- that closes the superset-completeness blind
  spot permanently.
  
  3. The signature-spoofing reality (most important takeaway)

  Every source agrees: microG officially still requires framework-level signature spoofing, and there is no official Zygisk spoofing module. On stock Android the only runtime options are (a) an Xposed/LSPosed
  module FakeGApps (capped ~Android 15), or (b) a ROM that bakes it in. None of the surveyed installers bundle spoofing -- they all defer it to the ROM or FakeGApps, same as us.

  So our "no spoofing bundled" stance is consistent with the field, but it means: out of the box on a stock ROM without spoofing, microG installs cleanly and then fails for most client apps. This must be stated
  loudly in the README/spoofing guide so users aren't surprised.

  One genuinely relevant piece of prior art for a no-spoofing design: microg_no_sigspoof uses apksigcopier to copy Google's signature block onto the microG APKs and installs them as system apps (system-app
  signatures aren't verified the same way), sidestepping spoofing entirely. It's directly aligned with your stance -- but it conflicts with our 3-anchor signer verification, breaks F-Droid self-updates, and the
  tool is archived. Worth knowing about, not necessarily adopting.

  4. Genuine optional add-ons we lack (none are blockers)

  - Contacts/Calendar sync adapters -- the one functional capability gap (Google account Contacts/Calendar sync). Google-signed, optional. Easy to add as [[apk]] rows.
  - F-Droid Privileged Extension + microG repo seeding -- in the canonical set; nice for self-updating.
  - Location backends -- looks like a gap but isn't: UnifiedNlp is now inside GmsCore and the field is removing standalone backends (MinMicroG dropped them in 2023). Omitting them is correct.
  - DroidGuard helper -- also a non-gap; integrated into GmsCore now.
  - addon.d OTA survival -- only relevant once you do Phase 3 system-mode; module mode survives inherently.

  ---
  Recommended next actions (your call):
  1. Now (correctness): add CHANGE_DEVICE_IDLE_TEMP_WHITELIST to both perms files + allow-in-data-usage-save to the sysconfig emitter -- both are bootloop/push-reliability fixes grounded in the canonical
  packaging. I can do these in minutes.
  2. Structural: switch the CI privileged-set to --aosp-manifest so the superset can't silently under-list again.
  3. Docs: make the spoofing prerequisite explicit in the README.
  4. Optional features: draft manifest entries for Contacts/Calendar sync + F-Droid Priv-Extension if you want them.

  Want me to start with #1 (and verify against the actual bundled GmsCore manifest via genperms dump-requested to confirm whether it really requests CHANGE_DEVICE_IDLE_TEMP_WHITELIST)?

✻ Chur
