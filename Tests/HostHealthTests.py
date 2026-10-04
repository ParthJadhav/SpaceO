import copy
import importlib.util
import io
import json
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
                 services={name: (i+1, 10., 1) for i, name in enumerate(health.SERVICES)})
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

    def test_post_boot_report_never_ages_out_in_the_same_boot(self):
        boot, report = 1_000_000, 1_003_600
        for hours in [2, 14, 23, 24, 25, 48, 720]:
            cutoff = health.diagnostic_cutoff(f'{{ sec = {boot}, usec = 0 }}', boot + hours * 3600)
            self.assertGreaterEqual(report, cutoff)

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
        self.assertEqual(len(health.parse_services(text.splitlines()[1])), 1)
        self.assertEqual(health.parse_services('1 00:00.00 /bin/ps'), {})
        for bad in ['', 'malformed listing', 'invalid ' + health.SERVICES[0], text + '\n' + text.splitlines()[1]]:
            with self.assertRaises(ValueError): health.parse_services(bad)

    IDLE = ["state = not running", "active count = 0", "runs = 23",
            "last exit reason = JETSAM_REASON_MEMORY_IDLE_EXIT",
            "last jetsam exit details = JETSAM_REASON_MEMORY_IDLE_EXIT", "job state = exited",
            "properties = partial import | supports pressured exit | system service"]
    NEVER_STARTED = ["active count = 0", "state = not running", "runs = 0",
                     "last exit code = (never exited)"]

    def record(self, fields, service=None, program=None):
        service = service or health.SERVICES[0]
        # Nested blocks are ignored; only top-level fields are evidence.
        return ("system/" + health.launchd_label(service) + " = {\n\tprogram = " + (program or service) + "\n"
                + "".join("\t" + field + "\n" for field in fields)
                + '\tendpoints = {\n\t\t"x" = {\n\t\t\tpid = 9\n\t\t\tstate = running\n\t\t}\n\t}\n}\n')

    def running_record(self, pid, service, runs=1):
        return self.record(["active count = 2", "state = running", f"runs = {runs}", f"pid = {pid}",
                            "last exit code = (never exited)", "job state = running"], service)

    def test_launchd_evidence_accepts_only_exact_running_idle_exit_and_never_started(self):
        service = health.SERVICES[0]
        self.assertEqual(health.launchd_service(self.record(self.IDLE), service), (None, 23))
        self.assertEqual(health.launchd_service(self.record(self.NEVER_STARTED), service), (None, 0))
        self.assertEqual(health.launchd_service(self.running_record(533, service, 4), service), (533, 4))
        idle = lambda old, new: self.record([new if f.startswith(old) else f for f in self.IDLE if new or not f.startswith(old)])
        for bad in [idle("last exit reason", "last exit reason = JETSAM_REASON_MEMORY_HIGHWATER"),
                    self.record(self.IDLE + ["last terminating signal = Killed: 9"]),
                    self.record(self.IDLE + ["last exit code = 1"]), self.record(self.IDLE + ["pid = 42"]),
                    idle("active count", "active count = 1"), idle("properties", "properties = system service"),
                    idle("job state", "job state = spawn scheduled"), idle("runs", "runs = 0"),
                    idle("state = not running", "state = spawn scheduled"),
                    self.record([f.replace("runs = 0", "runs = 1") for f in self.NEVER_STARTED]),
                    self.record(self.NEVER_STARTED + ["job state = exited"]),
                    self.record(["state = running", "runs = 1"]), self.record(["state = running", "runs = 1", "pid = 0"]),
                    "", "malformed", idle("runs", "runs = -1"), idle("runs", None),
                    self.record(self.IDLE + ["state = not running"]),
                    self.record(self.IDLE, health.SERVICES[1]), self.record(self.IDLE, program="/private/other")]:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError): health.launchd_service(bad, service)

    def services(self, *values):
        return dict(zip(health.SERVICES, values))

    def test_crash_loop_hidden_between_absent_process_listings_is_unknown(self):
        a, b = self.samples()
        a['services'] = self.services((None, None, 5), (None, None, 0))
        b['services'] = self.services((None, None, 7), (None, None, 0))
        with self.assertRaises(ValueError): health.assess(a, b)

    def test_launch_counts_admit_only_stable_idle_or_one_accounted_start(self):
        a, b = self.samples()
        a['services'] = b['services'] = self.services((None, None, 5), (None, None, 0))
        report = health.assess(a, b)
        self.assertTrue(report['admitted'])
        self.assertEqual(report['colorsyncCPUPercent'], 0)
        self.assertEqual(set(report), set(health.assess(*self.samples())))
        b = dict(b, services=self.services((40, .1, 6), (None, None, 0)))
        self.assertEqual(health.assess(a, b)['colorsyncCPUPercent'], 2)
        b = dict(b, services=self.services((40, 2.5, 6), (None, None, 0)))
        self.assertEqual(health.assess(a, b)['reasons'], ['colorsync_busy'])
        for old, new in [((None, None, 5), (40, 0., 7)), ((None, None, 5), (40, 0., 5)),
                         ((None, None, 5), (None, None, 4)), ((40, 1., 3), (40, 1., 4)),
                         ((40, 1., 3), (41, 1., 3)), ((40, 1., 3), (None, None, 3))]:
            a, b = self.samples()
            a['services'] = self.services(old, (None, None, 0))
            b['services'] = self.services(new, (None, None, 0))
            with self.subTest(old=old, new=new):
                with self.assertRaises(ValueError): health.assess(a, b)
        a, b = self.samples()
        del b['services'][health.SERVICES[1]]
        with self.assertRaises(ValueError): health.assess(a, b)

    def test_idle_service_does_not_mask_busy_running_peer(self):
        a, b = self.samples()
        a['services'] = self.services((None, None, 23), (2, 10., 1))
        b['services'] = self.services((None, None, 23), (2, 12.5, 1))
        self.assertEqual(health.assess(a, b)['reasons'], ['colorsync_busy'])

    def test_service_sample_reconciles_process_listings_with_both_exact_jobs(self):
        names, other = health.SERVICES, '1 00:00.01 /sbin/launchd'
        idle0, idle1 = self.record(self.IDLE, names[0]), self.record(self.NEVER_STARTED, names[1])

        def run(outputs):
            if len(outputs) == 4:
                outputs = outputs + outputs[1:3]
            calls = []

            def read(command, until):
                calls.append(command)
                expected = '/bin/ps' if len(calls) in (1, 4) else '/bin/launchctl'
                self.assertEqual(command[0], expected)
                if expected == '/bin/launchctl':
                    index = len(calls)-2 if len(calls) <= 3 else len(calls)-5
                    self.assertEqual(command[1:], ['print', 'system/' + health.launchd_label(names[index])])
                self.assertEqual(until, 99)
                value = outputs[len(calls)-1]
                if value is None:
                    raise ValueError('unreadable')
                return value
            with mock.patch.object(health, 'read_command', side_effect=read), \
                    mock.patch.object(health.time, 'monotonic', return_value=0):
                return health.service_sample(99)[1]

        self.assertEqual(run([other, idle0, idle1, other]), self.services((None, None, 23), (None, None, 0)))
        rows = lambda cpu: '\n'.join([other, f'533 {cpu} {names[0]}', f'546 00:01.00 {names[1]}'])
        self.assertEqual(run([rows('00:01.00'), self.running_record(533, names[0], 2),
                              self.running_record(546, names[1]), rows('00:01.50')]),
                         self.services((533, 1.5, 2), (546, 1., 1)))
        appeared, wrong = other + f'\n533 00:01.00 {names[0]}', other + f'\n534 00:01.00 {names[0]}'
        for outputs in [[other, idle0, idle1, appeared], [appeared, idle0, idle1, other],
                        [other, self.running_record(533, names[0]), idle1, appeared],
                        [wrong, self.running_record(533, names[0]), idle1, wrong],
                        [rows('00:02.00'), self.running_record(533, names[0]), self.running_record(546, names[1]), rows('00:01.00')],
                        [other, None], [None], ['malformed listing'], [other, idle0, 'system/ = {'],
                        [other, idle0, self.record(['state = not running', 'active count = 0', 'runs = 4',
                                                    'last terminating signal = Segmentation fault: 11'], names[1])]]:
            with self.subTest(outputs=outputs):
                with self.assertRaises(ValueError): run(outputs)

    def test_launch_and_exit_after_launchd_read_is_not_hidden_by_absent_process_rows(self):
        other = '1 00:00.01 /sbin/launchd'
        initial = [self.record(self.IDLE, name) for name in health.SERVICES]
        for changed in range(2):
            final = initial.copy()
            final[changed] = final[changed].replace('runs = 23', 'runs = 24')
            outputs = [other, *initial, other, *final]
            with mock.patch.object(health, 'read_command', side_effect=outputs), \
                    mock.patch.object(health.time, 'monotonic', return_value=0):
                with self.assertRaisesRegex(ValueError, 'service changed'):
                    health.service_sample(99)

    def test_snapshot_shares_one_budget_across_every_helper(self):
        clock = [0.]
        seen = []
        records = {health.launchd_label(name): self.record(self.IDLE, name) for name in health.SERVICES}

        def read(command, until):
            seen.append(until - clock[0])
            if until - clock[0] <= 0:
                raise ValueError('snapshot exceeded budget')
            clock[0] += .5
            if command[0] == '/usr/sbin/sysctl': return '1\n'
            if command[0] == '/usr/bin/vm_stat': return 'Swapins: 1.\nSwapouts: 2.\n'
            if command[0] == '/bin/ps': return '1 00:00.01 /sbin/launchd'
            return records[command[2].split('/', 1)[1]]
        with mock.patch.object(health.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(health, 'read_command', side_effect=read):
            with self.assertRaises(ValueError): health.snapshot()
        self.assertEqual(seen, [2.5, 2., 1.5, 1., .5, 0.])
        clock[0], seen[:] = 0., []
        with mock.patch.object(health.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(health, 'read_command', side_effect=read), \
                mock.patch.object(health, 'SNAPSHOT_BUDGET', 4.1):
            self.assertEqual(health.snapshot()['services'], self.services((None, None, 23), (None, None, 23)))
        with self.assertRaises(ValueError): health.read_command([sys.executable, '-c', 'pass'], until=0)

    def test_cpu_observation_time_excludes_asymmetric_trailing_launchd_latency(self):
        clock, calls, capture = [100.], [0], [0]

        def read(command, until):
            calls[0] += 1
            if command[0] == '/usr/sbin/sysctl': return '1\n'
            if command[0] == '/usr/bin/vm_stat': return 'Swapins: 0.\nSwapouts: 0.\n'
            if command[0] == '/bin/ps':
                clock[0] += .05
                # Forty percent of one CPU, continuously, independent of helper latency.
                cpu = .4 * clock[0]
                return f'1 00:00.00 /sbin/launchd\n533 00:{cpu:05.2f} {health.SERVICES[0]}'
            if capture[0] == 0 and calls[0] == 7:
                clock[0] += 2
            service = next(name for name in health.SERVICES
                           if command[-1].endswith(health.launchd_label(name)))
            return (self.running_record(533, service) if service == health.SERVICES[0]
                    else self.record(self.NEVER_STARTED, service))

        with mock.patch.object(health.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(health, 'read_command', side_effect=read):
            before = health.snapshot()
            self.assertAlmostEqual(before['at'], 100.1)
            # The first final validation takes two seconds, still inside the snapshot budget.
            clock[0] += 5
            capture[0], calls[0] = 1, 0
            after = health.snapshot()
        report = health.assess(before, after)
        self.assertEqual(report['intervalSeconds'], 7.1)
        self.assertTrue(report['admitted'])
        self.assertEqual(report['colorsyncCPUPercent'], 40)

    def test_main_paces_from_observation_with_slow_captures_and_sleep_overshoot(self):
        clock, captures, sleeps = [100.], [0], []
        before, _ = self.samples()

        def snapshot():
            result = copy.deepcopy(before)
            if captures[0] == 0:
                result['at'] = clock[0]
                clock[0] += 2.45  # Trailing validation, within the 2.5-second budget.
            else:
                clock[0] += 2.45  # Next capture's work before observing process CPU.
                result['at'] = clock[0]
            captures[0] += 1
            return result

        def sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds + .2  # Scheduling may overshoot the requested sleep.

        output = io.StringIO()
        with mock.patch.object(health.sys, 'platform', 'darwin'), \
                mock.patch.object(health.sys, 'argv', ['host-health.py']), \
                mock.patch.object(health.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(health.time, 'time', return_value=200000), \
                mock.patch.object(health.time, 'sleep', side_effect=sleep), \
                mock.patch.object(health, 'read_command', return_value='{ sec = 1, usec = 0 }'), \
                mock.patch.object(health, 'windowserver_diagnostics', return_value=0), \
                mock.patch.object(health, 'windowserver_timeouts', return_value=0), \
                mock.patch.object(health, 'snapshot', side_effect=snapshot), \
                mock.patch.object(health.sys, 'stdout', output):
            self.assertEqual(health.main(), 0)
        self.assertEqual(captures[0], 2)
        self.assertAlmostEqual(sleeps[0], 2.55)
        report = json.loads(output.getvalue())
        self.assertTrue(report['admitted'])
        self.assertEqual(report['intervalSeconds'], 7.65)

    def test_busy_services_pressure_and_current_swap_refuse(self):
        a, b = self.samples()
        service = health.SERVICES[0]
        b['services'][service] = (a['services'][service][0], 12.5, 1)
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
            if field == 'restart': b['services'][name] = (99, 10, 1)
            if field == 'cpu_reset': b['services'][name] = (1, 9, 1)
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
