"""Desktop app: open a gear pump STEP file, extract the geometry, export for Amesim.

    python run_app.py            (or: python -m gearpump.gui)
"""

import sys
import traceback
from pathlib import Path

import numpy as np
from shapely import affinity

from PySide6.QtCore import QObject, QThread, Qt, Signal
from PySide6.QtWidgets import (
    QApplication, QComboBox, QDoubleSpinBox, QFileDialog, QFormLayout, QGroupBox,
    QHBoxLayout, QLabel, QMainWindow, QMessageBox, QPlainTextEdit, QPushButton,
    QSlider, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget,
    QVBoxLayout, QWidget)

import matplotlib
matplotlib.use("QtAgg")
from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg, NavigationToolbar2QT  # noqa: E402
from matplotlib.figure import Figure  # noqa: E402

from .analysis import Settings, analyse_pump  # noqa: E402
from .export import export_all  # noqa: E402
from .gears import STANDARD_PRESSURE_ANGLES  # noqa: E402

COL = {"gear1": "#3b6fb6", "gear2": "#d9822b", "housing": "#9aa0a6",
       "space1": "#7fb2e5", "space2": "#f2b880", "trap": "#d62728",
       "inlet": "#2ca02c", "outlet": "#9467bd"}


class Worker(QObject):
    progress = Signal(str)
    done = Signal(object)
    failed = Signal(str)

    def __init__(self, path, settings):
        super().__init__()
        self.path, self.settings = path, settings

    def run(self):
        try:
            res = analyse_pump(self.path, self.settings, progress=self.progress.emit)
            self.done.emit(res)
        except Exception as e:                      # report any failure in the window
            self.failed.emit(f"{e}\n\n{traceback.format_exc()}")


