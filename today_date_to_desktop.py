from datetime import datetime
from pathlib import Path


def main() -> None:
    desktop = Path.home() / "Desktop"
    output_file = desktop / "today_date.txt"
    today = datetime.now().strftime("%Y-%m-%d")
    output_file.write_text(f"{today}\n", encoding="utf-8")
    print(f"已写入: {output_file}")


if __name__ == "__main__":
    main()
