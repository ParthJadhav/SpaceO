#!/usr/bin/env node
import { pathToFileURL } from 'node:url';

// Classify only the evidence actually supplied. A missing callback is not a measured drop.
export function classifyPresentation(sample) {
  const counts = ['submittedWork', 'gpuCompletions', 'gpuFailures', 'presentationCallbacks'];
  for (const key of counts) {
    if (!Number.isSafeInteger(sample[key]) || sample[key] < 0 || sample[key] > 10000) {
      throw new Error(`${key} must be an integer from 0 through 10000`);
    }
  }
  const times = sample.nonzeroPresentationTimestamps;
  if (!Array.isArray(times) || times.length > sample.presentationCallbacks ||
      times.some(time => !Number.isFinite(time) || time <= 0)) {
    throw new Error('presentation timestamps must be bounded positive finite values');
  }
  if (sample.gpuCompletions > sample.submittedWork || sample.gpuFailures > sample.gpuCompletions ||
      sample.presentationCallbacks > sample.submittedWork) throw new Error('inconsistent evidence counts');
  const sorted = [...times].sort((a, b) => a - b);
  const complete = sample.submittedWork >= 2 && sample.gpuCompletions === sample.submittedWork &&
    sample.gpuFailures === 0 && sorted.length === sample.submittedWork &&
    sorted.every((time, i) => i === 0 || time > sorted[i - 1]);
  const callbackFPS = complete ? (sorted.length - 1) / (sorted.at(-1) - sorted[0]) : null;
  return {
    schemaVersion: 1,
    submittedWork: sample.submittedWork,
    gpuCompletions: sample.gpuCompletions,
    gpuFailures: sample.gpuFailures,
    presentationCallbacks: sample.presentationCallbacks,
    nonzeroPresentationTimestampCount: times.length,
    outstandingGPUCompletions: sample.submittedWork - sample.gpuCompletions,
    presentationVerification: complete ? 'timestamps_observed' : 'unverified',
    presentationTimestampFPS: Number.isFinite(callbackFPS) ? callbackFPS : null,
    displayFPS: null,
    droppedFrames: null,
    captureFreshness: 'unknown',
    visibility: 'unknown',
    nextAction: complete ? 'continue_functional_tests' : 'continue_functional_tests; repeat_probe_only_after_environment_change',
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    let input = '';
    for await (const chunk of process.stdin) {
      input += chunk;
      if (Buffer.byteLength(input) > 128 * 1024) throw new Error('probe evidence exceeds 128 KiB');
    }
    console.log(JSON.stringify(classifyPresentation(JSON.parse(input))));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
