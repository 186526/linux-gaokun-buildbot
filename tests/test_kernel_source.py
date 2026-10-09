#!/usr/bin/env python3
"""Check that source preparation never overwrites a mismatched or dirty tree."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'scripts/lib/kernel_source.sh'
SELECT_BASE = Path(__file__).resolve().parents[1] / 'scripts/ci/lib/select_base.sh'
KERNEL_VARIANTS = Path(__file__).resolve().parents[1] / 'scripts/ci/20_build_kernel_variants.sh'


class SourcePreparation(unittest.TestCase):
    def test_el2_localversion_is_overridable_with_compatible_default(self):
        script = KERNEL_VARIANTS.read_text()
        self.assertIn('KERN_LOCALVERSION_EL2="${KERN_LOCALVERSION_EL2:--gaokun3-el2}"', script)
        self.assertIn('build_variant "$KERN_SRC_EL2" "$KERN_OUT_EL2" "$KERN_LOCALVERSION_EL2"', script)

    def test_xanmod_dsc_change_requires_all_anchors(self):
        # The anchor must be the patch's post-image, not the XanMod base's
        # truncating form. Anchoring on the base form makes the helper report
        # 0011 as already applied when 0005 is missing, so the pipeline skips it
        # silently and the truncating DSC timing width stays in the build.
        applied_file = (
            '#include <drm/display/drm_dsc_helper.h>\n'
            'timing->width = DIV_ROUND_UP(timing->width * drm_dsc_get_bpp_int(dsc),\n'
            'timing->dce_bytes_per_line = msm_dsc_get_bytes_per_line(dsc);\n'
        )
        base_file = (
            '#include <drm/display/drm_dsc_helper.h>\n'
            'timing->width = timing->width * drm_dsc_get_bpp_int(dsc) /\n'
            'timing->dce_bytes_per_line = msm_dsc_get_bytes_per_line(dsc);\n'
        )
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c'
            target.parent.mkdir(parents=True)
            command = [
                'bash', '-euc',
                '. "$1"; KERNEL_BASE=xanmod; xanmod_change_is_present "$2" "$3"',
                'test', str(SELECT_BASE), directory,
                '0011-drm-msm-dpu-restore-dsc-interface-data-width.patch',
            ]
            # The rounded post-image counts as applied.
            target.write_text(applied_file)
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            # The truncating base form must NOT count as applied.
            target.write_text(base_file)
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            # A partial match must not count as applied either.
            target.write_text('#include <drm/display/drm_dsc_helper.h>\n')
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_existing_checkout_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            config = repo / 'arch/arm64/configs/gaokun3_defconfig'
            config.parent.mkdir(parents=True)
            config.write_text('CONFIG_TEST=y\n')
            git('add', '.')
            git('commit', '-qm', 'fixture')
            commit = git('rev-parse', 'HEAD')
            def prepare(sha):
                return subprocess.run(['bash', '-euc', '. "$1"; prepare_kernel_source "$2" "$3"',
                                       'test', str(HELPER), directory, sha], capture_output=True)
            self.assertEqual(prepare(commit).returncode, 0)
            self.assertNotEqual(prepare('0' * 40).returncode, 0)
            self.assertEqual(git('rev-parse', 'HEAD'), commit)
            config.write_text('local edit\n')
            self.assertNotEqual(prepare(commit).returncode, 0)
            self.assertEqual(config.read_text(), 'local edit\n')
            git('checkout', '--', str(config.relative_to(repo)))
            (repo / 'untracked.c').write_text('local file\n')
            self.assertNotEqual(prepare(commit).returncode, 0)
            self.assertTrue((repo / 'untracked.c').exists())


class DeviceParityBaseAware(unittest.TestCase):
    """The camera (G5) anchors must only apply to the xanmod base.

    The pinned mainline tree does not replay patches/0099 or patches/others/*,
    so requiring the OV13B10 binding there would fail a tree that cannot carry
    it. The checker must therefore select its anchor set from the kernel base.
    """

    PARITY = Path(__file__).resolve().parents[1] / 'scripts/ci/check_device_parity.sh'
    REPO = Path(__file__).resolve().parents[1]

    def _series(self, base):
        return subprocess.run(
            ['bash', str(self.PARITY), '--series', base],
            capture_output=True, text=True,
        )

    def test_series_xanmod_reports_camera_anchors_present(self):
        # The repository's patch series must carry every G5 anchor, so the
        # xanmod preflight reports them OK rather than PENDING.
        result = self._series('xanmod')
        self.assertEqual(result.returncode, 0, result.stderr)
        for label in ('G5 camera ov13b10 node', 'G5 camera ov13b10 compatible',
                      'G5 camera ov13b10 OF match', 'G5 camera ov13b10 get_selection',
                      'G5 camera camcc shared RCG'):
            self.assertIn(f'OK: {label}', result.stdout)

    def test_series_mainline_does_not_require_camera_anchors(self):
        result = self._series('mainline')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('G5 camera', result.stdout)

    def test_tree_check_is_base_gated(self):
        # A tree carrying G1-G4 but none of the camera work passes on mainline
        # and fails on xanmod; adding the camera anchors flips xanmod to pass.
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            files = {
                'sound/soc/qcom/sc8280xp.c':
                    'snd_soc_limit_volume(card, "WSA_RX0 Digital Volume", 84);\n'
                    'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 29);\n',
                'arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts':
                    'mode-select-pins\npins = "gpio174";\noutput-low;\n',
                'drivers/input/touchscreen/himax-spi-core.c':
                    'RX overwrites TX, including the command, on each attempt.\n'
                    'ts->spi_xfer_max_sz = HIMAX_HX83121A_FULL_STACK_SZ + HIMAX_BUS_R_HLEN;\n',
                'drivers/input/touchscreen/hx-algo.c':
                    'm->dist2 > algo->track_jump_dist2\n',
                'drivers/platform/arm64/huawei-gaokun-ec.c':
                    'return dev_err_probe(dev, PTR_ERR(ec->enable_gpio),\n',
            }
            for rel, body in files.items():
                target = tree / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(body)

            def check(base):
                return subprocess.run(
                    ['bash', str(self.PARITY), str(tree), base],
                    capture_output=True, text=True,
                )

            self.assertEqual(check('mainline').returncode, 0)
            self.assertNotEqual(check('xanmod').returncode, 0)

            for rel, body in {
                'arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-camera.dtsi':
                    'camera_rear: camera@36 {\ncompatible = "ovti,ov13b10";\n'
                    'ov13b10_ep: endpoint {\n',
                'drivers/media/i2c/ov13b10.c':
                    '.of_match_table = ov13b10_of_ids,\n.get_selection = ov13b10_get_selection,\n',
                'drivers/clk/qcom/camcc-sc8280xp.c':
                    '.ops = &clk_rcg2_shared_ops,\n',
            }.items():
                target = tree / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(body)
            self.assertEqual(check('xanmod').returncode, 0)

    def test_stale_s5k3l6_rear_binding_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            for rel, body in {
                'sound/soc/qcom/sc8280xp.c':
                    'snd_soc_limit_volume(card, "WSA_RX0 Digital Volume", 84);\n'
                    'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 29);\n',
                'arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts':
                    'mode-select-pins\npins = "gpio174";\noutput-low;\n',
                'drivers/input/touchscreen/himax-spi-core.c':
                    'RX overwrites TX, including the command, on each attempt.\n'
                    'ts->spi_xfer_max_sz = HIMAX_HX83121A_FULL_STACK_SZ + HIMAX_BUS_R_HLEN;\n',
                'drivers/input/touchscreen/hx-algo.c':
                    'm->dist2 > algo->track_jump_dist2\n',
                'drivers/platform/arm64/huawei-gaokun-ec.c':
                    'return dev_err_probe(dev, PTR_ERR(ec->enable_gpio),\n',
                'arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-camera.dtsi':
                    'camera_rear: camera@10 {\ncompatible = "samsung,s5k3l6xx";\n'
                    'ov13b10_ep: endpoint {\n',
                'drivers/media/i2c/ov13b10.c':
                    '.of_match_table = ov13b10_of_ids,\n.get_selection = ov13b10_get_selection,\n',
                'drivers/clk/qcom/camcc-sc8280xp.c':
                    '.ops = &clk_rcg2_shared_ops,\n',
            }.items():
                target = tree / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(body)
            result = subprocess.run(
                ['bash', str(self.PARITY), str(tree), 'xanmod'],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('stale s5k3l6 camera@10 node removed', result.stderr)


if __name__ == '__main__':
    unittest.main()
