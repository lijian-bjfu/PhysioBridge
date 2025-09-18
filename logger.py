# utils/logger.py
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path
import os
import sys

PROJECT_ROOT = Path(__file__).resolve().parent  # logger.py is at project root
LOG_DIR = PROJECT_ROOT / "data" / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)

# 日志文件名可带日期时间戳
from datetime import datetime
_now = datetime.now().strftime("%Y%m%d-%H%M%S")
LOG_FILE = LOG_DIR / f"physico_{_now}.log"

# 配置（如需改动可从 settings.py 或环境变量读取）
LOG_LEVEL = os.environ.get("PHYSICO_LOG_LEVEL", "INFO").upper()
MAX_BYTES = int(os.environ.get("PHYSICO_LOG_MAXBYTES", 10 * 1024 * 1024))  # 10MB
BACKUP_COUNT = int(os.environ.get("PHYSICO_LOG_BACKUPS", 5))

# 创建 logger
logger = logging.getLogger("physico")
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))
logger.propagate = False  # 防止重复打印

# 控制台处理器（终端）
ch = logging.StreamHandler(sys.stdout)
ch.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# 文件处理器（轮转）
fh = RotatingFileHandler(str(LOG_FILE), maxBytes=MAX_BYTES, backupCount=BACKUP_COUNT, encoding="utf-8")
fh.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

fmt = logging.Formatter("[%(asctime)s] %(levelname)-8s %(name)s:%(lineno)d | %(message)s", "%Y-%m-%d %H:%M:%S")
ch.setFormatter(fmt)
fh.setFormatter(fmt)

# 只添加一次 handler（防止重复添加）
if not logger.handlers:
    logger.addHandler(ch)
    logger.addHandler(fh)

def set_level(level:str):
    lvl = getattr(logging, level.upper(), None)
    if lvl is not None:
        logger.setLevel(lvl)
        ch.setLevel(lvl)
        fh.setLevel(lvl)