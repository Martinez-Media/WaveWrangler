#!/usr/bin/env python3
"""Exercise required wrapper gates with stand-ins; no product tests or app launch."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory(prefix="ww-required-passes-") as directory:
        root = Path(directory)
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copyfile(ROOT / "scripts/test.sh", scripts / "test.sh")
        (scripts / "test-ui-plans.py").write_text("")
        (scripts / "test-whisper-timestamps.sh").write_text("exit 0\n")
        swift = root / "swift"
        swift.write_text("""#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
selector = args[args.index('--filter') + 1] if '--filter' in args else 'ordinary'
if os.environ.get('WW_FAIL_SELECTOR') == selector:
    print('Required pass failed', file=sys.stderr)
    sys.exit(2)
elif os.environ.get('WW_EMPTY_SELECTOR') == selector:
    print('Test run with 0 tests in 0 suites passed after 0.001 seconds.')
elif os.environ.get('WW_SKIP_SELECTOR') == selector:
    print('Test ' + selector + '() skipped')
    print('Test run with 1 test in 1 suite passed after 0.001 seconds.')
elif os.environ.get('WW_SUMMARY_SELECTOR') == selector:
    print('Test run with 1 test in 1 suite passed after 0.001 seconds.')
elif os.environ.get('WW_NAMED_SELECTOR') == selector:
    print('Test "generated named regression" passed after 0.001 seconds.')
else:
    print('Test lightweight() passed after 0.001 seconds.')
    for suite in ['Estimator scenarios', 'Estimator calibration',
                  'Automatic alignment synthetic reliability', 'Automatic alignment pipeline reliability']:
        print('Suite "' + suite + '" passed')
    for test in ['calibrationAgainstPlantedTruth', 'detectionFloor', 'silenceBesideAJumpNeverBridgesIt',
                 'calibrationSplitMeetsEveryObjectiveGate', 'calibrationSplitMeetsEveryGate', selector]:
        print('Test ' + test + '() passed after 0.001 seconds.')
    print('Test "peaks well under 1 GiB" passed')
""")
        swift.chmod(0o755)
        logs = root / "logs"
        logs.mkdir()
        environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", CI="true", TMPDIR=str(logs),
                           WW_JOBS="2", WW_TEST_WORKERS="2")
        cases = [(None, None, 0), ("WW_EMPTY_SELECTOR", "ordinary", 1),
                 ("WW_SKIP_SELECTOR", "ordinary", 1),
                 ("WW_SUMMARY_SELECTOR", "ordinary", 1),
                 ("WW_NAMED_SELECTOR", "ordinary", 0)]
        timing = ["editToQuiescentCheckpointLatency", "publicationPipelineCost",
                  "hundredShowsThousandSourceRefs", "estimatorThroughputBenchmark",
                  "renderFamilyPeakAndThroughput"]
        cases += [(mode, selector, 1) for selector in timing
                  for mode in ("WW_EMPTY_SELECTOR", "WW_SKIP_SELECTOR")]
        cases += [("WW_FAIL_SELECTOR", selector, 2) for selector in ["ordinary"] + timing]
        for mode, selector, expected in cases:
            env = environment.copy()
            if mode:
                env[mode] = selector
            result = subprocess.run(["bash", str(scripts / "test.sh"), "--package-only"],
                                    env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == expected, (mode, selector, result.stdout, result.stderr)
            if expected == 1:
                assert ("no test executed and passed" if selector == "ordinary" else
                        f"{selector} did not run and pass") in result.stderr
            assert not list(logs.iterdir()), ("Temporary logs not cleaned", mode, selector)
        print(f"Required wrapper gates: {len(cases)} controls passed; product tests were stubbed")


if __name__ == "__main__":
    main()
