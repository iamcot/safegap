"""Đọc file config JSON trong thư mục config/."""
import json
from pathlib import Path

CONFIG_DIR = Path(__file__).resolve().parent.parent / "config"


def load(name: str = "default.json", config_dir: Path = CONFIG_DIR) -> dict:
    with open(Path(config_dir) / name, encoding="utf-8") as f:
        return json.load(f)


def load_law(name: str = "law_vn.json", config_dir: Path = CONFIG_DIR) -> dict:
    return load(name, config_dir)
