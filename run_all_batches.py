#!/usr/bin/env python3
"""
批量测试所有目录的 SQL 文件
"""

import subprocess
import sys
from pathlib import Path

# 配置
PROJECT_ROOT = Path(r"d:\workspace\superset-github\clickhouse-doc")
TARGET_DIRS = [
    "05-data-type",
    "07-troubleshooting", 
    "08-information-schema",
    "09-data-deletion",
    "10-date-update",
    "11-data-update",
    "11-performance",
    "12-security-authentication",
    "13-monitor"
]

print("=" * 80)
print("批量测试所有目录")
print("=" * 80)

results = {}

for target_dir in TARGET_DIRS:
    dir_path = PROJECT_ROOT / target_dir
    if not dir_path.exists():
        print(f"\n[SKIP] 目录不存在: {target_dir}")
        continue
    
    # 检查是否有 SQL 文件
    sql_files = list(dir_path.glob("*_examples.sql"))
    if not sql_files:
        print(f"\n[SKIP] 没有 SQL 文件: {target_dir}")
        continue
    
    print(f"\n{'=' * 80}")
    print(f"测试目录: {target_dir}")
    print(f"{'=' * 80}")
    
    # 运行批量执行
    result = subprocess.run(
        ["python", "run_batch_sql.py", target_dir],
        capture_output=True,
        text=True
    )
    
    # 解析结果
    output = result.stdout + result.stderr
    
    # 统计成功/失败
    success_count = output.count("[OK] 成功")
    error_count = output.count("[ERROR] 失败")
    
    print(f"\n结果: {success_count} 成功, {error_count} 失败")
    
    results[target_dir] = {
        "success": success_count,
        "errors": error_count,
        "exit_code": result.returncode
    }

# 打印总结
print("\n" + "=" * 80)
print("测试总结")
print("=" * 80)

total_success = 0
total_errors = 0
total_dirs = len(results)

for dir_name, result in results.items():
    status = "[OK]" if result["errors"] == 0 else "[FAIL]"
    print(f"{status} {dir_name}: {result['success']} 成功, {result['errors']} 失败")
    total_success += result['success']
    total_errors += result['errors']

print(f"\n总计: {total_success} 成功, {total_errors} 失败")

if total_errors > 0:
    print(f"\n[WARNING] 有 {total_errors} 个语句执行失败")
    sys.exit(1)
else:
    print("\n[OK] 所有语句执行成功！")
    sys.exit(0)
