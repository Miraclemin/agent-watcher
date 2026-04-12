from datetime import datetime


def main() -> None:
    today = datetime.now().astimezone().date()
    print(f"今天的日期是: {today.isoformat()}")


if __name__ == "__main__":
    main()
