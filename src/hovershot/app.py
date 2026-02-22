import tempfile
import time
from datetime import datetime
import os
import subprocess
import signal
import sys

from cv2 import COLOR_BGRA2BGR, COLOR_BGR2RGB, cvtColor, imread
from PyQt6.QtWidgets import (
    QApplication, QWidget, QSystemTrayIcon, QMenu, QDialog, QLabel, QCheckBox,
    QPushButton, QVBoxLayout, QHBoxLayout, QFileDialog, QGridLayout, QFrame,
    QLineEdit,
)
from PyQt6.QtGui import QPainter, QColor, QPen, QImage, QPixmap, QPainterPath, \
    QIcon, QAction, QColorSpace, QCursor, QFont
from PyQt6.QtCore import Qt, QVariantAnimation, QEasingCurve, QRectF, QObject, pyqtSignal, \
    QThread, QTimer, QRect

# Import your algorithm from your other file
from hovershot.boxfinder import BoxFinder, Box

# Import the native macOS Apple frameworks
from AppKit import (
    NSEvent,  # noqa
    NSEventMaskKeyDown,  # noqa
    NSEventModifierFlagControl,  # noqa
    NSEventModifierFlagShift,  # noqa
    NSEventModifierFlagCommand,  # noqa
    NSEventModifierFlagOption,  # noqa
    NSWorkspace,  # noqa
    NSApplicationActivateIgnoringOtherApps,  # noqa
)

from hovershot.config import Config


class ScanWorker(QThread):
    boxes_ready = pyqtSignal(dict)

    def __init__(self, cv_img, scale):
        super().__init__()
        # Pass in only the raw data needed for the math (no UI elements!)
        self.cv_img = cv_img
        self.scale = scale

    def run(self):
        """Executed in the background by Qt when worker.start() is called."""

        start = time.time()
        network = self.process_atomic_scan()
        print(f"Atomic scan completed in {time.time() - start:.2f} seconds.")
        self.boxes_ready.emit(network)  # noqa: PyUnresolvedReferences

    def process_atomic_scan(self):
        """Runs the atomic scan once and scales all boxes per sea."""
        print("Running atomic scan...")
        network = BoxFinder().predict(self.cv_img)

        scaled_network = {}
        for box in network:
            scaled_network[box.scale(self.scale)] = [b.scale(self.scale) for b in network[box]]

        if len(scaled_network) == 0:
            scaled_network = {Box(0, 0, 0, 0): []}

        return scaled_network


