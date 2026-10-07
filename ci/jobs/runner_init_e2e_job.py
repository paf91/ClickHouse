"""Runs `runner-init.py` end to end on a faked host and asserts its job loop.

The script runs unmodified as `__main__`. Instance metadata, boto3, `df`,
`sudo`, its `bash -euxo pipefail` scripts and the actions-runner `config.sh` /
`run.sh` are fakes that append to one event log, so nothing is provisioned,
registered, uploaded or terminated. Each scenario checks the recorded sequence
of disk checks, jobs, Docker teardowns and terminations.
"""

import http.server
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import uuid
from dataclasses import dataclass
from pathlib import Path

from praktika.result import Result
from praktika.utils import Utils

SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "praktika/infrastructure/runner/runner-init.py"
)
# Not configurable in `runner-init.py` on Linux.
RUNNER_HOME = Path("/home/ubuntu/actions-runner")
GIB = 1024 * 1024  # in `df -k` blocks
TOTAL = 100 * GIB

FAKE_DF = r"""#!/bin/sh
printf 'df\t%s\n' "$*" >> "$RUNNER_INIT_E2E/events"
avail=$(cat "$RUNNER_INIT_E2E/avail")
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/e2e $RUNNER_INIT_E2E_TOTAL $((RUNNER_INIT_E2E_TOTAL - avail)) $avail 0% /"
"""

# Runs only the runner's own commands; anything else (`shutdown`) is just recorded.
FAKE_SUDO = r"""#!/bin/sh
printf 'sudo\t%s\n' "$*" >> "$RUNNER_INIT_E2E/events"
if [ "$1" = "-u" ]; then shift 2; fi
case "$1" in
    bash|env|./config.sh|./run.sh) exec "$@" ;;
esac
"""

# `run_bash` scripts are saved and not executed.
FAKE_BASH = r"""#!/bin/sh
if [ "$*" != "-euxo pipefail" ]; then exec /bin/bash "$@"; fi
f="$RUNNER_INIT_E2E/scripts/$(ls "$RUNNER_INIT_E2E/scripts" | wc -l).sh"
cat > "$f"
printf 'bash\t%s\n' "$f" >> "$RUNNER_INIT_E2E/events"
"""

FAKE_CONFIG_SH = r"""#!/bin/sh
printf 'config.sh\t%s\n' "$*" >> "$RUNNER_INIT_E2E/events"
"""

# A job grows the rootfs by RUNNER_INIT_E2E_JOB_USES blocks.
FAKE_RUN_SH = r"""#!/bin/sh
printf 'run.sh\t\n' >> "$RUNNER_INIT_E2E/events"
echo $(( $(cat "$RUNNER_INIT_E2E/avail") - RUNNER_INIT_E2E_JOB_USES )) > "$RUNNER_INIT_E2E/avail"
"""

FAKE_BOTO3 = r'''import io
import json
import os
from pathlib import Path

_STATE = Path(os.environ["RUNNER_INIT_E2E"])
_CLOUDWATCH_CONFIG = {"logs": {"files": [{"file_path": "/var/log/cloud-init-output.log"}]}}


def _event(detail):
    with open(_STATE / "events", "a") as f:
        f.write(f"aws\t{detail}\n")


class _Client:
    def get_parameter(self, Name, WithDecryption=True):
        _event(f"ssm get_parameter {Name}")
        value = "e2e-token"
        if Name == "AmazonCloudWatch-github-runners":
            value = json.dumps(_CLOUDWATCH_CONFIG)
        return {"Parameter": {"Value": value}}

    def get_object(self, Bucket, Key):
        # One version per call; the last one repeats.
        versions = (_STATE / "remote_versions").read_text().split()
        (_STATE / "remote_versions").write_text(" ".join(versions[1:] or versions))
        _event(f"s3 get_object {Key}")
        return {"Body": io.BytesIO(f"    version: int = {versions[0]}\n".encode())}

    def upload_file(self, Filename, Bucket, Key):
        _event(f"s3 upload_file {Key}")

    def terminate_instances(self, InstanceIds):
        _event(f"ec2 terminate_instances {' '.join(InstanceIds)}")

    def terminate_instance_in_auto_scaling_group(self, InstanceId, ShouldDecrementDesiredCapacity):
        _event(f"autoscaling terminate_instance_in_auto_scaling_group {InstanceId}")


class _Instance:
    tags = [{"Key": "github:runner-type", "Value": "e2e-runner"}]


class _Resource:
    def Instance(self, instance_id):
        return _Instance()


def client(service, region_name=None):
    return _Client()


def resource(service, region_name=None):
    return _Resource()


class _Session:
    def __init__(self, region_name=None):
        pass

    def client(self, service, region_name=None):
        return _Client()


class session:
    Session = _Session
'''

