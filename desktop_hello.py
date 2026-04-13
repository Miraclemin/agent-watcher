from datetime import datetime
import platform


now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
print("Desktop Python script executed successfully.")
print(f"Time: {now}")
print(f"Python: {platform.python_version()}")
