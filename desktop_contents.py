from pathlib import Path


def main() -> None:
    desktop = Path.home() / "Desktop"
    entries = sorted(
        (path for path in desktop.iterdir() if not path.name.startswith(".")),
        key=lambda path: (path.is_file(), path.name.lower()),
    )

    print(f"桌面路径: {desktop}")
    print(f"项目总数: {len(entries)}")
    print("-" * 40)

    for path in entries:
        kind = "文件夹" if path.is_dir() else "文件"
        print(f"[{kind}] {path.name}")


if __name__ == "__main__":
    main()