METADATA = {
    "instance-id": "i-0e2e",
    "instance-type": "e2e.large",
    "placement/region": "us-east-1",
}


class _Metadata(http.server.BaseHTTPRequestHandler):
    """Instance metadata service, reached through `http_proxy`."""

    def do_GET(self):
        body = METADATA.get(self.path.split("/latest/meta-data/", 1)[-1])
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args):
        pass


@dataclass
class Scenario:
    name: str
    environment: str
    free: int
    job_uses: int
    expected_steps: list
    expected_output: str
    # Remote init script versions relative to the local one, one per upgrade check.
    remote_versions: tuple = (0,)


SCENARIOS = [
    Scenario(
        name="macOS refuses a job when the host boots with less than 20 GiB free",
        environment="macos",
        free=19 * GIB,
        job_uses=GIB,
        expected_steps=["disk-check"],
        expected_output="blocks on rootfs",
    ),
    Scenario(
        name="macOS skips the Docker teardown and checks the disk before the next job",
        environment="macos",
        free=60 * GIB,
        job_uses=GIB,
        remote_versions=(0, 1),
        expected_steps=[
            "disk-check",
            "upgrade-check",
            "register",
            "job",
            "disk-check",
            "disk-check",
            "upgrade-check",
        ],
        expected_output="exiting to re-provision",
    ),
    Scenario(
        name="macOS takes a job with exactly 20 GiB free and leaves the rotation below it",
        environment="macos",
        free=20 * GIB,
        job_uses=1,
        expected_steps=["disk-check", "upgrade-check", "register", "job", "disk-check"],
        expected_output="blocks on rootfs",
    ),
    Scenario(
        name="Linux takes a job with 10 GiB free and tears Docker down after it",
        environment="production",
        free=10 * GIB,
        job_uses=GIB,
        expected_steps=[
            "disk-check",
            "register",
            "job",
            "disk-check",
            "docker-teardown",
            "terminate",
        ],
        expected_output="Runner completed max number of jobs",
    ),
    Scenario(
        name="Linux refuses a job below 5% free",
        environment="production",
        free=4 * GIB,
        job_uses=GIB,
        expected_steps=["disk-check", "terminate"],
        expected_output="4% of free space on rootfs",
    ),
]


