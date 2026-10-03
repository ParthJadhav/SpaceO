import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('health', Path(__file__).resolve().parents[1] / 'scripts/host-health.py')
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class HostHealthTests(unittest.TestCase):
    def test_system_timeout_check_is_bounded_content_free_and_fail_closed(self):
        with mock.patch.object(health, 'read_command', return_value='[{"eventMessage":"private timeout content"}]') as read:
            self.assertEqual(health.windowserver_timeouts(100, 200), 1)
            command = read.call_args.args[0]
            self.assertEqual(command[:4], ['/usr/bin/log', 'show', '--style', 'json'])
            self.assertIn('--start', command)
            self.assertIn('--end', command)
        for value in ['{}', 'null', '[{}]', 'bad json']:
            with mock.patch.object(health, 'read_command', return_value=value):
                with self.assertRaises(ValueError): health.windowserver_timeouts(100, 200)
        with mock.patch.object(health, 'read_command', return_value='[]'):
            self.assertEqual(health.windowserver_timeouts(100, 200), 0)
            for since in [float('nan'), 201, -100000]:
                with self.assertRaises(ValueError): health.windowserver_timeouts(since, 200)

    def samples(self):
        a = dict(at=1, pressure=1, swap=dict(Swapins=100, Swapouts=200),
                 services={name: (i+1, 10.) for i, name in enumerate(health.SERVICES)})
        b = copy.deepcopy(a)
        b['at'] = 6
        return a, b

    def test_quiet_host_with_old_swap_is_admitted(self):
        self.assertTrue(health.assess(*self.samples())['admitted'])

    def test_windowserver_report_refuses_even_when_current_counters_are_quiet(self):
        report = health.assess(*self.samples(), diagnostic_reports=2)
        self.assertFalse(report['admitted'])
        self.assertEqual(report['reasons'], ['recent_windowserver_diagnostic'])
        self.assertEqual(report['windowServerDiagnosticReports'], 2)

    def test_incident_window_includes_this_boot_and_at_least_one_day(self):
        now = 200000
        self.assertEqual(health.diagnostic_cutoff('{ sec = 199900, usec = 0 }', now), now - 86400)
        self.assertEqual(health.diagnostic_cutoff('{ sec = 100, usec = 0 }', now), 100)
        for value in ['', 'sec = 0', 'sec = 200001', 'sec = 1 sec = 2']:
            with self.assertRaises(ValueError): health.diagnostic_cutoff(value, now)

    def test_metadata_scan_includes_retired_reports_without_reading_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Retired').mkdir()
            for name, modified in [('WindowServer-new.ips', 101), ('WindowServer-old.crash', 99),
                                   ('Retired/WindowServer_new.userspace_watchdog_timeout.spin', 100),
                                   ('Unrelated-new.ips', 101)]:
                path = root / name
                path.write_bytes(b'not parsed or published')
                os.utime(path, (modified, modified))
            self.assertEqual(health.windowserver_diagnostics([(root, True), (root/'absent', False)], 100), 2)
            with self.assertRaises(ValueError):
                health.windowserver_diagnostics([(root/'absent', True)], 100)
            (root / 'WindowServer-linked.ips').symlink_to(root/'WindowServer-new.ips')
            with self.assertRaises(ValueError): health.windowserver_diagnostics([(root, True)], 100)

    def test_unknown_or_over_budget_history_cannot_admit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'unrelated').touch()
            with mock.patch.object(health, 'MAX_DIAGNOSTIC_ENTRIES', 0):
                with self.assertRaises(ValueError): health.windowserver_diagnostics([(root, True)], 0)
            with mock.patch.object(health.os, 'scandir', side_effect=PermissionError):
                with self.assertRaises(OSError): health.windowserver_diagnostics([(root, True)], 0)
            with mock.patch.object(health.time, 'monotonic', side_effect=[0, 4]):
                with self.assertRaises(ValueError): health.windowserver_diagnostics([(root, True)], 0)

    def test_cpu_counter_formats_and_service_filtering(self):
        for value, expected in [('403:18.33', 24198.33), ('01:02:03.5', 3723.5), ('2-01:02:03', 176523)]:
            self.assertAlmostEqual(health.cpu_seconds(value), expected)
        text = '1 00:01.00 /private/unrelated app\n' + '\n'.join(
            f'{i+10} 403:18.33 {name}' for i, name in enumerate(health.SERVICES))
        self.assertEqual(len(health.parse_services(text)), 2)
        for bad in ['', text.splitlines()[1], text + '\n' + text.splitlines()[1]]:
            with self.assertRaises(ValueError): health.parse_services(bad)

    def idle_record(self, service=None):
        return ("system/service = {\n"
                "\tprogram = " + (service or health.SERVICES[0]) + "\n"
                "\tstate = not running\n\tactive count = 0\n\truns = 23\n"
                "\tlast exit reason = JETSAM_REASON_MEMORY_IDLE_EXIT\n"
                "\tproperties = supports pressured exit | system service\n"
                "\tendpoints = {\n\t\tstate = active\n\t}\n}\n")

    def test_idle_service_requires_exact_top_level_pressure_exit_evidence(self):
        text = self.idle_record()
        self.assertEqual(health.idle_service(text, health.SERVICES[0]), (None, 23))
        for bad in [text.replace('not running', 'running'),
                    text.replace('MEMORY_IDLE_EXIT', 'MEMORY_HIGHWATER'),
                    text.replace('active count = 0', 'active count = 1'),
                    text.replace('supports pressured exit', 'unsupported'),
                    text.replace('runs = 23', 'runs = -1'),
                    text.replace('\tstate = not running\n', ''),
                    text + '\tpid = 42\n', text + '\tlast terminating signal = 9\n',
                    text + '\tlast exit code = 1\n', text + '\tstate = not running\n',
                    self.idle_record('/private/other')]:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError): health.idle_service(bad, health.SERVICES[0])

    def test_stable_idle_services_admit_without_inventing_cpu_counters(self):
        a, b = self.samples()
        for name in health.SERVICES:
            a['services'][name] = b['services'][name] = (None, 23)
        report = health.assess(a, b)
        self.assertTrue(report['admitted'])
        self.assertEqual(report['colorsyncIdleServices'], 2)
        self.assertEqual(report['colorsyncCPUPercent'], 0)
        b['pressure'] = 2
        self.assertFalse(health.assess(a, b)['admitted'])
        self.assertFalse(health.assess(a, b, diagnostic_reports=1)['admitted'])

    def test_idle_service_does_not_mask_busy_running_peer(self):
        a, b = self.samples()
        a['services'][health.SERVICES[0]] = b['services'][health.SERVICES[0]] = (None, 23)
        b['services'][health.SERVICES[1]] = (2, 12.5)
        report = health.assess(a, b)
        self.assertEqual(report['colorsyncIdleServices'], 1)
        self.assertEqual(report['reasons'], ['colorsync_busy'])

    def test_idle_transitions_or_intervening_launch_refuse(self):
        for old, new in [((None, 23), (None, 24)), ((None, 23), (1, 10)), ((1, 10), (None, 23))]:
            a, b = self.samples()
            a['services'][health.SERVICES[0]] = old
            b['services'][health.SERVICES[0]] = new
            with self.assertRaises(ValueError): health.assess(a, b)

    def test_service_sample_reconciles_process_and_launchd_evidence(self):
        records = [self.idle_record(name) for name in health.SERVICES]
        with mock.patch.object(health, 'read_command', side_effect=['', *records, '']):
            self.assertEqual(health.service_sample(), {name: (None, 23) for name in health.SERVICES})
        for tail in ['42 00:01.00 ' + health.SERVICES[0]]:
            with mock.patch.object(health, 'read_command', side_effect=['', *records, tail]):
                with self.assertRaises(ValueError): health.service_sample()
        first = '42 00:01.00 ' + health.SERVICES[0]
        changed = '43 00:01.00 ' + health.SERVICES[0]
        with mock.patch.object(health, 'read_command', side_effect=[first, records[1], changed]):
            with self.assertRaises(ValueError): health.service_sample()
        with mock.patch.object(health, 'read_command', side_effect=['', ValueError('unreadable')]):
            with self.assertRaises(ValueError): health.service_sample()

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
