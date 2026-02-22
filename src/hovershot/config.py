from pathlib import Path
import os

from PyQt6.QtCore import QSettings


class Config:

    _SETTINGS_PREFIX = "hovershot"
    _KEY_DEBUG = f"{_SETTINGS_PREFIX}/debug"
    _KEY_SAVE_FOLDER = f"{_SETTINGS_PREFIX}/save_folder"

    _debug = None
    _save_folder = None

    @classmethod
    def set_debug(cls, debug: bool) -> None:
        cls._debug = bool(debug)
        QSettings().setValue(cls._KEY_DEBUG, cls._debug)

    @classmethod
    def is_debug(cls) -> bool:
        if cls._debug is None:
            cls._debug = bool(QSettings().value(cls._KEY_DEBUG, False, type=bool))
        return cls._debug

    @classmethod
    def get_save_folder(cls) -> Path:
        if cls._save_folder is None:
            stored = QSettings().value(cls._KEY_SAVE_FOLDER, "")
            cls._save_folder = Path(stored) if stored else Path(os.path.expanduser("~/Desktop"))
        return cls._save_folder

    @classmethod
    def set_save_folder(cls, folder) -> None:
        cls._save_folder = Path(folder)
        cls._save_folder.mkdir(parents=True, exist_ok=True)
        QSettings().setValue(cls._KEY_SAVE_FOLDER, str(cls._save_folder))

    @classmethod
    def folder(cls, name: str) -> Path:
        folder_path = cls.get_save_folder() / name
        folder_path.mkdir(parents=True, exist_ok=True)

        return folder_path

    class Color:
        primary = (252, 129, 2)  # Orange
        secondary = (78, 145, 166)  # Blue
        background = (60, 56, 53)  # Blackish brown
        dark_accent = (73, 95, 102)  # Blackish brown
        accent = (255, 191, 0)  # Light orange