def write_executable(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(0o755)


def local_version() -> int:
    for line in SCRIPT.read_text().splitlines():
        if line.startswith("    version: int = "):
            return int(line.split("=", 1)[1])
    raise RuntimeError(f"No version line in {SCRIPT}")


def steps(state: Path) -> list:
    result = []
    for line in (state / "events").read_text().splitlines():
        source, _, detail = line.partition("\t")
        if source == "df" and detail == "-k /":
            result.append("disk-check")
        elif source == "config.sh" and not detail.startswith("remove"):
            result.append("register")
        elif source == "run.sh":
            result.append("job")
        elif source == "bash" and "docker kill" in Path(detail).read_text():
            result.append("docker-teardown")
        elif source == "aws" and detail.startswith("s3 get_object"):
            result.append("upgrade-check")
        elif source == "aws" and detail.startswith(("ec2 terminate", "autoscaling")):
            result.append("terminate")
    return result


def render(step_list: list) -> str:
    shown = " -> ".join(step_list[:20])
    return shown if len(step_list) <= 20 else f"{shown} -> ... ({len(step_list)} steps)"


def kill_leftovers(token: str) -> None:
    # The Linux monitor runs in its own session, so find it by environment.
    needle = f"RUNNER_INIT_E2E_RUN={token}".encode()
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if needle in (proc / "environ").read_bytes().split(b"\0"):
                os.kill(int(proc.name), signal.SIGKILL)
        except OSError:
            pass


def run_scenario(scenario: Scenario, proxy: str, version: int) -> Result:
    stopwatch = Utils.Stopwatch()
    state = Path(tempfile.mkdtemp(prefix="runner-init-e2e-"))
    bin_dir = state / "bin"
    boto3_dir = state / "py" / "boto3"
    for d in (state / "home", state / "scripts", bin_dir, boto3_dir):
        d.mkdir(parents=True)
    write_executable(bin_dir / "df", FAKE_DF)
    write_executable(bin_dir / "sudo", FAKE_SUDO)
    write_executable(bin_dir / "bash", FAKE_BASH)
    (boto3_dir / "__init__.py").write_text(FAKE_BOTO3)
    (state / "events").write_text("")
    (state / "avail").write_text(str(scenario.free))
    (state / "remote_versions").write_text(
        " ".join(str(version + v) for v in scenario.remote_versions)
    )
    RUNNER_HOME.mkdir(parents=True)
    write_executable(RUNNER_HOME / "config.sh", FAKE_CONFIG_SH)
    write_executable(RUNNER_HOME / "run.sh", FAKE_RUN_SH)

    token = uuid.uuid4().hex
    env = {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HOME": str(state / "home"),
        "PYTHONPATH": str(state / "py"),
        "http_proxy": proxy,
        "no_proxy": "",
        "RUNNER_INIT_E2E": str(state),
        "RUNNER_INIT_E2E_TOTAL": str(TOTAL),
        "RUNNER_INIT_E2E_JOB_USES": str(scenario.job_uses),
        "RUNNER_INIT_E2E_RUN": token,
    }
    problems = []
    try:
        with open(state / "output", "w") as output:
            proc = subprocess.run(
                [sys.executable, str(SCRIPT), "--environment", scenario.environment],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=120,
            )
        if proc.returncode == 0:
            problems.append("runner-init exited with 0")
    except subprocess.TimeoutExpired:
        problems.append("runner-init did not exit in 120 s")
    finally:
        kill_leftovers(token)
        shutil.rmtree(RUNNER_HOME, ignore_errors=True)

    observed = steps(state)
    output = (state / "output").read_text()
    if observed != scenario.expected_steps:
        problems.append(
            f"steps: {render(observed)}, expected: {render(scenario.expected_steps)}"
        )
    if scenario.expected_output not in output:
        problems.append(f"no '{scenario.expected_output}' in the output")
    marker = state / "home" / ".clickhouse-ci-runner-init-version"
    if scenario.environment == "macos" and marker.exists():
        problems.append("the provisioning marker survived the exit")

    info = f"steps: {render(observed)}"
    if problems:
        info = "\n".join(problems + [info, "output tail:", *output.splitlines()[-30:]])
    shutil.rmtree(state, ignore_errors=True)
    return Result(
        name=scenario.name,
        status=Result.Status.FAIL if problems else Result.Status.OK,
        start_time=stopwatch.start_time,
        duration=stopwatch.duration,
        info=info,
    )


def main():
    # The script under test writes RUNNER_HOME and /tmp the way a real runner does.
    if not Path("/.dockerenv").exists():
        sys.exit("Refusing to run outside a container")
    if RUNNER_HOME.exists():
        sys.exit(f"Refusing to run: {RUNNER_HOME} already exists")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Metadata)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    proxy = f"http://127.0.0.1:{server.server_address[1]}"
    version = local_version()

    results = [run_scenario(s, proxy, version) for s in SCENARIOS]
    for r in results:
        print(f"[{r.status}] {r.name}\n{r.info}\n")
    Result.create_from(results=results).complete_job()


if __name__ == "__main__":
    main()
