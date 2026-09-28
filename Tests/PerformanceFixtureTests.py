#!/usr/bin/env python3
"""Execute fixture JavaScript in a fake DOM; never launch an app or create a display."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import unittest

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
