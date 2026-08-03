#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.13.*"
# dependencies = ["textual>=1.0"]
# ///
"""vm-tui.py — interactive console for the friend VMs.

Lists every VM with its state, IP, CPUs, RAM and disk usage, and starts or
stops them so you never have to remember a virsh incantation.

    ./vm-tui.py

uv reads the metadata block above, builds an isolated environment on first
run and caches it — nothing to install by hand, nothing added to the system
Python. Keys are shown in the footer.
"""
from __future__ import annotations

import os
import subprocess

from textual import work
from textual.app import App, ComposeResult
from textual.containers import Grid
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Footer, Header, Label

VIRSH = ["virsh", "--connect", "qemu:///system"]
HERE = os.path.dirname(os.path.realpath(__file__))
REFRESH_SECONDS = 5.0

COLUMNS = ("NAME", "STATE", "IP", "VCPU", "RAM cur/max", "DISK")


def virsh(*args: str, timeout: int = 60) -> tuple[bool, str]:
    """Run virsh; return (ok, output). Never raises — errors become messages."""
    try:
        p = subprocess.run(VIRSH + list(args), capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, f"timed out: virsh {' '.join(args)}"
    except FileNotFoundError:
        return False, "virsh not found — is libvirt installed?"
    out = (p.stdout or "").strip() or (p.stderr or "").strip()
    return p.returncode == 0, out


def human(n: int | None) -> str:
    if n is None:
        return "-"
    v = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if v < 1024:
            return f"{v:.0f}{unit}" if unit in "BK" else f"{v:.1f}{unit}"
        v /= 1024
    return f"{v:.1f}P"


def disk_usage(name: str) -> int | None:
    """Actual thin-provisioned size on disk, not the 256 G virtual size."""
    try:
        return os.stat(os.path.join(HERE, f"{name}.qcow2")).st_blocks * 512
    except OSError:
        return None


def fetch_vms() -> tuple[list[dict] | None, str | None]:
    ok, out = virsh("list", "--all", "--name")
    if not ok:
        return None, out
    vms: list[dict] = []
    for name in (line.strip() for line in out.splitlines()):
        if not name:
            continue
        vm = {"name": name, "state": "?", "ip": "-", "vcpu": "-",
              "cur": None, "max": None, "disk": disk_usage(name)}
        ok, info = virsh("dominfo", name)
        if ok:
            for line in info.splitlines():
                key, _, val = line.partition(":")
                key, val = key.strip(), val.strip()
                if key == "State":
                    vm["state"] = val
                elif key == "CPU(s)":
                    vm["vcpu"] = val
                elif key == "Used memory":
                    vm["cur"] = int(val.split()[0]) * 1024
                elif key == "Max memory":
                    vm["max"] = int(val.split()[0]) * 1024
        if vm["state"] == "running":
            ok, addr = virsh("domifaddr", name)
            if ok:
                for line in addr.splitlines():
                    if "ipv4" in line:
                        vm["ip"] = line.split()[3].split("/")[0]
                        break
        vms.append(vm)
    return vms, None


class ConfirmForceOff(ModalScreen[bool]):
    """Force off is unclean — make it a deliberate choice, not a keystroke."""

    CSS = """
    ConfirmForceOff { align: center middle; }
    #box {
        grid-size: 2; grid-gutter: 1 2; grid-rows: 1fr 3;
        padding: 1 2; width: 62; height: 11; border: thick $error;
        background: $surface;
    }
    #question { column-span: 2; height: 1fr; width: 1fr; content-align: center middle; }
    """

    def __init__(self, name: str) -> None:
        super().__init__()
        self.vm_name = name

    def compose(self) -> ComposeResult:
        with Grid(id="box"):
            yield Label(
                f"Force off {self.vm_name}?\n\n"
                "This is like pulling the power cord — the guest gets no\n"
                "chance to flush its disks. Prefer 'h' for a clean shutdown.",
                id="question")
            yield Button("Force off", variant="error", id="yes")
            yield Button("Cancel", variant="primary", id="no")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


class VMApp(App):
    TITLE = "friend VMs"
    CSS = """
    DataTable { height: 1fr; }
    DataTable > .datatable--cursor { background: $accent; color: $text; }
    """

    BINDINGS = [
        ("s", "start", "Start"),
        ("h", "shutdown", "Shutdown"),
        ("f", "force_off", "Force off"),
        ("c", "console", "Console"),
        ("r", "refresh", "Refresh"),
        ("q", "quit", "Quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.vms: list[dict] = []

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(cursor_type="row", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = HERE
        table = self.query_one(DataTable)
        table.add_columns(*COLUMNS)
        self.refresh_vms()
        self.set_interval(REFRESH_SECONDS, self.refresh_vms)

    # ---- data --------------------------------------------------------------
    @work(thread=True, exclusive=True, group="refresh")
    def refresh_vms(self) -> None:
        vms, err = fetch_vms()
        if err:
            self.call_from_thread(self.notify, err, severity="error", timeout=8)
            return
        self.call_from_thread(self.populate, vms or [])

    def populate(self, vms: list[dict]) -> None:
        table = self.query_one(DataTable)
        keep = table.cursor_row
        self.vms = vms
        table.clear()
        for vm in vms:
            ram = "-"
            if vm["cur"] is not None and vm["max"] is not None:
                ram = f"{human(vm['cur'])}/{human(vm['max'])}"
            colour = {"running": "green", "paused": "yellow"}.get(vm["state"], "yellow")
            table.add_row(vm["name"], f"[{colour}]{vm['state']}[/]", vm["ip"],
                          vm["vcpu"], ram, human(vm["disk"]))
        if vms:
            table.move_cursor(row=min(keep, len(vms) - 1))

    @property
    def selected(self) -> dict | None:
        table = self.query_one(DataTable)
        if not self.vms or table.cursor_row is None:
            return None
        if 0 <= table.cursor_row < len(self.vms):
            return self.vms[table.cursor_row]
        return None

    # ---- actions -----------------------------------------------------------
    @work(thread=True, group="action")
    def run_virsh(self, action: str, name: str) -> None:
        ok, out = virsh(action, name)
        msg = out.splitlines()[0] if out else f"{action} {name}: ok"
        self.call_from_thread(
            self.notify, msg, severity="information" if ok else "error",
            timeout=6 if ok else 10)
        self.refresh_vms()

    def action_start(self) -> None:
        vm = self.selected
        if not vm:
            return
        if vm["state"] == "running":
            self.notify(f"{vm['name']} is already running")
        else:
            self.run_virsh("start", vm["name"])

    def action_shutdown(self) -> None:
        vm = self.selected
        if not vm:
            return
        if vm["state"] != "running":
            self.notify(f"{vm['name']} is not running")
            return
        # Shutdown is an ACPI request. A guest that has not finished booting
        # has nothing listening for it yet, so the request is silently lost —
        # say so rather than leaving the VM looking stuck.
        if vm["ip"] == "-":
            self.notify(
                f"{vm['name']} is still booting (no IP yet). ACPI shutdown may "
                "be ignored — press 'h' again once it has an address.",
                severity="warning", timeout=10)
        self.run_virsh("shutdown", vm["name"])

    def action_force_off(self) -> None:
        vm = self.selected
        if not vm:
            return
        if vm["state"] != "running":
            self.notify(f"{vm['name']} is not running")
            return

        def done(confirmed: bool | None) -> None:
            if confirmed:
                self.run_virsh("destroy", vm["name"])

        self.push_screen(ConfirmForceOff(vm["name"]), done)

    def action_console(self) -> None:
        vm = self.selected
        if not vm:
            return
        if vm["state"] != "running":
            self.notify(f"{vm['name']} is not running — start it first")
            return
        with self.suspend():
            print(f"\nAttaching to {vm['name']}. Press Ctrl+] to detach.\n")
            subprocess.call(VIRSH + ["console", vm["name"]])
            input("\n[detached — press Enter to return to the list] ")

    def action_refresh(self) -> None:
        self.refresh_vms()


if __name__ == "__main__":
    VMApp().run()