class ScreenshotOverlay(QWidget):
    def __init__(self, captured_img):
        super().__init__()

        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setMouseTracking(True)
        self.setCursor(Qt.CursorShape.CrossCursor)

        self.previous_app = NSWorkspace.sharedWorkspace().frontmostApplication()

        # 1. State Variables
        self.autocluster = True
        self.scroll_accumulator = 0  # Normalizes trackpad and mouse scrolling
        self.cv_img = captured_img
        self.selected_boxes = []
        self.hovered_box = None
        self.enc_box = None
        self.padded_enc_box = None
        self.network = {}  # Stores our scaled UI boxes
        self.anim_box = None      # The visual box currently being drawn
        self.flowmode = False
        self._notification = None

        self._set_animations()

    def _set_animations(self):
        self.box_anim = QVariantAnimation(self)
        self.box_anim.valueChanged.connect(self._on_anim_step)  # noqa: PyUnresolvedReferences
        self.box_anim.finished.connect(self._on_anim_finished)  # noqa: PyUnresolvedReferences

        self._message_anim = QVariantAnimation(self)
        self._message_anim.valueChanged.connect(self._fade_message)  # noqa: PyUnresolvedReferences
        self._message_anim.finished.connect(self._clear_message)  # noqa: PyUnresolvedReferences
        self._message_anim.setDuration(2500)
        self._message_anim.setKeyValueAt(0.0, 0)
        self._message_anim.setKeyValueAt(0.1, 255)
        self._message_anim.setKeyValueAt(0.7, 255)
        self._message_anim.setKeyValueAt(1.0, 0)

    def setup_dimensions_and_background(self):
        # 1. Get the screen this widget is ACTUALLY on
        # If the widget hasn't been shown yet, ensure self.setScreen() was called first
        screen = self.screen()
        logical_geo = screen.geometry()
        dpr = screen.devicePixelRatio()  # Usually 2.0 on Mac, 1.0 on external monitors

        img_h, img_w = self.cv_img.shape[:2]

        # 2. Match the widget size to the logical monitor size
        self.setGeometry(logical_geo)

        # 3. CALCULATE SCALE PROPERLY
        # Logical width * DPR = Physical Width.
        # We want to know how to get from Physical (OpenCV) to Logical (Qt Paint)
        # The math should be: (Logical_Width) / (Physical_Image_Width)
        self.scale = (logical_geo.width() / img_w, logical_geo.height() / img_h)

        # 4. Handle the Background Pixmap
        cv_rgb = cvtColor(self.cv_img, COLOR_BGR2RGB)
        q_img = QImage(cv_rgb.data, img_w, img_h, 3 * img_w, QImage.Format.Format_RGB888)

        # Set the DPR on the QImage so it looks sharp on Retina
        q_img.setDevicePixelRatio(dpr)

        self.bg_pixmap = QPixmap.fromImage(q_img)

    def start_scan(self):
        # Animation and Scanning Parameters
        self.scan_x = self.width()
        self.scanning = True

        self.scan_timer = QTimer(self)
        self.scan_timer.timeout.connect(self._update_scan_animation)  # noqa: PyUnresolvedReferences
        self.scan_timer.start(16)  # ~60 FPS

    def _update_scan_animation(self):
        if self.scanning:  # Phase 1: Search line
            self.scan_x -= 45
            if self.scan_x <= 0:
                self.scan_x = 0
                self._wait_and_reveal()
        else:  # Phase 2: Final Reveal Sweep
            self.scan_x += 60
            if self.scan_x >= self.width():
                self.scan_x = self.width()
                self.scan_timer.stop()

        self.update()

    def process_atomic_scan(self):
        """Runs the atomic scan once and scales all boxes per sea."""

        self.worker = ScanWorker(self.cv_img, self.scale)
        self.worker.boxes_ready.connect(self._on_boxes_processed)  # noqa: PyUnresolvedReferences
        self.worker.start()

    def _on_boxes_processed(self, network):
        """Set the selected boxes and trigger a redraw once the worker thread has finished."""

        self.network = network
        self.worker.deleteLater()
        self.worker = None
        self._wait_and_reveal()

    def _wait_and_reveal(self):
        """Waits for box calculation and scanning to complete before starting the final reveal."""

        if self.scan_x == 0 and len(self.network) > 0:
            self.scanning = False
            self.update()

    def mouseMoveEvent(self, event):
        """Finds hovered box using Area Gravity, supporting rock-solid Cmd-Brush mode."""

        if self.scan_timer.isActive():
            return

        mx, my = event.pos().x(), event.pos().y()

        min_dist = float("inf")
        closest_box = None
        for box in self.network:
            x, y, w, h = box

            dx = max(0, x - mx, mx - (x + w))
            dy = max(0, y - my, my - (y + h))
            edge_dist = dx ** 2 + dy ** 2
            if edge_dist == 0:  # Inside a box
                edge_dist = min(mx - x, (x + w) - mx, my - y, (y + h) - my) ** 2

            if edge_dist <= min_dist:
                min_dist = edge_dist
                if not self.flowmode or min_dist < 225:  # dist is squared: 15 ** 2
                    closest_box = box

        if closest_box != self.hovered_box and closest_box is not None:
            self.hovered_box = closest_box

            if self.flowmode:  # Additive mode: Append without modifying the base selection
                if closest_box not in self.selected_boxes:
                    self.selected_boxes.append(closest_box)
            elif self.autocluster:  # Cluster mode: Run the smart spatial auto-cluster
                self.selected_boxes = self._get_all_connections(closest_box)
            else:  # Single-box mode: No smart clustering
                self.selected_boxes = [closest_box]

            self._update_encompassing_box()
            self.update()

    def _get_all_connections(self, start_box):
        connected_boxes = [start_box]
        seen = {start_box}
        children = self.network[start_box]
        while children:
            connected_boxes.extend(children)
            seen.update(children)
            new_children = []
            for child in children:
                for box in self.network[child]:
                    if box not in seen:
                        seen.add(box)
                        new_children.append(box)
            children = new_children

        return connected_boxes

    def _get_connection_lines(self, start_box):
        edges, depths = [], []
        seen = {start_box}
        children = self.network[start_box]
        parents = [start_box] * len(children)
        depth = 0
        while children:
            seen.update(children)
            for child, parent in zip(children, parents):
                edges.append((
                    int((parent.left + parent.right) / 2),
                    int((parent.top + parent.bottom) / 2),
                    int((child.left + child.right) / 2),
                    int((child.top + child.bottom) / 2),
                ))
                depths.append(depth)

            new_children, parents = [], []
            for child in children:
                for box in self.network[child]:
                    if box not in seen:
                        seen.add(box)
                        new_children.append(box)
                        parents.append(child)

            children = new_children
            depth += 1

        return edges, depths

    @staticmethod
    def _get_bounds(boxes):
        """Get the bounds of all boxes"""

        min_x = min(b[0] for b in boxes)
        min_y = min(b[1] for b in boxes)
        max_r = max(b[0] + b[2] for b in boxes)
        max_b = max(b[1] + b[3] for b in boxes)
        cluster_bounds = [min_x, min_y, max_r - min_x, max_b - min_y]

        return cluster_bounds

    def _update_encompassing_box(self):
        """Calculates strict boundaries for math, and padded boundaries for visuals."""
        cursor_pos = self.mapFromGlobal(self.cursor().pos())
        mx, my = cursor_pos.x(), cursor_pos.y()

        if self.selected_boxes:
            # 1. STRICT LOGICAL BOUNDARY (Used for distance math and containment)
            strict_min_x = min(b.x for b in self.selected_boxes)
            strict_min_y = min(b.y for b in self.selected_boxes)
            strict_max_r = max(b.right for b in self.selected_boxes)
            strict_max_b = max(b.bottom for b in self.selected_boxes)

            self.enc_box = [strict_min_x, strict_min_y,
                            strict_max_r - strict_min_x, strict_max_b - strict_min_y]

            # 2. PADDED VISUAL BOUNDARY (Used for animation and final screenshot)
            padding = 12
            pad_min_x = max(0, strict_min_x - padding)
            pad_min_y = max(0, strict_min_y - padding)
            pad_max_r = min(self.width(), strict_max_r + padding)
            pad_max_b = min(self.height(), strict_max_b + padding)

            target_padded_box = [pad_min_x, pad_min_y,
                                 pad_max_r - pad_min_x, pad_max_b - pad_min_y]

            self.padded_enc_box = target_padded_box  # Store for the final crop!

            if self.box_anim.endValue() == QRectF(*target_padded_box):
                return  # No need to animate if we're already aiming for the target

            # --- THE GROW ANIMATION (Animate to the PADDED box) ---
            self.box_anim.stop()
            self.box_anim.setKeyValues([])
            self.box_anim.setDuration(150)  # 150ms feels snappy but smooth
            self.box_anim.setEasingCurve(QEasingCurve.Type.OutCubic)  # Decelerates smoothly
            if self.anim_box is None:
                self.anim_box = [mx, my, 0, 0]

            self.box_anim.setStartValue(QRectF(*self.anim_box))
            self.box_anim.setEndValue(QRectF(*target_padded_box))
            self.box_anim.start()

        else:
            # Clear both logical and visual targets
            self.enc_box = None
            self.padded_enc_box = None

            # --- THE SHRINK ANIMATION ---
            if self.anim_box:
                self.box_anim.stop()
                self.box_anim.setDuration(150)  # 150ms feels snappy but smooth
                self.box_anim.setEasingCurve(QEasingCurve.Type.OutCubic)  # Decelerates smoothly
                target_box = [mx, my, 0, 0]

                self.box_anim.setKeyValues([])
                self.box_anim.setStartValue(QRectF(*self.anim_box))
                self.box_anim.setEndValue(QRectF(*target_box))
                self.box_anim.start()

    def _play_success_flash(self):
        if self.anim_box:
            self.box_anim.stop()

            self.box_anim.setDuration(250)  # 250ms makes it feel punchy and responsive
            self.box_anim.setEasingCurve(QEasingCurve.Type.InOutQuad)

            # The Bounce Sequence:
            self.box_anim.setKeyValueAt(0.0, QRectF(*self.padded_enc_box))  # Start padded
            self.box_anim.setKeyValueAt(0.5, QRectF(*self.enc_box))
            self.box_anim.setKeyValueAt(1.0, QRectF(*self.padded_enc_box))  # Pop back to padded
            self.box_anim.start()

    def paintEvent(self, event):
        painter = QPainter(self)

        # 1. Draw the frozen screenshot
        painter.drawPixmap(self.rect(), self.bg_pixmap)

        if self.scanning or self.scan_timer.isActive():
            pen = QPen(QColor(255, 255, 255, 255), 7)
            painter.setPen(pen)
            painter.drawLine(int(self.scan_x), 0, int(self.scan_x), self.height())

        # 2. Create the dimming path
        if self.scanning:
            painter.fillRect(
                self.scan_x, 0, self.width() - self.scan_x, self.height(), QColor(0, 0, 0, 75)
            )
            return

        if self.scan_timer.isActive():
            painter.fillRect(0, 0, self.scan_x, self.height(), QColor(0, 0, 0, 75))

        path = QPainterPath()
        path.addRect(QRectF(self.rect()))

        # 3. Cut a ROUNDED hole in the path
        radius = 8.0  # Adjust this to make it more or less round!
        if self.anim_box:
            ex, ey, ew, eh = self.anim_box
            path.addRoundedRect(QRectF(ex, ey, ew, eh), radius, radius)

            # 5. Draw colored border for flow mode and white for hover mode
            if self.flowmode:
                painter.setPen(QPen(QColor(*Config.Color.primary, 255), 5, Qt.PenStyle.SolidLine))
            else:
                painter.setPen(QPen(QColor(255, 255, 255, 200), 2, Qt.PenStyle.SolidLine))
            painter.drawRoundedRect(
                int(ex), int(ey), int(ew), int(eh), radius, radius
            )

        # 4. Fill the path
        path.setFillRule(Qt.FillRule.OddEvenFill)
        alpha = 75 if self.scan_timer.isActive() else 128  # 128 = a1 + a2 * (1 - a1 / 255)
        painter.fillPath(path, QColor(0, 0, 0, alpha))

        # 5. Draw boxes faintly in the background
        painter.setPen(QPen(QColor(255, 255, 255, 80), 1, Qt.PenStyle.SolidLine))
        for box in self.network:
            x, y, w, h = box
            if x < self.scan_x:
                painter.drawRect(x, y, min(w, self.scan_x - x), h)

        # 6. Draw the sequential selection chain (Solid Blue / Orange)
        if self.selected_boxes:
            if self.autocluster:
                painter.setPen(QPen(QColor(*Config.Color.secondary, 255), 2, Qt.PenStyle.SolidLine))
            else:
                painter.setPen(QPen(QColor(*Config.Color.accent, 255), 2, Qt.PenStyle.SolidLine))
            for sx, sy, sw, sh in self.selected_boxes:
                if sx < self.scan_x:
                    painter.drawRect(sx, sy, min(sw, self.scan_x - sx), sh)

        # 7. Highlight the root hovered box (Solid Neon Green)
        if self.hovered_box and self.hovered_box in self.selected_boxes:
            hx, hy, hw, hh = self.hovered_box
            if hx < self.scan_x:
                painter.setPen(QPen(QColor(0, 255, 0, 255), 2, Qt.PenStyle.SolidLine))
                painter.drawRect(hx, hy, min(hw, self.scan_x - hx), hh)

            if self.autocluster and not self.flowmode:
                edges, depths = self._get_connection_lines(self.hovered_box)
                for edge, depth in zip(edges, depths):
                    color = QColor(255, min(depth * 40, 255), 0, 150)
                    painter.setPen(QPen(color, 2, Qt.PenStyle.SolidLine))
                    painter.drawLine(*edge)

        if self._notification:
            message, alpha = self._notification
            font = QFont("Helvetica", 16)
            painter.setFont(font)

            metrics = painter.fontMetrics()
            bg_w = metrics.horizontalAdvance(message) + 40
            bg_h = metrics.height() + 20
            bg_rect = QRect((self.width() - bg_w) // 2, int(self.height() * 0.8 - bg_h), bg_w, bg_h)
            bg_color = QColor(*Config.Color.background, alpha)
            painter.setBrush(bg_color)
            painter.setPen(QColor(*Config.Color.dark_accent, alpha))
            painter.drawRoundedRect(bg_rect, 10, 10)

            painter.setPen(QColor(*Config.Color.primary, alpha))
            painter.drawText(bg_rect, Qt.AlignmentFlag.AlignCenter, message)

    def mousePressEvent(self, event):
        """Click to toggle selection, keeping only the outermost boxes."""
        # SWALLOW THE CLICK: Prevents the OS from passing it to the background app
        event.accept()

        if event.button() == Qt.MouseButton.LeftButton and self.hovered_box:

            # 1. Toggle logic
            if self.hovered_box in self.selected_boxes:
                self.selected_boxes.remove(self.hovered_box)
            else:
                self.selected_boxes.append(self.hovered_box)

            # 3. Filter to keep only the outermost boxes
            filtered_selection = []
            for box in self.selected_boxes:
                is_nested = False
                for other in self.selected_boxes:
                    if box != other and other.contains(box):
                        is_nested = True
                        break
                if not is_nested:
                    filtered_selection.append(box)

            self.selected_boxes = filtered_selection
            self._update_encompassing_box()
            self.update()  # Trigger a redraw

    def keyPressEvent(self, event):
        """Handle keys and track Cmd press."""
        if event.key() == Qt.Key.Key_F:
            event.accept()
            self.flowmode = not self.flowmode
        elif event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_S):
            event.accept()
            if self.padded_enc_box:
                self._save()
        elif event.key() in (Qt.Key.Key_Space, Qt.Key.Key_C):
            if self.padded_enc_box:
                self._copy_selection_to_clipboard()
        elif event.key() == Qt.Key.Key_A:
            self.autocluster = not self.autocluster
        elif event.key() == Qt.Key.Key_V:
            event.accept()
            if self.padded_enc_box:
                self._open_in_preview()
        elif event.key() in (Qt.Key.Key_Escape, Qt.Key.Key_Q):
            event.accept()
            self._quit()
        else:
            super().keyPressEvent(event)

        if event.key() in [Qt.Key.Key_A, Qt.Key.Key_F]:
            if self.autocluster:
                if self.hovered_box:
                    self.selected_boxes = self._get_all_connections(self.hovered_box)
                else:
                    self.selected_boxes = []
            else:
                self.selected_boxes = [self.hovered_box] if self.hovered_box else []

            self._update_encompassing_box()
            self.update()

    def _quit(self):
        if self.previous_app:
            self.previous_app.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
            self.previous_app = None

        del self.cv_img
        del self.network
        del self.bg_pixmap
        self.close()
        self.deleteLater()
        self.box_anim.stop()

    def _on_anim_step(self, value):
        """Updates the visual box coordinates during the animation."""
        self.anim_box = [value.x(), value.y(), value.width(), value.height()]
        self.update()  # Force a redraw

    def _on_anim_finished(self):
        """Cleans up the visual box after the shrink animation completes."""
        if self.enc_box is None:
            self.anim_box = None
            self.update()

    def _cropped_image(self):
        lx, ly, lw, lh = self.padded_enc_box
        px = int(lx / self.scale[0])
        py = int(ly / self.scale[1])
        pw = int(lw / self.scale[0])
        ph = int(lh / self.scale[1])

        # Crop using NumPy slicing [y:y+h, x:x+w]
        cropped_numpy_img = self.cv_img[py:py+ph, px:px+pw]

        # 3. Convert OpenCV's BGR format to standard RGB
        rgb_image = cvtColor(cropped_numpy_img, COLOR_BGR2RGB)

        # 4. Extract the memory details required by PyQt
        height, width, channels = rgb_image.shape
        bytes_per_line = channels * width

        # 5. Create the QImage wrapper around the NumPy data
        q_img = QImage(
            rgb_image.data,
            width,
            height,
            bytes_per_line,
            QImage.Format.Format_RGB888
        )

        # Manually tell Qt to treat this as Display P3 (Native Mac)
        # and convert it to sRGB for display
        srgb_space = QColorSpace(QColorSpace.NamedColorSpace.SRgb)

        # q_img.setColorSpace(p3_space)
        q_img.convertToColorSpace(srgb_space)

        return q_img

    def _save(self):
        """Crops the original CV image and saves to disk."""

        filename = f"Capture_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
        filepath = Config.folder("screenshots") / filename

        q_img = self._cropped_image()
        q_img.save(str(filepath))

        self._notify(f"Saved to: {filepath}")

        self._play_success_flash()

        return filepath

    def _copy_selection_to_clipboard(self):
        if not self.selected_boxes:
            return

        # 6. Push to the macOS Clipboard
        q_img = self._cropped_image()
        clipboard = QApplication.clipboard()
        clipboard.setImage(q_img)

        self._notify(f"Copied image to clipboard!")

        self._play_success_flash()

    def _open_in_preview(self):
        filepath = self._save()

        def _open_preview():
            subprocess.run(["open", "-a", "Preview", str(filepath)])
            self.box_anim.finished.disconnect(_open_preview)
            self._quit()

        self.box_anim.finished.connect(_open_preview)

    def _notify(self, message):
        """Displays a temporary notification message on the overlay."""
        self._notification = (message, 0)
        self._message_anim.stop()
        self._message_anim.start()

    def _fade_message(self, value):
        """Fades the notification message out over time."""
        if self._notification is not None:
            self._notification = (self._notification[0], int(value))
            self.update()  # Trigger a repaint to update the alpha

    def _clear_message(self):
        """Hides the text and redraws the window"""
        self._notification = None
        self.update()