def _fill(ax, geom, **kw):
    for p in getattr(geom, "geoms", [geom]):
        if p.is_empty or p.geom_type != "Polygon":
            continue
        x, y = p.exterior.xy
        ax.fill(x, y, **kw)
        for r in p.interiors:
            x, y = r.xy
            ax.fill(x, y, color="white", lw=0)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Gear Pump CAD -> Amesim")
        self.resize(1300, 820)
        self.res = None
        self.thread = None

        # ---- left: file, settings, actions
        left = QWidget()
        lv = QVBoxLayout(left)
        self.btn_open = QPushButton("Open STEP ...")
        self.lbl_file = QLabel("no file")
        self.lbl_file.setWordWrap(True)
        lv.addWidget(self.btn_open)
        lv.addWidget(self.lbl_file)

        box = QGroupBox("Settings")
        f = QFormLayout(box)
        self.cmb_dir = QComboBox()
        self.cmb_dir.addItems(["CCW (counter-clockwise)", "CW (clockwise)"])
        self.cmb_dir.setToolTip("Drive gear rotation as seen in the section view. "
                                "The inlet is where the teeth leave the mesh.")
        self.cmb_drive = QComboBox()
        self.cmb_drive.addItem("auto")
        self.cmb_alpha = QComboBox()
        self.cmb_alpha.addItem("auto")
        self.cmb_alpha.addItems([f"{a:g}" for a in sorted(STANDARD_PRESSURE_ANGLES)])
        self.cmb_alpha.setToolTip("The CAD fixes the base radius; module and pressure angle "
                                  "are split using standard values unless set here.")
        self.sp_step = QDoubleSpinBox()
        self.sp_step.setRange(0.1, 10)
        self.sp_step.setValue(1.0)
        self.sp_step.setSuffix(" deg")
        self.sp_mesh = QSpinBox()
        self.sp_mesh.setRange(21, 2001)
        self.sp_mesh.setValue(181)
        self.sp_slices = QSpinBox()
        self.sp_slices.setRange(1, 101)
        self.sp_slices.setValue(9)
        self.sp_tol = QDoubleSpinBox()
        self.sp_tol.setDecimals(4)
        self.sp_tol.setRange(0.0001, 0.1)
        self.sp_tol.setValue(0.005)
        self.sp_tol.setSuffix(" mm")
        f.addRow("Drive gear rotation", self.cmb_dir)
        f.addRow("Drive gear (solid)", self.cmb_drive)
        f.addRow("Pressure angle", self.cmb_alpha)
        f.addRow("Chamber angle step", self.sp_step)
        f.addRow("Mesh samples / pitch", self.sp_mesh)
        f.addRow("Slices across width", self.sp_slices)
        f.addRow("Contact tolerance", self.sp_tol)
        lv.addWidget(box)
        self.btn_run = QPushButton("Analyse")
        self.btn_export = QPushButton("Export for Amesim ...")
        self.btn_run.setEnabled(False)
        self.btn_export.setEnabled(False)
        lv.addWidget(self.btn_run)
        lv.addWidget(self.btn_export)
        lv.addStretch(1)

        # ---- right: tabs
        self.tabs = QTabWidget()
        # section view
        sec_w = QWidget()
        sv = QVBoxLayout(sec_w)
        self.fig_sec = Figure(figsize=(7, 6))
        self.can_sec = FigureCanvasQTAgg(self.fig_sec)
        sv.addWidget(NavigationToolbar2QT(self.can_sec, self))
        sv.addWidget(self.can_sec, 1)
        hl = QHBoxLayout()
        self.lbl_ang = QLabel("drive gear angle 0.0 deg")
        self.sld = QSlider(Qt.Horizontal)
        self.sld.setRange(0, 720)
        hl.addWidget(self.lbl_ang)
        hl.addWidget(self.sld, 1)
        sv.addLayout(hl)
        self.tabs.addTab(sec_w, "Section")
        # curves
        cur_w = QWidget()
        cv = QVBoxLayout(cur_w)
        self.fig_cur = Figure(figsize=(7, 6))
        self.can_cur = FigureCanvasQTAgg(self.fig_cur)
        cv.addWidget(NavigationToolbar2QT(self.can_cur, self))
        cv.addWidget(self.can_cur, 1)
        self.tabs.addTab(cur_w, "Volumes and areas")
        # results table
        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["Quantity", "Drive gear", "Driven gear"])
        self.table.horizontalHeader().setStretchLastSection(True)
        self.tabs.addTab(self.table, "Results")
        # log
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.tabs.addTab(self.log, "Log")

        split = QSplitter()
        split.addWidget(left)
        split.addWidget(self.tabs)
        split.setStretchFactor(1, 1)
        self.setCentralWidget(split)

        self.btn_open.clicked.connect(self.open_file)
        self.btn_run.clicked.connect(self.run)
        self.btn_export.clicked.connect(self.export)
        self.sld.valueChanged.connect(self.draw_section)
        self.path = None

    # ------------------------------------------------------------ actions
    def open_file(self):
        p, _ = QFileDialog.getOpenFileName(self, "Open gear pump STEP", "",
                                           "STEP files (*.step *.stp *.STEP *.STP)")
        if p:
            self.set_file(p)

    def set_file(self, p):
        self.path = p
        self.lbl_file.setText(p)
        self.btn_run.setEnabled(True)
        self.cmb_drive.clear()
        self.cmb_drive.addItem("auto")

    def settings(self):
        alpha = self.cmb_alpha.currentText()
        drive = self.cmb_drive.currentText()
        return Settings(
            drive_index=None if drive == "auto" else int(drive.split()[1]),
            direction=1 if self.cmb_dir.currentIndex() == 0 else -1,
            alpha_deg=None if alpha == "auto" else float(alpha),
            angle_step_deg=self.sp_step.value(), mesh_points=self.sp_mesh.value(),
            n_slices=self.sp_slices.value(), contact_tol=self.sp_tol.value())

    def run(self):
        if not self.path:
            return
        self.btn_run.setEnabled(False)
        self.btn_export.setEnabled(False)
        self.log.clear()
        self.tabs.setCurrentWidget(self.log)
        self.thread = QThread()
        self.worker = Worker(self.path, self.settings())
        self.worker.moveToThread(self.thread)
        self.thread.started.connect(self.worker.run)
        self.worker.progress.connect(self.log.appendPlainText)
        self.worker.done.connect(self.finished)
        self.worker.failed.connect(self.failed)
        self.worker.done.connect(self.thread.quit)
        self.worker.failed.connect(self.thread.quit)
        self.thread.start()

    def failed(self, msg):
        self.btn_run.setEnabled(True)
        self.log.appendPlainText("ERROR: " + msg)
        QMessageBox.critical(self, "Analysis failed", msg.split("\n\n")[0])

    def finished(self, res):
        self.res = res
        self.btn_run.setEnabled(True)
        self.btn_export.setEnabled(True)
        gi = res.section.gear_indices
        cur = self.cmb_drive.currentText()
        self.cmb_drive.blockSignals(True)
        self.cmb_drive.clear()
        self.cmb_drive.addItems(["auto", f"solid {gi[0]}", f"solid {gi[1]}"])
        if cur != "auto":
            self.cmb_drive.setCurrentText(cur)
        self.cmb_drive.blockSignals(False)
        self.fill_table()
        self.draw_curves()
        self.draw_section()
        self.tabs.setCurrentIndex(0)

    def export(self):
        if self.res is None:
            return
        d = QFileDialog.getExistingDirectory(self, "Output folder",
                                             str(Path(self.res.file).parent))
        if not d:
            return
        files = export_all(self.res, d)
        self.log.appendPlainText(f"Wrote {len(files)} files to {d}:")
        for p in files:
            self.log.appendPlainText("  " + Path(p).name)
        QMessageBox.information(self, "Export", f"Wrote {len(files)} files to\n{d}")

    # ------------------------------------------------------------ views
    def fill_table(self):
        r = self.res
        g1, g2, p, k = r.gear1, r.gear2, r.pair, r.kin
        lg = r.lateral_gaps

        def f(v, n=4):
            if v is None or (isinstance(v, float) and not np.isfinite(v)):
                return "n/a"
            return str(v) if isinstance(v, (int, np.integer)) else f"{v:.{n}f}"

        rows = [("Number of teeth z", g1.z, g2.z),
                ("Module m [mm]", g1.module, g2.module),
                ("Pressure angle [deg]", g1.alpha_deg, g2.alpha_deg),
                ("Profile shift x", g1.x, g2.x),
                ("Tip radius ra [mm]", g1.ra, g2.ra),
                ("Root radius rf [mm]", g1.rf, g2.rf),
                ("Base radius rb [mm]", g1.rb, g2.rb),
                ("Reference radius [mm]", g1.r_pitch, g2.r_pitch),
                ("Operating pitch radius [mm]", p.rw1, p.rw2),
                ("Addendum coeff. ha*", g1.ha, g2.ha),
                ("Dedendum coeff. hf*", g1.hf, g2.hf),
                ("Tip land [mm]", g1.tip_thickness, g2.tip_thickness),
                ("Shaft bore radius [mm]", g1.bore_radius, g2.bore_radius),
                ("Involute fit rms [mm]", g1.flank_rms, g2.flank_rms),
                ("Tip clearance h_r [mm]", k.tip_clearance1, k.tip_clearance2),
                ("Sealing arc [deg]", k.seal_arc1_deg, k.seal_arc2_deg),
                ("Teeth in sealing arc", k.seal_teeth1, k.seal_teeth2),
                ("Tooth space volume max [mm3]", k.V1.max(), k.V2.max()),
                ("Tooth space volume min [mm3]", k.V1.min(), k.V2.min()),
                ("Inlet area max [mm2]", k.A_in1.max(), k.A_in2.max()),
                ("Outlet area max [mm2]", k.A_out1.max(), k.A_out2.max()),
                ("Centre distance a [mm]", p.a, None),
                ("Face width b [mm]", p.face_width, None),
                ("Working pressure angle [deg]", p.alpha_w_deg, None),
                ("Backlash (circumferential) [mm]", p.backlash, None),
                ("Contact ratio", p.contact_ratio, None),
                ("Lateral gap upper / lower [mm]", lg[0], lg[1]),
                ("Displacement [cm3/rev]", p.displacement, None),
                ("Chamber volume swing [cm3/rev]", k.D_cv, None),
                ("Trapped volume max [mm3]", k.V_trap.max(), None)]
        self.table.setRowCount(len(rows))
        for i, (name, a, b) in enumerate(rows):
            self.table.setItem(i, 0, QTableWidgetItem(name))
            self.table.setItem(i, 1, QTableWidgetItem(f(a)))
            self.table.setItem(i, 2, QTableWidgetItem("" if b is None and "upper" not in name
                                                      else f(b)))
        self.table.resizeColumnsToContents()

    def draw_curves(self):
        k = self.res.kin
        fig = self.fig_cur
        fig.clear()
        ax1, ax2, ax3 = fig.add_subplot(311), fig.add_subplot(312), fig.add_subplot(313)
        ax1.plot(k.psi_deg, k.V1, color=COL["gear1"], label="drive gear")
        ax1.plot(k.psi_deg, k.V2, color=COL["gear2"], ls="--", label="driven gear")
        ax1.set_ylabel("TSV [mm³]")
        ax1.legend(loc="lower right", fontsize=8)
        ax2.plot(k.psi_deg, k.A_in1, color=COL["inlet"], label="inlet, drive")
        ax2.plot(k.psi_deg, k.A_out1, color=COL["outlet"], label="outlet, drive")
        ax2.plot(k.psi_deg, k.A_in2, color=COL["inlet"], ls="--", label="inlet, driven")
        ax2.plot(k.psi_deg, k.A_out2, color=COL["outlet"], ls="--", label="outlet, driven")
        ax2.set_ylabel("area [mm²]")
        ax2.set_xlabel("chamber angle ψ [deg] (0 = middle of the mesh)")
        ax2.legend(loc="upper center", fontsize=8, ncol=2)
        ax3.plot(k.theta_mesh_deg, k.V_trap, color=COL["trap"])
        ax3.set_ylabel("trapped [mm³]")
        ax3.set_xlabel("drive gear angle over one tooth pitch [deg]")
        for ax in (ax1, ax2, ax3):
            ax.grid(alpha=0.3)
        fig.tight_layout()
        self.can_cur.draw_idle()

    def draw_section(self, *_):
        if self.res is None:
            return
        kin = self.res.kinematics
        theta_deg = self.sld.value() * 0.5
        self.lbl_ang.setText(f"drive gear angle {theta_deg:5.1f} deg")
        th = np.radians(theta_deg)
        G1, G2 = kin.gears_at(th)
        t1, t2 = kin.angles(th)
        fig = self.fig_sec
        fig.clear()
        ax = fig.add_subplot(111)
        _fill(ax, self.res.section.housing, color=COL["housing"], alpha=0.6, lw=0)
        _fill(ax, affinity.rotate(kin.S1, t1, origin=kin.C1, use_radians=True)
              .intersection(kin.H1).difference(G2), color=COL["space1"], lw=0)
        _fill(ax, affinity.rotate(kin.S2, t2, origin=kin.C2, use_radians=True)
              .intersection(kin.H2).difference(G1), color=COL["space2"], lw=0)
        _fill(ax, G1, color=COL["gear1"], alpha=0.85, lw=0)
        _fill(ax, G2, color=COL["gear2"], alpha=0.85, lw=0)
        pockets, segs, _ = kin.mesh_state(th)
        for pk in pockets:
            _fill(ax, pk, color=COL["trap"], lw=0)
        for X, _d in kin.contact_points(th):
            ax.plot(*X, "k.", ms=5)
        k = self.res.kin
        inlet_y = 1 if k.direction > 0 else -1
        R = max(self.res.gear1.ra, self.res.gear2.ra)
        ax.annotate("INLET", (kin.a / 2, inlet_y * 1.25 * R), ha="center",
                    color=COL["inlet"], weight="bold")
        ax.annotate("OUTLET", (kin.a / 2, -inlet_y * 1.25 * R), ha="center",
                    color=COL["outlet"], weight="bold")
        ax.set_aspect("equal")
        ax.set_xlim(-1.4 * R, kin.a + 1.4 * R)
        ax.set_ylim(-1.4 * R, 1.4 * R)
        ax.set_title("Mid-plane section: blue/orange = tooth space 0 of each gear, "
                     "red = trapped volume", fontsize=9)
        fig.tight_layout()
        self.can_sec.draw_idle()


def main(argv=None):
    app = QApplication.instance() or QApplication(sys.argv if argv is None else argv)
    w = MainWindow()
    args = sys.argv[1:] if argv is None else argv[1:]
    if args:
        w.set_file(args[0])
    w.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
