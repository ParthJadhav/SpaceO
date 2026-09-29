import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('health', Path(__file__).resolve().parents[1] / 'scripts/host-health.py')
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class HostHealthTests(unittest.TestCase):
    def samples(self):
        a = dict(at=1, pressure=1, swap=dict(Swapins=100, Swapouts=200),
                 services={name: (i+1, 10.) for i, name in enumerate(health.SERVICES)})
        b = copy.deepcopy(a)
        b['at'] = 6
        return a, b

    def test_quiet_host_with_old_swap_is_admitted(self):
        self.assertTrue(health.assess(*self.samples())['admitted'])

    def test_cpu_counter_formats_and_service_filtering(self):
        for value, expected in [('403:18.33', 24198.33), ('01:02:03.5', 3723.5), ('2-01:02:03', 176523)]:
            self.assertAlmostEqual(health.cpu_seconds(value), expected)
        text = '1 00:01.00 /private/unrelated app\n' + '\n'.join(
            f'{i+10} 403:18.33 {name}' for i, name in enumerate(health.SERVICES))
        self.assertEqual(len(health.parse_services(text)), 2)
        for bad in ['', text.splitlines()[1], text + '\n' + text.splitlines()[1]]:
            with self.assertRaises(ValueError): health.parse_services(bad)

    def test_busy_services_pressure_and_current_swap_refuse(self):
        a, b = self.samples()
        service = health.SERVICES[0]
        b['services'][service] = (a['services'][service][0], 12.5)
        b['pressure'] = 2
        b['swap']['Swapouts'] += 1
        r = health.assess(a, b)
        self.assertFalse(r['admitted'])
        self.assertEqual(r['reasons'], ['memory_pressure', 'colorsync_busy', 'swap_activity'])
        self.assertEqual(r['colorsyncCPUPercent'], 50)
        self.assertNotIn(service, str(r))

    def test_restarts_counter_resets_and_short_intervals_are_unknown(self):
        for field in ['restart', 'cpu_reset', 'swap_reset', 'short', 'nan']:
            a, b = self.samples()
            name = health.SERVICES[0]
            if field == 'restart': b['services'][name] = (99, 10)
            if field == 'cpu_reset': b['services'][name] = (1, 9)
            if field == 'swap_reset': b['swap']['Swapins'] = 0
            if field == 'short': b['at'] = 2
            if field == 'nan': b['at'] = float('nan')
            with self.assertRaises(ValueError): health.assess(a, b)

    def test_helpers_are_bounded_and_nonzero_is_not_evidence(self):
        self.assertEqual(health.read_command([sys.executable, '-c', 'print("ok")']), 'ok\n')
        for code in ['raise SystemExit(1)', 'print("x" * (1024*1024+1))', 'import time; time.sleep(10)']:
            with self.assertRaises(ValueError): health.read_command([sys.executable, '-c', code])

    def test_matrix_refusal_does_not_start_mcp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / 'python3'
            helper.write_text('#!/bin/sh\nexit 1\n')
            helper.chmod(0o700)
            binary = root / 'fake-spaceo'
            # If reached, the marker is emitted independently of any live daemon or display.
            binary.write_text('#!/bin/sh\necho MCP_MUST_NOT_START >&2\nexit 99\n')
            binary.chmod(0o700)
            script = Path(__file__).resolve().parents[1] / 'scripts/computer-use-check.mjs'
            result = subprocess.run(['node', str(script), str(binary)], capture_output=True,
                text=True, timeout=5, env=dict(os.environ, SPACEO_LIVE_TESTS='1',
                PATH=str(root)+os.pathsep+os.environ['PATH']))
            self.assertEqual(result.returncode, 1)
            self.assertIn('host is not quiet enough', result.stderr)
            self.assertNotIn('MCP_MUST_NOT_START', result.stderr)


if __name__ == '__main__':
    unittest.main()
