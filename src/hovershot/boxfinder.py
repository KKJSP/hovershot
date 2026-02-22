import math
import subprocess
import tempfile
from dataclasses import dataclass

import cv2
import numpy as np

from hovershot.config import Config
from hovershot.constants import CSS4_COLORS


@dataclass
class Box:
    x: int
    y: int
    width: int
    height: int

    def __post_init__(self):
        self.left = self.x
        self.right = self.x + self.width
        self.top = self.y
        self.bottom = self.y + self.height

    def __iter__(self):
        yield self.x
        yield self.y
        yield self.width
        yield self.height

    def __hash__(self):
        return hash((self.x, self.y, self.width, self.height))

    @property
    def area(self):
        return self.width * self.height

    def expand(self, amount) -> "Box":
        return Box(
            self.x - amount,
            self.y - amount,
            self.width + 2 * amount,
            self.height + 2 * amount
        )

    def scale(self, amount: tuple[float, float]) -> "Box":
        return Box(
            int(self.x * amount[0]),
            int(self.y * amount[1]),
            int(self.width * amount[0]),
            int(self.height * amount[1])
        )

    def contains_point(self, x: int, y: int) -> bool:
        return self.left <= x <= self.right and self.top <= y <= self.bottom

    def contains(self, other: "Box") -> bool:
        return (
            self.left <= other.left
            and self.right >= other.right
            and self.top <= other.top
            and self.bottom >= other.bottom
        )

    def overlaps(self, other: "Box") -> bool:
        return not (
            self.right < other.left
            or self.left > other.right
            or self.bottom < other.top
            or self.top > other.bottom
        )

    def overlap(self, other: "Box") -> float:
        if not self.overlaps(other):
            return 0.0

        x_overlap = max(0, min(self.right, other.right) - max(self.left, other.left))
        y_overlap = max(0, min(self.bottom, other.bottom) - max(self.top, other.top))

        return x_overlap * y_overlap

    def edge_distance(self, other: "Box") -> float:
        dx = max(0, self.left - other.right, other.left - self.right)
        dy = max(0, self.top - other.bottom, other.top - self.bottom)
        return math.hypot(dx, dy)

    def alignment(self, other: "Box", margin: float) -> float:
        """Returns fraction of 'other' that is within the shadow of 'self' in any direction"""
        width_overlap = max(0, min(self.right, other.right) - max(self.left, other.left))
        height_overlap = max(0, min(self.bottom, other.bottom) - max(self.top, other.top))

        width_overlap_fraction = min((width_overlap + margin) / other.width, 1)
        height_overlap_fraction = min((height_overlap + margin) / other.height, 1)

        height_factor = min((self.height + margin) / other.height, 1)
        width_factor = min((self.width + margin) / other.width, 1)

        width_alignment = width_overlap_fraction * height_factor
        height_alignment = height_overlap_fraction * width_factor

        alignment = max(width_alignment, height_alignment)

        return alignment

    def connection_probability(self, other: "Box", merge_distance: float) -> float:

        # If this box is mostly inside the other box, don't connect them
        if self.overlap(other) > 0.9:
            return 0

        # Boxes that are closer are more likely to be connected. Upto merge_distance, the score
        # is 1, at 2x merge_distance, the score is 0.5, and at 3x merge_distance, the score is 0
        edge_distance = self.edge_distance(other)
        distance_score = min(1, max(0, (merge_distance * 3 - edge_distance) / merge_distance / 2))

        # Alignment score is 1 if the boxes are perfectly aligned vertically or horiztonally, and
        # decreases as they become misaligned E.g. It is 0 for boxes that are diagonal to each other
        # Only consider alignment if the boxes are far from each other, otherwise the proximity is
        # a strong signal that they are connected, even if they are not perfectly aligned. The edge
        # proximity is weighed by the area ratio to ensure small boxes do not connect to
        # other large boxes even if they are really close.
        area_ratio = min(self.area * 5 / other.area, 1)
        proximity = min(1, merge_distance / max(1, edge_distance) / 2)
        adjusted_proximity = proximity * area_ratio
        alignment = self.alignment(other, merge_distance)
        alignment_score = adjusted_proximity + (1 - adjusted_proximity) * alignment

        return distance_score * alignment_score


