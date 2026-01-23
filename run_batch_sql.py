#!/usr/bin/env python3
"""
ClickHouse SQL 文件批量执行工具（分批执行）

使用方法：
    python run_batch_sql.py <目录名>
    
示例：
    python run_batch_sql.py 05-data-type
    python run_batch_sql.py 08-information-schema
"""

import os
import re
import sys
from pathlib import Path
from datetime import datetime
import json
from typing import List, Dict, Tuple
import time
import requests

# 配置
PROJECT_ROOT = Path(r"d:\workspace\superset-github\clickhouse-doc")
CLICKHOUSE_HOST = "localhost"
CLICKHOUSE_PORT = 8123
CLICKHOUSE_USER = "default"
CLICKHOUSE_PASSWORD = ""


class ClickHouseClient:
    """ClickHouse HTTP 客户端"""

    def __init__(self, host=CLICKHOUSE_HOST, port=CLICKHOUSE_PORT,
                 user=CLICKHOUSE_USER, password=CLICKHOUSE_PASSWORD):
        self.base_url = f"http://{host}:{port}"
        self.user = user
        self.password = password
        self.session = requests.Session()
        self.session.timeout = 300

    def execute_query(self, query: str, database: str = None) -> Tuple[bool, str]:
        """执行单个 SQL 查询"""
        try:
            query = query.strip()
            if not query or query.startswith('--') or query.startswith('/*'):
                return True, "Comment - skipped"

            # 移除注释
            query = self._clean_query(query)

            params = {
                'query': query,
                'database': database if database else 'default'
            }

            if self.user:
                params['user'] = self.user
            if self.password:
                params['password'] = self.password

            response = self.session.post(self.base_url, params=params)

            if response.status_code == 200:
                return True, response.text.strip()
            else:
                return False, f"HTTP {response.status_code}: {response.text[:200]}"

        except requests.exceptions.Timeout:
            return False, "Timeout"
        except requests.exceptions.ConnectionError:
            return False, "Connection failed"
        except Exception as e:
            return False, f"Error: {str(e)}"

    def _clean_query(self, query: str) -> str:
        """清理 SQL 查询"""
        query = re.sub(r'/\*.*?\*/', '', query, flags=re.DOTALL)
        lines = []
        for line in query.split('\n'):
            if line.strip().startswith('--'):
                lines.append(line)
            else:
                parts = re.split(r'--.*$', line, maxsplit=1)
                lines.append(parts[0])
        return '\n'.join(lines)


def split_sql_statements(content: str) -> List[str]:
    """分割 SQL 内容为多个语句"""
    content = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)
    statements = []
    buffer = []
    in_string = False
    in_single_quote = False
    in_double_quote = False
    escape = False

    i = 0
    while i < len(content):
        char = content[i]

        # 处理字符串
        if escape:
            escape = False
        elif char == '\\':
            escape = True
        elif char == "'" and not in_double_quote:
            in_single_quote = not in_single_quote
        elif char == '"' and not in_single_quote:
            in_double_quote = not in_double_quote

        # 按分号分割（不在字符串中）
        if char == ';' and not in_single_quote and not in_double_quote:
            stmt = ''.join(buffer).strip()
            if stmt:
                statements.append(stmt)
            buffer = []
        else:
            buffer.append(char)

        i += 1

    # 处理最后一个语句
    if buffer:
        stmt = ''.join(buffer).strip()
        if stmt:
            statements.append(stmt)

    return statements


