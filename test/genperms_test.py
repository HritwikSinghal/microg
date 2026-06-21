#!/usr/bin/env python3
"""Host tests for lib/genperms.py and lib/invariant.py.

Pure, hermetic tests with TINY hand-written fixtures -- NO real APKs, NO network,
NO Android toolchain. They exercise the bootloop-prevention logic that is the
heart of the project (design spec 6.1 / 6.2):

  * the intersection: requested-but-not-privileged perms are DROPPED;
    privileged-and-requested perms are KEPT; FAKE_PACKAGE_SIGNATURE is ALWAYS
    added even though it is absent from the privileged set;
  * emitted XML is well-formed and matches a checked-in expected fixture;
  * the permission invariant PASSES on a consistent set and FAILS (non-zero,
    with a precise diff) on an under-listed allowlist;
  * default-permissions must be a subset of what the APK requests;
  * the signer-cert gate PASSES on an unchanged cert and FAILS on a changed one.

Run:  python3 -m pytest test/genperms_test.py -v
  or: python3 -m unittest test.genperms_test -v
  or: python3 test/genperms_test.py
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

# Make lib/ importable regardless of cwd.
REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "lib"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "perms"
sys.path.insert(0, str(LIB_DIR))

import genperms  # noqa: E402
import invariant  # noqa: E402

FAKE = genperms.FAKE_PACKAGE_SIGNATURE


def _load_bump_module():
    """Import tools/bump (a shebang script with no .py extension) as a module.

    importlib.util lets us load it by explicit path so the bump tests can call
    its functions directly, hermetically, with no network and no subprocess.
    """
    bump_path = REPO_ROOT / "tools" / "bump"
    # bump has no .py extension, so spec_from_file_location can't infer a loader;
    # hand it a SourceFileLoader explicitly.
    loader = importlib.machinery.SourceFileLoader("bump_tool", str(bump_path))
    spec = importlib.util.spec_from_loader("bump_tool", loader)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # Register before exec: @dataclass resolves cls.__module__ via sys.modules.
    sys.modules["bump_tool"] = module
    spec.loader.exec_module(module)
    return module


bump = _load_bump_module()


class IntersectionTests(unittest.TestCase):
    """compute_granted: the core requested-INTERSECT-privileged + FAKE logic."""

    def test_keeps_privileged_and_requested(self) -> None:
        requested = {"a.LOC", "a.NET"}
        privileged = {"a.LOC", "a.NET", "a.OTHER"}
        granted = genperms.compute_granted(requested, privileged)
        self.assertIn("a.LOC", granted)
        self.assertIn("a.NET", granted)

    def test_drops_requested_but_not_privileged(self) -> None:
        requested = {"a.LOC", "a.INTERNET"}  # INTERNET is normal, not privileged
        privileged = {"a.LOC"}
        granted = genperms.compute_granted(requested, privileged)
        self.assertNotIn("a.INTERNET", granted)
        self.assertIn("a.LOC", granted)

    def test_ignores_privileged_not_requested(self) -> None:
        requested = {"a.LOC"}
        privileged = {"a.LOC", "a.UNREQUESTED"}
        granted = genperms.compute_granted(requested, privileged)
        self.assertNotIn("a.UNREQUESTED", granted)

    def test_fake_signature_always_added_even_if_not_privileged(self) -> None:
        # FAKE is microG-custom: absent from the privileged set, must survive.
        requested = {"a.LOC"}
        privileged = {"a.LOC"}  # no FAKE here on purpose
        granted = genperms.compute_granted(requested, privileged)
        self.assertIn(FAKE, granted)

    def test_fake_signature_can_be_disabled(self) -> None:
        granted = genperms.compute_granted({"a.LOC"}, {"a.LOC"}, add_fake_signature=False)
        self.assertNotIn(FAKE, granted)

    def test_empty_requested_yields_only_fake(self) -> None:
        granted = genperms.compute_granted(set(), {"a.LOC"})
        self.assertEqual(granted, {FAKE})

    def test_empty_privileged_still_grants_fake(self) -> None:
        # Edge case: empty privileged set must not crash and must keep FAKE.
        granted = genperms.compute_granted({"a.LOC"}, set())
        self.assertEqual(granted, {FAKE})


class RequestedParsingTests(unittest.TestCase):
    """Injectable requested-perms sources and tool-output parsers."""

    def test_normalize_strips_and_dedupes(self) -> None:
        out = genperms.normalize_requested([" a.X ", "a.X", "", "a.Y"])
        self.assertEqual(out, {"a.X", "a.Y"})

    def test_read_requested_file_skips_comments(self) -> None:
        out = genperms.read_requested_file(FIXTURES / "requested-gms.txt")
        self.assertIn("android.permission.ACCESS_FINE_LOCATION", out)
        self.assertIn(FAKE, out)
        self.assertNotIn("# Fixture", out)

    def test_parse_apkanalyzer_permissions(self) -> None:
        sample = (
            "android.permission.INTERNET\n"
            "uses-permission: android.permission.ACCESS_FINE_LOCATION\n"
            "org.microg.gms.STATUS_BROADCAST\n"
            "\n"
            "# a comment line\n"
            "some descriptive sentence with spaces\n"
        )
        out = genperms._parse_apkanalyzer_permissions(sample)
        self.assertEqual(
            out,
            {
                "android.permission.INTERNET",
                "android.permission.ACCESS_FINE_LOCATION",
                "org.microg.gms.STATUS_BROADCAST",
            },
        )

    def test_parse_aapt2_permissions(self) -> None:
        sample = (
            "package: name='com.x'\n"
            "uses-permission: name='android.permission.INTERNET'\n"
            "uses-permission: name='android.permission.ACCESS_FINE_LOCATION'\n"
        )
        out = genperms._parse_aapt2_permissions(sample)
        self.assertEqual(
            out,
            {
                "android.permission.INTERNET",
                "android.permission.ACCESS_FINE_LOCATION",
            },
        )


class PrivilegedLoadingTests(unittest.TestCase):
    """Loading the privileged-perms data files (real repo data/)."""

    def test_loads_target_api_and_unions_extra(self) -> None:
        perms = genperms.load_privileged_perms(34, REPO_ROOT / "data")
        # FAKE is intentionally present in the data file as a documented entry,
        # but the generator does not rely on that -- intersection tests above
        # prove FAKE is added regardless.
        self.assertIn("android.permission.WRITE_SECURE_SETTINGS", perms)
        # API 34-only entry should appear after the union pulls in the 34 file.
        self.assertIn("android.permission.BLUETOOTH_CONNECT", perms)
        # API 30-only entry should appear because 30 is unioned in by default.
        self.assertIn("android.permission.SEND_SMS_NO_CONFIRMATION", perms)

    def test_missing_target_api_file_raises(self) -> None:
        with self.assertRaises(genperms.GenPermsError):
            genperms.load_privileged_perms(999, REPO_ROOT / "data")

    def test_parse_aosp_manifest(self) -> None:
        manifest = (
            '<?xml version="1.0"?>\n'
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '  <permission android:name="a.PRIV" '
            'android:protectionLevel="signature|privileged"/>\n'
            '  <permission android:name="a.SIG" '
            'android:protectionLevel="signature"/>\n'
            '  <permission android:name="a.DEV" '
            'android:protectionLevel="signature|privileged|development"/>\n'
            "</manifest>\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "AndroidManifest.xml"
            p.write_text(manifest, encoding="ascii")
            out = genperms.privileged_perms_from_aosp_manifest(p)
        self.assertEqual(out, {"a.PRIV", "a.DEV"})


class XmlGenerationTests(unittest.TestCase):
    """XML emission: well-formedness, validation, and fixture match."""

    def test_emitted_xml_matches_expected_fixture(self) -> None:
        requested = genperms.read_requested_file(FIXTURES / "requested-gms.txt")
        privileged = genperms._read_perm_list_file(
            FIXTURES / "privileged-sample.txt"
        )
        granted = genperms.compute_granted(requested, privileged)
        xml = genperms.build_privapp_xml("com.google.android.gms", granted)
        expected = (FIXTURES / "expected-gms.xml").read_text(encoding="ascii")
        self.assertEqual(xml, expected)

    def test_emitted_xml_is_well_formed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "gms.xml"
            granted = genperms.generate_privapp_file(
                package="com.google.android.gms",
                requested={"a.LOC"},
                privileged={"a.LOC"},
                out_path=out,
            )
            # validate_xml inside generate_privapp_file would have raised; assert
            # the file exists and re-validate explicitly.
            self.assertTrue(out.is_file())
            genperms.validate_xml(out)
            self.assertIn(FAKE, granted)

    def test_sysconfig_is_separate_and_well_formed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "sysconfig-microg.xml"
            genperms.generate_sysconfig_file(["com.google.android.gms"], out)
            text = out.read_text(encoding="ascii")
            genperms.validate_xml(out)
            # Behavioral exemptions live here, NOT in any allowlist.
            self.assertIn("allow-in-power-save", text)
            self.assertIn("allow-unthrottled-location", text)
            self.assertNotIn("privapp-permissions", text)

    def test_malformed_xml_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.xml"
            bad.write_text("<permissions><privapp-permissions></permissions>", "ascii")
            with self.assertRaises(genperms.GenPermsError):
                genperms.validate_xml(bad)

    def test_doctype_is_rejected_xxe_guard(self) -> None:
        # Defence-in-depth: a DTD/DOCTYPE must be refused by the safe parser.
        with tempfile.TemporaryDirectory() as tmp:
            evil = Path(tmp) / "evil.xml"
            evil.write_text(
                '<?xml version="1.0"?>\n'
                "<!DOCTYPE foo [ <!ENTITY x \"y\"> ]>\n"
                "<permissions/>\n",
                "ascii",
            )
            with self.assertRaises(genperms.GenPermsError):
                genperms._safe_parse(evil)


class PermissionInvariantTests(unittest.TestCase):
    """invariant.check_permission_invariant: PASS consistent, FAIL under-listed."""

    def setUp(self) -> None:
        self.privileged = {"a.LOC", "a.NET", "a.SECURE"}

    def test_passes_when_allowlist_is_superset(self) -> None:
        requested = {"a.LOC", "a.INTERNET", FAKE}
        allowlist = {"a.LOC", FAKE}  # INTERNET is non-priv so not required
        result = invariant.check_permission_invariant(
            "GmsCore", requested, self.privileged, allowlist
        )
        self.assertTrue(result.ok, result.report())

    def test_fails_when_allowlist_underlists_a_privileged_perm(self) -> None:
        # APK newly requests a.NET (privileged) but allowlist forgot it -> bootloop.
        requested = {"a.LOC", "a.NET", FAKE}
        allowlist = {"a.LOC", FAKE}  # missing a.NET
        result = invariant.check_permission_invariant(
            "GmsCore", requested, self.privileged, allowlist
        )
        self.assertFalse(result.ok)
        self.assertIn("a.NET", result.report())
        self.assertIn("BOOTLOOP", result.report())

    def test_fails_when_fake_signature_requested_but_not_allowlisted(self) -> None:
        requested = {"a.LOC", FAKE}
        allowlist = {"a.LOC"}  # forgot FAKE
        result = invariant.check_permission_invariant(
            "GmsCore", requested, self.privileged, allowlist
        )
        self.assertFalse(result.ok)
        self.assertIn(FAKE, result.report())

    def test_default_permissions_must_be_subset_of_requested(self) -> None:
        requested = {"a.LOC"}
        allowlist = {"a.LOC", FAKE}
        default_perms = {"a.LOC", "a.NOT_REQUESTED"}
        result = invariant.check_permission_invariant(
            "GmsCore",
            requested,
            self.privileged,
            allowlist,
            default_perms=default_perms,
        )
        self.assertFalse(result.ok)
        self.assertIn("a.NOT_REQUESTED", result.report())

    def test_generated_allowlist_passes_its_own_invariant(self) -> None:
        # End-to-end: generate from fixtures, read back, invariant must PASS.
        requested = genperms.read_requested_file(FIXTURES / "requested-gms.txt")
        privileged = genperms._read_perm_list_file(
            FIXTURES / "privileged-sample.txt"
        )
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "GmsCore.xml"
            genperms.generate_privapp_file(
                "com.google.android.gms", requested, privileged, out
            )
            allowlist = invariant.read_allowlist_xml(out)
        result = invariant.check_permission_invariant(
            "GmsCore", requested, privileged, allowlist
        )
        self.assertTrue(result.ok, result.report())


class SignerCertGateTests(unittest.TestCase):
    """invariant.signer_cert_gate: PASS unchanged cert, FAIL changed cert."""

    def _load(self, name: str) -> dict:
        return invariant._load_toml(FIXTURES / name)

    def test_unchanged_cert_passes_for_gms(self) -> None:
        old = self._load("manifest-old.toml")
        # Compare GmsCore-only by filtering to it in both manifests.
        old_gms = {"apk": [e for e in old["apk"] if e["name"] == "GmsCore"]}
        new = self._load("manifest-new.toml")
        new_gms = {"apk": [e for e in new["apk"] if e["name"] == "GmsCore"]}
        result = invariant.signer_cert_gate(old_gms, new_gms)
        self.assertTrue(result.ok, result.report())

    def test_changed_cert_fails(self) -> None:
        old = self._load("manifest-old.toml")
        new = self._load("manifest-new.toml")
        result = invariant.signer_cert_gate(old, new)
        self.assertFalse(result.ok)
        self.assertIn("FakeStore", result.report())
        self.assertIn("SECURITY EVENT", result.report())

    def test_new_component_is_not_flagged(self) -> None:
        old = {"apk": []}
        new = {"apk": [{"name": "GmsCore", "signer_cert_sha256": "abc"}]}
        result = invariant.signer_cert_gate(old, new)
        self.assertTrue(result.ok, result.report())


class CliIntegrationTests(unittest.TestCase):
    """End-to-end CLI exit codes for genperms and invariant."""

    def test_genperms_cli_writes_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "gms.xml"
            rc = genperms.main(
                [
                    "gen",
                    "--requested-file",
                    str(FIXTURES / "requested-gms.txt"),
                    "--priv-file",
                    str(FIXTURES / "privileged-sample.txt"),
                    "--package",
                    "com.google.android.gms",
                    "--out",
                    str(out),
                ]
            )
            self.assertEqual(rc, 0)
            self.assertTrue(out.is_file())

    def test_invariant_check_signer_cli_fails_on_changed_cert(self) -> None:
        rc = invariant.main(
            [
                "check-signer",
                "--old",
                str(FIXTURES / "manifest-old.toml"),
                "--new",
                str(FIXTURES / "manifest-new.toml"),
            ]
        )
        self.assertEqual(rc, 1)

    def test_invariant_check_perms_cli_passes_on_consistent_set(self) -> None:
        # Build a tiny consistent component tree: manifest + apks sidecar + perms.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apks = root / "apks"
            perms = root / "perms"
            apks.mkdir()
            perms.mkdir()
            # Sidecar requested-perms for component "GmsCore".
            (apks / "GmsCore.perms").write_text(
                "android.permission.WRITE_SECURE_SETTINGS\n"
                "android.permission.INTERNET\n"
                f"{FAKE}\n",
                "ascii",
            )
            # Generated allowlist must include the privileged + FAKE perms.
            genperms.generate_privapp_file(
                package="com.google.android.gms",
                requested={
                    "android.permission.WRITE_SECURE_SETTINGS",
                    "android.permission.INTERNET",
                    FAKE,
                },
                privileged=genperms.load_privileged_perms(34, REPO_ROOT / "data"),
                out_path=perms / "gmscore.xml",
            )
            manifest = root / "manifest.toml"
            manifest.write_text(
                'schema_version = 1\n\n'
                '[[apk]]\n'
                'name = "GmsCore"\n'
                'package = "com.google.android.gms"\n'
                'type = "app"\n'
                'url = "https://example/gms.apk"\n'
                'signer_cert_sha256 = "abc"\n',
                "ascii",
            )
            rc = invariant.main(
                [
                    "check-perms",
                    "--manifest",
                    str(manifest),
                    "--perms-dir",
                    str(perms),
                    "--apks-dir",
                    str(apks),
                    "--api",
                    "34",
                    "--data-dir",
                    str(REPO_ROOT / "data"),
                ]
            )
            self.assertEqual(rc, 0)

    def test_invariant_check_perms_cli_fails_on_underlist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apks = root / "apks"
            perms = root / "perms"
            apks.mkdir()
            perms.mkdir()
            # APK requests a privileged perm...
            (apks / "GmsCore.perms").write_text(
                "android.permission.WRITE_SECURE_SETTINGS\n"
                "android.permission.MODIFY_PHONE_STATE\n",
                "ascii",
            )
            # ...but the allowlist OMITS MODIFY_PHONE_STATE -> must fail.
            genperms.generate_privapp_file(
                package="com.google.android.gms",
                requested={"android.permission.WRITE_SECURE_SETTINGS"},
                privileged={"android.permission.WRITE_SECURE_SETTINGS"},
                out_path=perms / "gmscore.xml",
            )
            manifest = root / "manifest.toml"
            manifest.write_text(
                'schema_version = 1\n\n'
                '[[apk]]\n'
                'name = "GmsCore"\n'
                'package = "com.google.android.gms"\n'
                'type = "app"\n'
                'url = "https://example/gms.apk"\n'
                'signer_cert_sha256 = "abc"\n',
                "ascii",
            )
            rc = invariant.main(
                [
                    "check-perms",
                    "--manifest",
                    str(manifest),
                    "--perms-dir",
                    str(perms),
                    "--apks-dir",
                    str(apks),
                    "--api",
                    "34",
                    "--data-dir",
                    str(REPO_ROOT / "data"),
                ]
            )
            self.assertEqual(rc, 1)


class SignerNormalizationTests(unittest.TestCase):
    """_norm_cert: the SINGLE canonicalizer shared by the gate and tools/bump."""

    def test_colon_and_case_reformat_is_equivalent(self) -> None:
        # A cosmetic reformat of an UNCHANGED hex cert must canonicalize equal.
        colon = "9B:D0:67:27:E6:27:96:C0"
        plain = "9bd06727e62796c0"
        self.assertEqual(invariant._norm_cert(colon), invariant._norm_cert(plain))

    def test_placeholders_compare_verbatim(self) -> None:
        # Non-hex sentinels are not normalized away; distinct ones stay distinct.
        self.assertEqual(
            invariant._norm_cert("n-a-framework-jar"), "n-a-framework-jar"
        )
        self.assertNotEqual(
            invariant._norm_cert("TODO-phase2"),
            invariant._norm_cert("n-a-framework-jar"),
        )

    def test_gate_does_not_fire_on_cosmetic_reformat(self) -> None:
        # Same cert, one colon-grouped + uppercased -> gate must PASS.
        old = {"apk": [{"name": "X", "signer_cert_sha256": "9B:D0:67:27"}]}
        new = {"apk": [{"name": "X", "signer_cert_sha256": "9bd06727"}]}
        result = invariant.signer_cert_gate(old, new)
        self.assertTrue(result.ok, result.report())

    def test_gate_fires_on_genuine_cert_change(self) -> None:
        old = {"apk": [{"name": "X", "signer_cert_sha256": "9bd06727"}]}
        new = {"apk": [{"name": "X", "signer_cert_sha256": "deadbeef"}]}
        result = invariant.signer_cert_gate(old, new)
        self.assertFalse(result.ok)
        self.assertIn("SECURITY EVENT", result.report())

    def test_bump_and_invariant_share_one_canonicalizer(self) -> None:
        # The whole point of the fix: bump must reuse the gate's _norm_cert, not
        # a divergent local copy. Verify it is literally the same function.
        self.assertIs(bump._norm_cert, invariant._norm_cert)


class BumpApplyResultsTests(unittest.TestCase):
    """apply_results: a missing key line must be fatal (no stale-anchor write)."""

    _MANIFEST = (
        "schema_version = 1\n\n"
        "[[apk]]\n"
        'name               = "GmsCore"\n'
        'package            = "com.google.android.gms"\n'
        'type               = "app"\n'
        'source             = "github"\n'
        "version_code       = 1\n"
        'url                = "https://example/old.apk"\n'
        'sha256             = "old"\n'
        'signer_cert_sha256 = "abc"\n'
    )

    def test_missing_sha256_key_raises_and_does_not_write(self) -> None:
        # Drop the sha256 line: _set_field returns False, which must now be fatal
        # so we never write a new url+version_code beside a stale/absent sha256.
        manifest_text = self._MANIFEST.replace('sha256             = "old"\n', "")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.toml"
            path.write_text(manifest_text, "utf-8")
            result = bump.BumpResult(
                name="GmsCore", version_code=2, url="https://example/new.apk",
                sha256="newhash",
            )
            with self.assertRaises(bump.BumpError) as ctx:
                bump.apply_results(path, [result], dry_run=False)
            self.assertIn("sha256", str(ctx.exception))
            # The file must be byte-for-byte unchanged (atomic swap never ran).
            self.assertEqual(path.read_text("utf-8"), manifest_text)

    def test_all_keys_present_writes_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.toml"
            path.write_text(self._MANIFEST, "utf-8")
            result = bump.BumpResult(
                name="GmsCore", version_code=2, url="https://example/new.apk",
                sha256="newhash",
            )
            bump.apply_results(path, [result], dry_run=False)
            written = path.read_text("utf-8")
            self.assertIn("version_code       = 2", written)
            self.assertIn('"https://example/new.apk"', written)
            self.assertIn('"newhash"', written)
            # No temp file left behind in the directory.
            leftovers = [p.name for p in Path(tmp).iterdir() if p.name != "manifest.toml"]
            self.assertEqual(leftovers, [])


class BumpDowngradeGuardTests(unittest.TestCase):
    """bump_component: refuse a lower versionCode unless --allow-downgrade."""

    def _component(self, committed_vc: int) -> object:
        return bump.Component(
            name="GmsCore",
            package="com.google.android.gms",
            type="app",
            source="github",
            url="https://example/gms.apk",
            sha256="old",
            signer_cert_sha256="abc",
            version_code=committed_vc,
        )

    def _patch(self, resolved_vc: int) -> list:
        """Stub out network/subprocess so the guard logic runs hermetically.

        Returns the list of (attr, original) to restore.
        """
        saved = []
        for attr, stub in (
            ("_resolve", lambda c: bump.ResolvedArtifact(url=c.url, version_code_hint=resolved_vc)),
            ("_download", lambda url, dest: None),
            ("_sha256_file", lambda p: "newhash"),
            ("_read_version_code", lambda apk, hint: resolved_vc),
            # signer cert matches committed -> gate passes, downgrade logic runs.
            ("_read_signer_cert_sha256", lambda apk: "abc"),
        ):
            saved.append((attr, getattr(bump, attr)))
            setattr(bump, attr, stub)
        return saved

    def _restore(self, saved: list) -> None:
        for attr, original in saved:
            setattr(bump, attr, original)

    def test_downgrade_refused_by_default(self) -> None:
        saved = self._patch(resolved_vc=5)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(bump.BumpError) as ctx:
                    bump.bump_component(self._component(10), Path(tmp))
                self.assertIn("DOWNGRADE", str(ctx.exception))
        finally:
            self._restore(saved)

    def test_downgrade_allowed_with_flag(self) -> None:
        saved = self._patch(resolved_vc=5)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                res = bump.bump_component(
                    self._component(10), Path(tmp), allow_downgrade=True
                )
                self.assertEqual(res.version_code, 5)
        finally:
            self._restore(saved)

    def test_same_version_is_accepted(self) -> None:
        saved = self._patch(resolved_vc=10)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                res = bump.bump_component(self._component(10), Path(tmp))
                self.assertEqual(res.version_code, 10)
        finally:
            self._restore(saved)

    def test_upgrade_is_accepted(self) -> None:
        saved = self._patch(resolved_vc=11)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                res = bump.bump_component(self._component(10), Path(tmp))
                self.assertEqual(res.version_code, 11)
        finally:
            self._restore(saved)


class BumpLoadComponentsTests(unittest.TestCase):
    """load_components: duplicate-name detection + clear field validation."""

    _BASE = (
        "schema_version = 1\n\n"
        "[[apk]]\n"
        'name = "GmsCore"\n'
        'package = "com.google.android.gms"\n'
        'type = "app"\n'
        'source = "github"\n'
        "version_code = 1\n"
        'url = "https://example/a.apk"\n'
        'sha256 = "a"\n'
        'signer_cert_sha256 = "abc"\n'
    )

    def _write(self, text: str) -> Path:
        tmp = tempfile.mkdtemp()
        path = Path(tmp) / "manifest.toml"
        path.write_text(text, "utf-8")
        return path

    def test_duplicate_name_raises(self) -> None:
        dup = self._BASE + (
            "\n[[apk]]\n"
            'name = "GmsCore"\n'  # same name again
            'package = "com.other"\n'
            'type = "app"\n'
            'source = "fdroid"\n'
            "version_code = 1\n"
            'url = "https://example/b.apk"\n'
            'sha256 = "b"\n'
            'signer_cert_sha256 = "def"\n'
        )
        with self.assertRaises(bump.BumpError) as ctx:
            bump.load_components(self._write(dup))
        self.assertIn("duplicate", str(ctx.exception).lower())

    def test_missing_required_field_raises_bumperror(self) -> None:
        # Drop sha256 -> a bare KeyError must NOT escape; a BumpError must.
        bad = self._BASE.replace('sha256 = "a"\n', "")
        with self.assertRaises(bump.BumpError):
            bump.load_components(self._write(bad))

    def test_non_int_version_code_raises_bumperror(self) -> None:
        bad = self._BASE.replace("version_code = 1\n", 'version_code = "oops"\n')
        with self.assertRaises(bump.BumpError):
            bump.load_components(self._write(bad))

    def test_valid_manifest_loads(self) -> None:
        comps = bump.load_components(self._write(self._BASE))
        self.assertEqual(len(comps), 1)
        self.assertEqual(comps[0].name, "GmsCore")


if __name__ == "__main__":
    unittest.main(verbosity=2)