class BoxFinder:

    def __init__(
        self,
        ksize=(8, 5),
        color_threshold=(5, 40),
        margin=2,
        sea_point_gap=10,
    ):
        # Box finding parameters
        self._ksize = ksize
        self._color_threshold = color_threshold

        # Sea calling parameters
        self._margin = margin
        self.sea_point_gap = sea_point_gap

        # Set in predict based on the image size to handle different resolutions
        self._scale = 1

    @property
    def ksize(self):
        """Margin rounded down to ensure details are captured even for small resolutions"""
        return (
            max(1, math.floor(self._ksize[0] * self._scale)),
            max(1, math.floor(self._ksize[1] * self._scale))
        )

    @property
    def margin(self):
        """Margin rounded up to ensure the moat is wide enough to capture the sea color"""
        return math.ceil(self._margin * self._scale)

    def predict(self, image):
        # TODO: Better box and ksize estimation using OCR

        # Scale the metrics based on the original image size on which it was developed.
        # This allows it to work on different screen resolutions without manual tuning.
        self._scale = image.shape[0] / 1964

        if Config.is_debug():
            cv2.imwrite(Config.folder("debug") / "_0_source.png", image)

        # Convert to LAB for better color distance measurement
        lab_image = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
        contours, heirarchy, edge_image = self._find_contours(lab_image)
        boxes = self._estimate_boxes(contours, image)
        init = len(boxes)
        boxes = self._selectable_boxes(boxes, heirarchy, image)
        boxes, sea_colors = self._get_stable_boxes(lab_image, boxes)
        seas = self._group_boxes_to_seas(boxes, sea_colors)
        if Config.is_debug():
            self._draw_islands(image, seas)
        network = self._estimate_network(boxes, seas, edge_image)

        print(f"Grouped {init} elements into {len(boxes)} elements across {len(seas)} seas.")

        return network

    def _draw_islands(self, image, seas):
        """Draw the final seas on top of the original image for visualization."""
        sea_image = image.copy()
        rng = np.random.default_rng(0)
        for boxes in seas.values():
            color = self.hex_to_rgb(rng.choice(list(CSS4_COLORS.values())))
            for (x, y, w, h) in boxes:
                cv2.rectangle(sea_image, (x, y), (x + w, y + h), color, 2)
        cv2.imwrite(Config.folder("debug") / "_3_seas.png", sea_image)

    def _estimate_network(self, boxes, seas, edge_image):
        network = self._connect_noisy_boxes(boxes, edge_image)

        merge_distance = math.hypot(*np.array(self.ksize) * 2)
        for boxes in seas.values():
            for box in boxes:
                if box in network:
                    continue

                network[box] = []
                for other in boxes:
                    if box.connection_probability(other, merge_distance) > 0.5:
                        network[box].append(other)

        return network

    def _connect_noisy_boxes(self, boxes, edges, min_uncovered=0.9, min_exposed=0.05):
        """Finds boxes which are likely due to noise inside larger boxes"""

        grid_size = 10
        grid = {}
        grid_width = edges.shape[1] // grid_size
        grid_height = edges.shape[0] // grid_size
        for i in range(grid_size + 1):
            for j in range(grid_size + 1):
                grid_box = Box(grid_width * i, grid_height * j, grid_width, grid_height)
                for box in boxes:
                    if box.overlaps(grid_box):
                        grid.setdefault((i, j), []).append(box)

        parents = {}
        for boxes in grid.values():
            for parent in boxes:
                for child in boxes:
                    if parent == child:
                        continue

                    if parent.contains(child):
                        parents.setdefault(parent, []).append(child)

        network = {}
        for parent, children in parents.items():
            subview = np.ma.masked_array(
                edges[parent.top:parent.bottom, parent.left: parent.right],
                np.zeros((parent.height, parent.width), dtype=bool)
            )
            subview[:self.margin, :] = np.ma.masked
            subview[-self.margin:, :] = np.ma.masked
            subview[:, :self.margin] = np.ma.masked
            subview[:, -self.margin:] = np.ma.masked
            for child in children:
                subview[
                    child.top - parent.top:child.bottom - parent.top,
                    child.left - parent.left:child.right - parent.left
                ] = np.ma.masked

            if subview.mask.mean() < min_uncovered and subview.mean() / 255 > min_exposed:
                for child in children:
                    network.setdefault(child, []).append(parent)

        return network

    def _group_boxes_to_seas(self, boxes, sea_colors):
        """Groups boxes into seas based on color similarity."""

        seas = {}
        for box, box_sea_color in zip(boxes, sea_colors):
            for c_color in seas:
                if np.linalg.norm(np.subtract(c_color, box_sea_color)) < self._color_threshold[0]:
                    seas[c_color].append(box)
                    break
            else:
                seas[box_sea_color] = [box]

        return seas

    def _get_stable_boxes(self, lab_img, initial_boxes):
        """
        Checks each box's perimeter color consistency to filter out non-UI elements.

        Returns boxes that are in calm seas and their associated sea color.
        """

        boxes, sea_colors = [], []
        for box in initial_boxes:
            c_color, is_calm = self._get_sea_color_and_validity(lab_img, box)
            if is_calm:
                boxes.append(box)
                sea_colors.append(c_color)

        return boxes, sea_colors

    def _estimate_boxes(self, contours, image):
        """Estimates bounding boxes from contours, filtering by size and aspect ratio."""

        boxes = []
        for i, cnt in enumerate(contours):
            x, y, w, h = cv2.boundingRect(cnt)
            boxes.append(Box(x, y, w, h))  # Shift to include all edges

        if Config.is_debug():
            boxed_image = image.copy()
            for (x, y, w, h) in boxes:
                cv2.rectangle(boxed_image, (x, y), (x + w, y + h), (0, 255, 0), 2)

            cv2.imwrite(Config.folder("debug") / "_2_initial_boxes.png", boxed_image)

        return boxes

    def _selectable_boxes(self, boxes, heirarchy, image):
        """
        Filters boxes based on size, aspect ratio, and hierarchy to find likely UI elements.

        Some factors are hard coded for (8, 5) ksize
        """

        max_area = np.prod(image.shape[:2]) * 0.6
        max_child_area = np.prod(self.ksize) * 250
        selectable_boxes = set()
        for box, (_, _, _, parent) in zip(boxes, heirarchy[0]):
            x, y, w, h = box
            area = w * h
            if w < self.ksize[0] or h < self.ksize[1] or area > max_area:
                continue  # Too small or too large to be a UI element

            if parent != -1 and area < max_child_area:
                px, py, pw, ph = boxes[parent]
                if pw - w < 4 * self.ksize[0] or ph - h < 6 * self.ksize[1]:
                    continue  # Likely an alphabet in a word, or a double-edged rectangle

            selectable_boxes.add(box)

        return list(selectable_boxes)

    def _find_contours(self, image):
        """Finds contours in the image using Canny edge detection and morphological closing."""

        edges = cv2.Canny(image, self._color_threshold[0], self._color_threshold[1])
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, self.ksize)
        closed = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, kernel)
        contours, heirarchy = cv2.findContours(closed, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE)

        if Config.is_debug():
            cv2.imwrite(Config.folder("debug") / "_1_edges.png", edges)

        return contours, heirarchy, edges

    def _get_sea_color_and_validity(self, color_img, box):
        """
        Samples the perimeter. Returns (median_color, is_calm_sea).
        If the perimeter is wildly multicolored, is_calm_sea becomes False.
        """
        x, y, w, h = box
        h_img, w_img = color_img.shape[:2]
        pts = []

        x_coords = np.arange(x, x + w, self.sea_point_gap, dtype=int)
        y_coords = np.arange(y, y + h, self.sea_point_gap, dtype=int)

        margin = max(1, self.margin)
        for cx in x_coords:
            pts.append((cx, y - margin))
            pts.append((cx, y + h + margin))
        for cy in y_coords:
            pts.append((x - margin, cy))
            pts.append((x + w + margin, cy))

        valid_colors = []
        for px, py in pts:
            if 0 <= px < w_img and 0 <= py < h_img:
                # Convert to standard int array to prevent overflow during math
                valid_colors.append(color_img[py, px].astype(int))

        if not valid_colors:
            return np.array([0, 0, 0]), False

        mean_color = np.mean(valid_colors, axis=0).astype(int)
        difference = np.array(valid_colors) - mean_color
        distance = np.linalg.norm(difference, axis=1)
        is_calm_sea = np.mean(distance < self._color_threshold[1]) >= 0.5

        return tuple(mean_color), is_calm_sea

    @staticmethod
    def hex_to_rgb(hex_color):
        """
        Converts a hex color string (e.g., "#FF5733" or "FF5733")
        to a tuple of (R, G, B) integers.
        """
        # Remove '#' if present
        hex_color = hex_color.lstrip('#')

        # Convert hex pairs to integers
        r = int(hex_color[0:2], 16)
        g = int(hex_color[2:4], 16)
        b = int(hex_color[4:6], 16)

        return [r, g, b]

    @staticmethod
    def capture_image():
        """Captures a screenshot using the macOS 'screencapture' and returns it as a BGR image."""
        with tempfile.NamedTemporaryFile("w", suffix=".png") as tmp_file:
            command = ["screencapture"] + ["-x", tmp_file.name]
            subprocess.run(command)
            image = BoxFinder.load_image(tmp_file.name)

        return image

    @staticmethod
    def load_image(filepath):
        image = cv2.imread(filepath)
        return cv2.cvtColor(image, cv2.COLOR_BGRA2BGR)


# if __name__ == "__main__":
#     cv_img = capture_image()
#     BoxFinder().predict(cv_img, scale=0.1)