SHORTCUTS = [
    ("Cmd + Shift + 1", "Take a screenshot (global)"),
    ("Return / S", "Save selection to disk"),
    ("Space / C", "Copy selection to clipboard"),
    ("V", "Save and open in Preview"),
    ("F", "Toggle Flow mode (paint multiple boxes)"),
    ("A", "Toggle auto-cluster mode"),
    ("Esc / Q", "Cancel and quit overlay"),
]

ABOUT_TEXT = (
    "<b>HoverShot</b><br>"
    "A smart screenshot tool that detects UI elements and lets you grab "
    "them with a single hover. Use the shortcuts below while the overlay "
    "is active."
)


class SettingsDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("HoverShot Settings")
        self.setMinimumWidth(460)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 20)
        layout.setSpacing(14)

        about = QLabel(ABOUT_TEXT)
        about.setWordWrap(True)
        about.setTextFormat(Qt.TextFormat.RichText)
        layout.addWidget(about)

        layout.addWidget(self._separator())

        shortcuts_title = QLabel("<b>Keyboard shortcuts</b>")
        layout.addWidget(shortcuts_title)

        grid = QGridLayout()
        grid.setHorizontalSpacing(20)
        grid.setVerticalSpacing(4)
        for row, (keys, desc) in enumerate(SHORTCUTS):
            key_label = QLabel(keys)
            key_label.setStyleSheet("font-family: Menlo, monospace;")
            grid.addWidget(key_label, row, 0)
            grid.addWidget(QLabel(desc), row, 1)
        grid.setColumnStretch(1, 1)
        layout.addLayout(grid)

        layout.addWidget(self._separator())

        folder_title = QLabel("<b>Save folder</b>")
        layout.addWidget(folder_title)

        folder_row = QHBoxLayout()
        self.folder_edit = QLineEdit(str(Config.get_save_folder()))
        self.folder_edit.setReadOnly(True)
        browse_btn = QPushButton("Browse…")
        browse_btn.clicked.connect(self._pick_folder)  # noqa: PyUnresolvedReferences
        folder_row.addWidget(self.folder_edit)
        folder_row.addWidget(browse_btn)
        layout.addLayout(folder_row)

        layout.addWidget(self._separator())

        self.debug_checkbox = QCheckBox("Debug mode")
        self.debug_checkbox.setChecked(Config.is_debug())
        self.debug_checkbox.toggled.connect(Config.set_debug)  # noqa: PyUnresolvedReferences
        layout.addWidget(self.debug_checkbox)

        button_row = QHBoxLayout()
        button_row.addStretch(1)
        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.accept)  # noqa: PyUnresolvedReferences
        button_row.addWidget(close_btn)
        layout.addLayout(button_row)

    @staticmethod
    def _separator():
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        line.setFrameShadow(QFrame.Shadow.Sunken)
        return line

    def _pick_folder(self):
        chosen = QFileDialog.getExistingDirectory(
            self, "Choose save folder", str(Config.get_save_folder())
        )
        if chosen:
            Config.set_save_folder(chosen)
            self.folder_edit.setText(str(Config.get_save_folder()))


