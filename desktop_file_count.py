from pathlib import Path


def main() -> None:
    desktop = Path.home() / "Desktop"
    count = sum(
        1
        for path in desktop.iterdir()
        if path.is_file() and not path.name.startswith(".")
    )
    print(f"桌面文件个数：{count}")


if __name__ == "__main__":
    main()
