# src/utils/paths.py
# 这个文件将作为整个项目的“路径中心”

from pathlib import Path

# 这段代码会自动找到 paths.py 文件自身的位置，
# 然后向上跳三级 (utils -> src -> PhysioBridge)，从而获得整个项目的根目录。
# 这种方法非常可靠，无论您在哪个文件夹下运行脚本，都能准确定位。
PROJECT_ROOT = Path(__file__).resolve().parent
# 现在，我们基于这个根目录来定义所有其他的数据文件夹路径
DATA_DIR = PROJECT_ROOT / "data"
RECORDER_DATA_DIR = DATA_DIR / "recorder_data"
PROCESSED_DATA_DIR = DATA_DIR / "processed_data"
MIRROR_DATA_DIR = DATA_DIR / "mirror_data"

# 您可以在这里打印路径来测试它是否正确 (可选)
# if __name__ == '__main__':
#     print(f"项目根目录是: {PROJECT_ROOT}")
#     print(f"处理后的数据目录是: {PROCESSED_DATA_DIR}")