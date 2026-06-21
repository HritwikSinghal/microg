# Signature Spoofing -- Prerequisite Guide

- Status: Guide for a prerequisite this installer deliberately does NOT bundle
- Scope: why microG needs signature spoofing, why this ZIP ships none, the
  realistic ways to obtain it on stock Android, and how to verify it works.

This installer places microG as privileged system apps. It does **not** provide
signature spoofing. Spoofing is the genuinely ROM-specific, framework-level part
of a microG setup; you must supply it separately. Without it microG installs
cleanly but most Google-API apps will reject it.

---

## 1. Why spoofing is needed

microG officially requires framework-level signature spoofing to function as a
drop-in replacement for Google Play Services. Apps that talk to Google APIs
verify that they are communicating with the genuinely-signed
`com.google.android.gms` (Google's platform signing cert, SHA-1
`38918a453d07199354f8b19af05ec6562ced5788`). microG is a clean reimplementation
signed by microG's own key, so that check fails unless the framework is made to
*report Google's signature* for microG's package -- this is "signature
spoofing".

The practical symptom: without spoofing, microG installs and runs, but most
Google-API client apps refuse to use it (login fails, push does not arrive, the
microG Self-Check flags the signature item red).

## 2. Why this installer bundles none (out of scope by design)

Spoofing is the ROM-specific, hard, fast-moving part of the stack, and there is
**no official Zygisk signature-spoofing module** to bundle. Baking a spoofing
engine into the ZIP would tie it to a specific Android version / root manager /
Xposed stack and turn a low-maintenance system-app installer into a fragile,
constantly-breaking one. So the installer's job stops at placing the privileged
apps correctly; spoofing is delegated to your ROM or a separate add-on, exactly
as the established installers (MinMicroG, micro5k) do.

One subtlety to keep straight: microG declares a custom privileged permission,
`FAKE_PACKAGE_SIGNATURE`, and this installer **does** generate that permission
into microG's privapp allowlist XML. But the *permission* is inert on its own.
It only grants the *right to ask* for a spoofed signature; the ROM/framework
still has to actually implement the spoof. Granting `FAKE_PACKAGE_SIGNATURE`
without a framework that honors it does nothing -- do not mistake the permission
appearing in the allowlist for spoofing being active.

## 3. Ways to get spoofing on stock Android

### Option A -- a microG-aware ROM (recommended)

The cleanest path is a ROM that bakes signature spoofing into the framework:

- LineageOS for microG, /e/OS, CalyxOS, iodeOS -- all ship framework spoofing.
- Mainline LineageOS 18.1+ has the spoofing patch upstreamed, but restricted:
  it only spoofs for microG's official signing certificate, so it works for
  stock microG builds and not for arbitrary re-signed packages.

On such a ROM, spoofing is already present; this installer's components simply
work, and you do nothing extra for spoofing. (If your ROM already includes
microG, you likely do not need this installer at all.)

### Option B -- FakeGApps via LSPosed (Xposed route)

On a stock ROM with root you can add spoofing as an **Xposed module** (note:
Xposed/LSPosed, not Zygisk). FakeGApps is the module that supplies the spoof.
The required stack is:

```
Magisk / KernelSU / APatch   (root + Zygisk)
  -> Zygisk                  (built into Magisk; ReZygisk / Zygisk Next on KSU/APatch)
    -> LSPosed               (the Xposed framework, loaded via Zygisk)
      -> FakeGApps           (the spoofing module)
```

Caveats:

- This stack is more fragile than a ROM patch and depends on LSPosed/FakeGApps
  keeping pace with new Android releases. As of writing the practical ceiling is
  around Android 15; treat that as a moving target -- verify current FakeGApps /
  LSPosed compatibility for your exact Android version before relying on it.
- LSPosed fork selection and the Zygisk implementation differ per root manager
  (Magisk has Zygisk built in; KernelSU / APatch typically need ReZygisk or
  Zygisk Next). Match these to your setup.

### Option C -- apksigcopier prior art (not a recommendation)

For completeness, there is an external project, `microg_no_sigspoof`, that
sidesteps spoofing entirely rather than enabling it. It uses `apksigcopier` to
copy Google's signature block onto the microG APKs, then installs those as
system apps so signature checks pass without any framework spoof.

This is recorded here as prior art, not as advice. Caveats:

- It breaks F-Droid self-updates of microG (the copied signature no longer
  matches microG's own publishing key, so F-Droid will not update the apps).
- The upstream tooling is archived.
- It is fundamentally a different approach from what this installer does (this
  installer ships microG's genuine, microG-signed APKs and relies on real
  framework spoofing). Mixing the two is not supported here.

If you choose this route, do so with the project's own documentation and at your
own risk; this installer neither performs nor endorses signature copying.

## 4. Verifying spoofing actually works

The authoritative test is microG's own Self-Check:

- Open microG Settings -> Self-Check.
- The "System grants signature spoofing" item must be green/checked. If it is
  red, spoofing is not active no matter what modules are installed.

Do **not** rely on the old standalone "Signature Spoofing Checker" app or on a
ROM's spoofing-patch claims alone. In November 2024 Google changed its
signature-checking code, and as a result stale ROM spoofing patches and the old
standalone checker app became unreliable indicators. microG's own Self-Check is
the current authoritative signal that spoofing is genuinely working end to end.

## 5. Quick checklist

- [ ] microG installed (this installer) and the device booted (see the
      boot-time self-check log at `/data/adb/microg_installer/selfcheck.log`).
- [ ] Signature spoofing provided by one of: a microG-aware ROM (Option A) or
      LSPosed + FakeGApps (Option B).
- [ ] microG Settings -> Self-Check shows "System grants signature spoofing" as
      green.
- [ ] No real Google Play Services present/active (microG and stock GMS must not
      coexist).