class AppController(QObject):
    trigger_ui_signal = pyqtSignal()

    def __init__(self):

        super().__init__()
        self.overlay = None
        self.settings_dialog = None

        # 1. Create the System Tray Icon
        tray_icon = QSystemTrayIcon(self)

        # You'll need a small 16x16 or 32x32 icon file in your directory
        # If you don't have one yet, it will just show a blank space
        tray_icon.setIcon(QIcon(self.get_path("icon_32x32.png")))

        # 2. Create the Menu
        tray_menu = QMenu()

        # Add a Label (Disabled item just for show)
        status_action = QAction("HoverShot", self)
        status_action.setEnabled(False)
        tray_menu.addAction(status_action)

        tray_menu.addSeparator()

        shot = QAction("Take screenshot", self)
        shot.triggered.connect(self.trigger_ui_signal.emit)  # noqa: PyUnresolvedReferences
        tray_menu.addAction(shot)

        settings_action = QAction("Settings", self)
        settings_action.triggered.connect(self.show_settings)  # noqa: PyUnresolvedReferences
        tray_menu.addAction(settings_action)

        tray_menu.addSeparator()

        # Add the Quit Option
        quit_action = QAction("Quit HoverShot", self)
        quit_action.triggered.connect(QApplication.quit)  # noqa: PyUnresolvedReferences
        tray_menu.addAction(quit_action)

        # 3. Apply the menu and show the icon
        tray_icon.setContextMenu(tray_menu)
        tray_icon.show()

        # Connect signals to methods
        self.trigger_ui_signal.connect(self.show_overlay)  # noqa: PyUnresolvedReferences
        self.setup_native_hotkey()

    @staticmethod
    def get_path(filename):
        if hasattr(sys, '_MEIPASS'):
            return os.path.join(sys._MEIPASS, filename)
        return os.path.join(os.path.abspath("../../build/icon/"), filename)

    def cleanup(self):
        """Always clean up the monitor when quitting."""
        if hasattr(self, 'monitor') and self.monitor:
            NSEvent.removeMonitor_(self.monitor)

    def setup_native_hotkey(self):
        """Registers a global event monitor with macOS."""

        # The OS will call this function every time a key is pressed globally
        def handler(event):
            self.handle_key_press(event)

        # Register the monitor for KeyDown events
        self.monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSEventMaskKeyDown,
            handler
        )

        print("Service started. Press Cmd+Shift+1 to screenshot. Press Esc to cancel.")

    def handle_key_press(self, event):
        """Parses the native event to check for our specific combo."""
        # Get the currently pressed modifier keys
        flags = event.modifierFlags()

        # Check for our specific modifiers (e.g., Control + Shift)
        has_ctrl = bool(flags & NSEventModifierFlagCommand)
        has_shift = bool(flags & NSEventModifierFlagShift)

        # In macOS virtual keycodes, the 'S' key is exactly 1.
        # (See the reference below if you want to change this)
        key_code = event.keyCode()

        if has_ctrl and has_shift and key_code == 18:
            self.trigger_ui_signal.emit()  # noqa: PyUnresolvedReferences

    def on_hotkey_pressed(self):
        self.trigger_ui_signal.emit()  # noqa: PyUnresolvedReferences

    def capture_active_monitor(self):
        screen, geo = self.get_active_screen_geometry()

        with tempfile.NamedTemporaryFile("w", suffix=".png") as tmp_file:
            area = ["-R", f"{geo.x()},{geo.y()},{geo.width()},{geo.height()}"]
            command = ["screencapture"] + area + ["-x", tmp_file.name]
            subprocess.run(command)
            img_bgra = imread(tmp_file.name)
            cv_img = cvtColor(img_bgra, COLOR_BGRA2BGR)

        return cv_img

    @staticmethod
    def get_active_screen_geometry():
        # Get the global mouse position
        mouse_pos = QCursor.pos()

        # Find which screen contains that point
        active_screen = None
        for screen in QApplication.screens():
            if screen.geometry().contains(mouse_pos):
                active_screen = screen
                break

        # Fallback to primary screen if something goes wrong
        if not active_screen:
            active_screen = QApplication.primaryScreen()

        return active_screen, active_screen.geometry()

    def show_overlay(self):
        if self.overlay is not None:  # TODO: How will this be triggerred?
            self.overlay.close()
            self.overlay.deleteLater()
            self.overlay = None

        cv_img = self.capture_active_monitor()
        screen, geo = self.get_active_screen_geometry()
        self.overlay = ScreenshotOverlay(cv_img)
        self.overlay.setGeometry(geo)
        self.overlay.setScreen(screen)
        self.overlay.setup_dimensions_and_background()
        self.overlay.process_atomic_scan()
        self.overlay.start_scan()
        self.overlay.show()

        # 1. Tell PyQt to prepare the window
        self.overlay.raise_()
        self.overlay.activateWindow()
        self.overlay.destroyed.connect(self.on_overlay_destroyed)

    def on_overlay_destroyed(self):
        self.overlay = None

    def show_settings(self):
        if self.settings_dialog is None:
            self.settings_dialog = SettingsDialog()
            self.settings_dialog.finished.connect(self._on_settings_closed)  # noqa: PyUnresolvedReferences

        self.settings_dialog.show()
        self.settings_dialog.raise_()
        self.settings_dialog.activateWindow()

    def _on_settings_closed(self, _result):
        if self.settings_dialog is not None:
            self.settings_dialog.deleteLater()
            self.settings_dialog = None


if __name__ == '__main__':
    # 1. Setup Signal Handling for Ctrl+C
    # This allows the Python interpreter to catch the SIGINT signal
    # and tell the PyQt application to quit.
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    app = QApplication(sys.argv)
    app.setOrganizationName("HoverShot")
    app.setOrganizationDomain("hovershot.app")
    app.setApplicationName("HoverShot")
    app.setQuitOnLastWindowClosed(False)

    controller = AppController()
    app.aboutToQuit.connect(controller.cleanup)  # noqa: PyUnresolvedReferences

    sys.exit(app.exec())
