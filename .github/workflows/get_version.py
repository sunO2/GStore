import yaml

# 读取 YAML 文件内容
with open("./pubspec.yaml", "r", encoding="utf-8") as file:
    data = yaml.safe_load(file)

# 提取 version 的主版本号部分（在 '+' 之前）
full_version = data.get("version", "")
version = full_version.split("+")[0]
print(version)