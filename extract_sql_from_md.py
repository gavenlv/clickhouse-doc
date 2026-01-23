#!/usr/bin/env python3
"""
自动从 Markdown 文件中提取 SQL 的工具

使用方法：
    python extract_sql_from_md.py

功能：
1. 扫描指定目录下的所有 .md 文件
2. 提取 ```sql ... ``` 代码块
3. 生成对应的 .sql 文件
"""

import os
import re
import sys
from pathlib import Path
from datetime import datetime
from typing import List, Tuple

# 配置
PROJECT_ROOT = Path(r"d:\workspace\superset-github\clickhouse-doc")
# 要处理的目录（排除 00-infra）
TARGET_DIRS = [
    "01-base",
    "02-advance",
    "03-engines",
    "05-data-type",
    "06-admin",
    "07-troubleshooting",
    "08-information-schema",
    "09-data-deletion",
    "10-date-update",
    "11-data-update",
    "11-performance",
    "12-security-authentication",
    "13-monitor"
]

# 排除的文件
EXCLUDE_FILES = [
    "README.md",
    "SYSTEM_TABLE_ALTERNATIVES.md",
    "SQL_EXECUTION_GUIDE.md"
]


def extract_sql_from_markdown(file_path: Path) -> List[Tuple[str, str]]:
    """
    从 Markdown 文件中提取 SQL 代码块

    Args:
        file_path: Markdown 文件路径

    Returns:
        List of (description, sql_code) tuples
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"无法读取文件 {file_path}: {e}")
        return []

    # 匹配 SQL 代码块 ```sql ... ```（更精确的匹配）
    pattern = r'```sql\s*\n(.*?)\n```'
    matches = re.findall(pattern, content, re.DOTALL)

    # 确保匹配的内容确实是 SQL 语句（过滤掉包含过多 Markdown 标记的内容）
    valid_matches = []
    for match in matches:
        # 移除开头的空行和注释
        lines = match.strip().split('\n')
        
        # 过滤掉看起来像 Markdown 标记的内容
        if any(line.strip().startswith('```') for line in lines):
            continue
        if any('**' in line and not line.strip().startswith('--') for line in lines):
            continue
        if any(line.strip().startswith('#') for line in lines):
            continue
        
        valid_matches.append(match.strip())
    
    matches = valid_matches

    if not matches:
        return []

    # 提取每个代码块前的标题或描述
    result = []
    content_lines = content.split('\n')
    
    for i, match in enumerate(matches):
        sql_code = match.strip()
        
        # 跳过空代码
        if not sql_code:
            continue
        
        # 跳过纯注释（全部都是注释行）
        if all(line.strip().startswith('--') or not line.strip() for line in sql_code.split('\n')):
            continue
        
        # 查找代码块前的标题
        description = f"SQL Block {i+1}"
        block_start = content.find('```sql')
        if block_start > 0:
            # 查找最近的一个标题
            lines_before = content[:block_start].split('\n')[-5:]
            for line in reversed(lines_before):
                if line.strip().startswith('##'):
                    description = line.strip().replace('##', '').replace('#', '').strip()
                    break
                elif line.strip().startswith('###'):
                    description = line.strip().replace('###', '').replace('#', '').strip()
                    break
        
        result.append((description, sql_code))

    return result


def clean_sql_code(sql: str) -> str:
    """
    清理 SQL 代码

    Args:
        sql: 原始 SQL 代码

    Returns:
        清理后的 SQL 代码
    """
    # 移除多余的空行
    lines = sql.split('\n')
    cleaned_lines = []
    prev_empty = False
    
    for line in lines:
        stripped = line.strip()
        if not stripped:
            if not prev_empty:
                cleaned_lines.append('')
            prev_empty = True
        else:
            cleaned_lines.append(line)
            prev_empty = False
    
    return '\n'.join(cleaned_lines)


def write_sql_file(md_file: Path, sql_blocks: List[Tuple[str, str]]) -> int:
    """
    将提取的 SQL 写入文件

    Args:
        md_file: 源 Markdown 文件路径
        sql_blocks: SQL 块列表

    Returns:
        写入的 SQL 块数量
    """
    if not sql_blocks:
        return 0

    # 确定 SQL 文件名
    sql_filename = md_file.stem + "_examples.sql"
    sql_file = md_file.parent / sql_filename

    # 检查是否已存在
    if sql_file.exists():
        print(f"  跳过（已存在）: {sql_file.relative_to(PROJECT_ROOT)}")
        return 0

    try:
        with open(sql_file, 'w', encoding='utf-8') as f:
            f.write(f"-- ================================================\n")
            f.write(f"-- {sql_filename}\n")
            f.write(f"-- 从 {md_file.name} 提取的 SQL 示例\n")
            f.write(f"-- 提取时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"-- ================================================\n\n")

            for i, (description, sql_code) in enumerate(sql_blocks):
                f.write(f"\n-- ========================================\n")
                f.write(f"-- {description}\n")
                f.write(f"-- ========================================\n\n")
                f.write(sql_code)
                f.write("\n")

        print(f"  [OK] 写入: {sql_file.relative_to(PROJECT_ROOT)} ({len(sql_blocks)} 个 SQL 块)")
        return len(sql_blocks)

    except Exception as e:
        print(f"  [ERROR] 写入失败 {sql_file}: {e}")
        return 0


def process_directory(directory: str):
    """
    处理单个目录

    Args:
        directory: 目录名称
    """
    dir_path = PROJECT_ROOT / directory
    
    if not dir_path.exists():
        print(f"目录不存在: {directory}")
        return

    print(f"\n处理目录: {directory}")
    print("-" * 60)

    md_files = list(dir_path.glob("*.md"))
    
    # 过滤排除的文件
    md_files = [f for f in md_files if f.name not in EXCLUDE_FILES]

    if not md_files:
        print("未找到 Markdown 文件")
        return

    print(f"找到 {len(md_files)} 个 Markdown 文件")

    total_blocks = 0
    created_files = 0

    for md_file in md_files:
        # 跳过已提取的文件
        sql_file = md_file.parent / (md_file.stem + "_examples.sql")
        if sql_file.exists():
            print(f"  跳过（已提取）: {md_file.name}")
            continue

        sql_blocks = extract_sql_from_markdown(md_file)
        
        if sql_blocks:
            count = write_sql_file(md_file, sql_blocks)
            total_blocks += count
            created_files += 1

    print(f"\n完成: 创建 {created_files} 个 SQL 文件，共 {total_blocks} 个 SQL 块")


def main():
    """主函数"""
    print("=" * 60)
    print("Markdown 到 SQL 提取工具")
    print("=" * 60)
    print()

    total_dirs = 0
    total_files = 0
    total_blocks = 0

    for directory in TARGET_DIRS:
        dir_path = PROJECT_ROOT / directory
        if not dir_path.exists():
            continue

        print(f"\n处理目录: {directory}")
        print("-" * 60)

        md_files = list(dir_path.glob("*.md"))
        md_files = [f for f in md_files if f.name not in EXCLUDE_FILES]

        if not md_files:
            continue

        print(f"找到 {len(md_files)} 个 Markdown 文件")

        dir_blocks = 0
        dir_files = 0

        for md_file in md_files:
            # 跳过已提取的文件
            sql_file = md_file.parent / (md_file.stem + "_examples.sql")
            if sql_file.exists():
                print(f"  跳过（已提取）: {md_file.name}")
                continue

            sql_blocks = extract_sql_from_markdown(md_file)
            
            if sql_blocks:
                count = write_sql_file(md_file, sql_blocks)
                dir_blocks += count
                dir_files += 1

        print(f"\n完成: 创建 {dir_files} 个 SQL 文件，共 {dir_blocks} 个 SQL 块")
        
        total_dirs += 1
        total_files += dir_files
        total_blocks += dir_blocks

    print("\n" + "=" * 60)
    print("提取总结")
    print("=" * 60)
    print(f"处理的目录: {total_dirs}")
    print(f"创建的 SQL 文件: {total_files}")
    print(f"提取的 SQL 块: {total_blocks}")
    print("\n完成！")


if __name__ == "__main__":
    main()
