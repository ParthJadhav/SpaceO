#!/usr/bin/env python3
"""Execute fixture JavaScript in a fake DOM; never launch an app or create a display."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('performance_live', ROOT / 'scripts/performance-live.py')
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)

RUN_SCRIPT = r'''
const vm = require('node:vm');
const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const queue = [], timers = [], reports = [], scrolls = [], rows = [];
const box = {style:{}};
const context = vm.createContext({box,
  document: {visibilityState:input.visibility,
    createElement:()=>({}), body:{append:row=>rows.push(row)}},
  requestAnimationFrame:fn=>queue.push(fn),
  scrollTo:(x,y)=>scrolls.push([x,y]),
  setInterval:fn=>timers.push(fn),
  navigator:{sendBeacon:(url,data)=>reports.push({url,data:JSON.parse(data)})}
});
vm.runInContext(input.script, context, {timeout:1000});
for (let i=0;i<3;i++) {
  const batch=queue.splice(0);
  for(const fn of batch) fn();
}
for(const fn of timers) fn();
process.stdout.write(JSON.stringify({animation:box.style.animation,scrolls,rows:rows.length,reports}));
'''

class Fixture(unittest.TestCase):
    def test_focused_motion_keeps_static_baseline_and_explicit_coverage(self):
        self.assertEqual(live.viewer_modes({}), ("static", "animated", "scrolling"))
        for mode in ("animated", "scrolling"):
            self.assertEqual(live.viewer_modes({"SPACEO_PERF_VIEWER_MOTION": mode}), ("static", mode))

    def test_invalid_or_inapplicable_motion_is_refused_before_live_work(self):
        for mode in ("", "static", "animated,scrolling", "unknown"):
            with self.assertRaises(ValueError):
                live.viewer_modes({"SPACEO_PERF_VIEWER_MOTION": mode})
        for workload in ("SPACEO_PERF_DAEMON_ONLY", "SPACEO_PERF_NATIVE_PROBE"):
            with self.assertRaises(ValueError):
                live.viewer_modes({"SPACEO_PERF_VIEWER_MOTION": "scrolling", workload: "1"})

    def test_safety_stop_does_not_depend_on_logging(self):
        class Suspended(Exception): pass
        with patch.object(live.os, 'write', side_effect=OSError('closed log')), \
             patch.object(live.os, 'kill', side_effect=Suspended) as stop:
            with self.assertRaises(Suspended): live.safety_stop()
            stop.assert_called_once_with(live.os.getpid(), live.signal.SIGSTOP)

    def test_cleanup_errors_retain_unverified_owner_even_when_reports_fail(self):
        with patch.object(live, 'safety_stop') as stop:
            for error in (OSError('disk full'), TimeoutError('shutdown'), KeyboardInterrupt()):
                with self.assertRaises(type(error)):
                    with live.retain_on_cleanup_failure(lambda: False):
                        raise error
            self.assertEqual(stop.call_count, 3)
            with self.assertRaises(OSError):
                with live.retain_on_cleanup_failure(lambda: True):
                    raise OSError('final report failed after verified teardown')
            self.assertEqual(stop.call_count, 3)

    def test_failed_sampler_is_not_successful_resource_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'samples'
            path.write_text('{"elapsedSeconds":0}\n{"elapsedSeconds":14}\n')
            child, target = Mock(), Mock()
            child.poll.return_value = 1
            target.poll.return_value = None
            self.assertTrue(live.sampler_completed_early(child, target, 'viewer', path, 15))
            self.assertTrue(live.sampler_completed_early(child, target, 'probe', path, 15))
            target.poll.return_value = 0
            self.assertFalse(live.sampler_completed_early(child, target, 'probe', path, 15))
            self.assertTrue(live.sampler_completed_early(child, target, 'probe', path, 20))
            child.poll.return_value = 0
            self.assertTrue(live.sampler_completed_early(child, target, 'daemon', path, 15))
            child.poll.return_value = None
            self.assertFalse(live.sampler_completed_early(child, target, 'daemon', path, 15))

    def evaluate(self, mode, visibility='visible'):
        page = live.fixture_markup('/?' + mode).decode()
        script = re.search(r'<script>(.*?)</script>', page, re.S).group(1)
        result = subprocess.run(['node', '-e', RUN_SCRIPT],
            input=json.dumps(dict(script=script, visibility=visibility)),
            text=True, capture_output=True, check=True, timeout=5)
        return json.loads(result.stdout)

    def test_modes_drive_expected_work_and_report_frame_progress(self):
        for mode in ('static','animated','scrolling'):
            with self.subTest(mode=mode):
                result = self.evaluate(mode)
                self.assertEqual(result['rows'],100)
                self.assertEqual(bool(result.get('animation')),mode == 'animated')
                self.assertEqual(bool(result['scrolls']),mode == 'scrolling')
                self.assertEqual(result['reports'],[dict(url='/fixture-health',data=dict(
                    mode=mode,visibility='visible',frames=3))])

    def test_hidden_document_and_unknown_mode_are_explicit(self):
        result = self.evaluate('unexpected', 'hidden')
        self.assertEqual(result['reports'][0]['data'],dict(mode='static',visibility='hidden',frames=3))
        self.assertFalse(result.get('animation'))

if __name__ == '__main__': unittest.main()