def execute_sql_file(sql_file: Path, client: ClickHouseClient,
                    results: Dict[str, List[Dict]]) -> int:
    """执行单个 SQL 文件"""
    print(f"\n{'=' * 80}")
    print(f"执行文件: {sql_file.name}")
    print(f"{'=' * 80}")

    file_key = str(sql_file.relative_to(PROJECT_ROOT))
    if file_key not in results:
        results[file_key] = []

    try:
        with open(sql_file, 'r', encoding='utf-8') as f:
            content = f.read()

        statements = split_sql_statements(content)
        total_statements = len(statements)
        success_count = 0
        error_count = 0

        print(f"找到 {total_statements} 个 SQL 语句\n")

        for i, stmt in enumerate(statements, 1):
            stmt = stmt.strip()
            if not stmt:
                continue

            # 检查是否是纯注释（没有 SQL 关键词）
            lines = [line.strip() for line in stmt.split('\n') if line.strip()]
            
            # 如果所有行都是注释行，且没有 SQL 关键词，则跳过
            sql_keywords = ['CREATE', 'ALTER', 'SELECT', 'INSERT', 'UPDATE', 'DELETE', 
                          'DROP', 'TRUNCATE', 'GRANT', 'REVOKE', 'SHOW', 'USE']
            has_sql_keyword = any(
                any(keyword in line.upper() for keyword in sql_keywords)
                for line in lines
            )
            
            if not has_sql_keyword and all(line.startswith('--') for line in lines):
                print(f"[{i}/{total_statements}] 跳过纯注释")
                continue

            print(f"[{i}/{total_statements}] 执行...")

            # 确定数据库
            database = None
            if re.match(r'CREATE\s+DATABASE', stmt, re.IGNORECASE):
                db_match = re.search(r'CREATE\s+DATABASE\s+IF\s+NOT\s+EXISTS\s+(\w+)', stmt, re.IGNORECASE)
                if db_match:
                    database = db_match.group(1)

            success, result = client.execute_query(stmt, database)

            if success:
                success_count += 1
                print(f"  [OK] 成功")
            else:
                error_count += 1
                print(f"  [ERROR] 失败: {result[:100]}")

            results[file_key].append({
                'statement': stmt[:200],
                'success': success,
                'result': result[:500] if success else result,
            })

            time.sleep(0.05)

        print(f"\n文件执行完成: {success_count}/{total_statements} 成功, {error_count} 失败")
        return total_statements

    except Exception as e:
        print(f"\n[ERROR] 文件执行出错: {str(e)}")
        results[file_key].append({
            'statement': 'FILE_READ_ERROR',
            'success': False,
            'result': f"Error: {str(e)}",
        })
        return 0


def main():
    """主函数"""
    if len(sys.argv) < 2:
        print("使用方法: python run_batch_sql.py <目录名>")
        print("\n可用目录:")
        dirs = ["05-data-type", "07-troubleshooting", "08-information-schema", 
                "09-data-deletion", "10-date-update", "11-data-update",
                "11-performance", "12-security-authentication", "13-monitor"]
        for d in dirs:
            print(f"  - {d}")
        sys.exit(1)

    target_dir = sys.argv[1]
    dir_path = PROJECT_ROOT / target_dir

    if not dir_path.exists():
        print(f"错误: 目录不存在: {target_dir}")
        sys.exit(1)

    print("=" * 80)
    print(f"ClickHouse SQL 批量执行工具")
    print(f"目标目录: {target_dir}")
    print("=" * 80)

    client = ClickHouseClient()

    print("\n测试连接...")
    success, result = client.execute_query("SELECT version()")
    if success:
        print(f"[OK] 连接成功: ClickHouse {result}")
    else:
        print(f"[ERROR] 连接失败: {result}")
        sys.exit(1)

    # 扫描 SQL 文件
    print(f"\n扫描目录: {target_dir}")
    sql_files = sorted(dir_path.glob("*_examples.sql"))

    if not sql_files:
        print(f"未找到 SQL 文件")
        sys.exit(0)

    print(f"找到 {len(sql_files)} 个 SQL 文件\n")

    # 执行
    results = {}
    total_statements = 0

    for sql_file in sql_files:
        count = execute_sql_file(sql_file, client, results)
        total_statements += count

    # 生成报告
    print("\n" + "=" * 80)
    print("执行总结")
    print("=" * 80)
    
    total_success = sum(sum(1 for s in stmts if s['success']) for stmts in results.values())
    total_errors = total_statements - total_success

    print(f"文件总数: {len(sql_files)}")
    print(f"语句总数: {total_statements}")
    print(f"成功: {total_success}")
    print(f"失败: {total_errors}")

    # 显示失败的文件
    if total_errors > 0:
        print("\n失败的文件和语句:")
        for file_key, statements in results.items():
            errors = [s for s in statements if not s['success']]
            if errors:
                print(f"\n  {file_key}:")
                for err in errors[:3]:
                    print(f"    - {err['statement'][:80]}")
                if len(errors) > 3:
                    print(f"    ... 还有 {len(errors) - 3} 个错误")

    # 保存详细报告
    report_file = dir_path / f"execution_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(report_file, 'w', encoding='utf-8') as f:
        json.dump({
            'timestamp': datetime.now().isoformat(),
            'directory': target_dir,
            'summary': {
                'total_files': len(sql_files),
                'total_statements': total_statements,
                'total_success': total_success,
                'total_errors': total_errors
            },
            'results': results
        }, f, indent=2, ensure_ascii=False)

    print(f"\n详细报告已保存: {report_file}")

    if total_errors > 0:
        print(f"\n[WARNING] 有 {total_errors} 个语句执行失败")
        sys.exit(1)
    else:
        print("\n[OK] 所有语句执行成功！")
        sys.exit(0)


if __name__ == "__main__":
    main()
