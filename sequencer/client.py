"""
sequencer/client.py — Lab PC ↔ DE10-Nano SSH interface.

Uses paramiko to connect to the HPS, upload the JSON config via SFTP,
and run pulse_sequencer_control.py commands remotely.
"""
from __future__ import annotations

import json
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .api import FPGAConfig


class PulseSequencer:
    """
    Lab PC interface to the DE10-Nano pulse sequencer.

    Maintains a persistent SSH connection and SFTP session.
    Use as a context manager for automatic cleanup::

        with PulseSequencer("de10nano.local") as ps:
            ps.configure(ro_cal)
            ps.start()
            # ...acquire data...
            ps.stop()
    """

    REMOTE_SCRIPT = "/home/root/pulse_sequencer_control.py"
    REMOTE_CONFIG = "/tmp/ps_config.json"

    def __init__(
        self,
        host:     str,
        username: str        = "root",
        key_path: str | None = None,
        password: str | None = None,
    ):
        try:
            import paramiko
        except ImportError:
            raise ImportError(
                "paramiko is required for SSH connectivity: "
                "uv add paramiko  (or  pip install paramiko)"
            )

        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        connect_kwargs: dict = dict(username=username)
        if key_path:
            connect_kwargs["key_filename"] = key_path
        elif password:
            connect_kwargs["password"] = password

        self._client.connect(host, **connect_kwargs)
        self._sftp = self._client.open_sftp()

    # ── Private helpers ─────────────────────────────────────────────────────

    def _exec(self, cmd: str) -> str:
        """Run a command on the HPS; raise RuntimeError if it fails."""
        _, stdout, stderr = self._client.exec_command(cmd)
        out = stdout.read().decode()
        err = stderr.read().decode()
        rc  = stdout.channel.recv_exit_status()
        if rc != 0:
            raise RuntimeError(
                f"Remote command failed (rc={rc}):\n  cmd: {cmd}\n  stderr: {err.strip()}"
            )
        return out

    def _upload_config(self, config: "FPGAConfig") -> None:
        """Serialize config to JSON and SFTP to REMOTE_CONFIG."""
        data = json.dumps(config.to_hps_config(), indent=2)
        with self._sftp.open(self.REMOTE_CONFIG, "w") as f:
            f.write(data)

    # ── Public API ──────────────────────────────────────────────────────────

    def configure(self, config: "FPGAConfig") -> None:
        """Upload config and write it to the FPGA (does not start)."""
        self._upload_config(config)
        self._exec(
            f"python3 {self.REMOTE_SCRIPT} configure {self.REMOTE_CONFIG}"
        )

    def start(self) -> None:
        """Start the sequencer running the last uploaded config."""
        self._exec(
            f"python3 {self.REMOTE_SCRIPT} start-super {self.REMOTE_CONFIG}"
        )

    def stop(self) -> None:
        """Send a stop strobe to the sequencer."""
        self._exec(f"python3 {self.REMOTE_SCRIPT} stop")

    def status(self) -> dict:
        """
        Query sequencer status.  Returns a dict of key→value strings
        parsed from the 'status' command output.
        """
        out = self._exec(f"python3 {self.REMOTE_SCRIPT} status")
        result: dict[str, str] = {}
        for line in out.splitlines():
            if ":" in line:
                key, _, val = line.partition(":")
                result[key.strip()] = val.strip()
        return result

    def wait(self, poll: float = 0.05) -> None:
        """Block until the sequencer finishes (finite super_cycle_repeats)."""
        self._exec(f"python3 {self.REMOTE_SCRIPT} wait {poll}")

    # ── Context manager ──────────────────────────────────────────────────────

    def close(self) -> None:
        """Close SFTP and SSH connections."""
        try:
            self._sftp.close()
        except Exception:
            pass
        try:
            self._client.close()
        except Exception:
            pass

    def __enter__(self) -> "PulseSequencer":
        return self

    def __exit__(self, *args) -> None:
        self.close()
