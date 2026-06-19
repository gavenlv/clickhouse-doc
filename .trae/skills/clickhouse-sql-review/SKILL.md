---
name: "clickhouse-sql-review"
description: "Reviews ClickHouse SQL queries for performance, syntax, and best practices. Invoke when user writes/modifies ClickHouse SQL or requests SQL review."
---

# ClickHouse SQL Review Skill

This skill provides comprehensive SQL review for ClickHouse queries, focusing on performance optimization, syntax validation, and best practices.

## When to Invoke

**Automatically invoke this skill when:**
- User writes or modifies ClickHouse SQL queries
- User asks for SQL review or optimization
- User creates new tables or views in ClickHouse
- User encounters performance issues with ClickHouse queries
- User asks about ClickHouse query best practices

## Review Checklist

### 1. Performance Analysis

**Query Structure:**
- Check for unnecessary `SELECT *` - recommend explicit column selection
- Identify missing `LIMIT` clauses in exploratory queries
- Review `JOIN` operations - prefer ClickHouse-specific join types
- Check for suboptimal `WHERE` clause ordering
- Analyze `GROUP BY` efficiency

**Index & Partition Usage:**
- Verify primary key usage in `WHERE` clauses
- Check partition key alignment with query filters
- Identify queries that scan full tables unnecessarily
- Review `ORDER BY` alignment with primary key

**Aggregation Optimization:**
- Check for `GROUP BY` with high cardinality columns
- Review use of `-State` and `-Merge` combinators
- Identify opportunities for `SimpleAggregateFunction`
- Verify appropriate use of `sum()`, `count()`, etc.

### 2. Syntax Validation

**Common Issues:**
- Verify proper quoting of identifiers and strings
- Check `ARRAY` and `TUPLE` syntax
- Validate `CAST` operations
- Review `NULL` handling (ClickHouse-specific behavior)
- Check for proper use of `FINAL` modifier

**ClickHouse-Specific Features:**
- Validate `MergeTree` family table engine syntax
- Check `TTL` expressions
- Review `SAMPLE` clause usage
- Verify `PREWHERE` vs `WHERE` usage

### 3. Best Practices

**Table Design:**
- Recommend appropriate table engines (MergeTree, ReplicatedMergeTree, etc.)
- Suggest optimal `ORDER BY` / `PRIMARY KEY` definitions
- Review partitioning strategy
- Check data skipping indices

**Query Patterns:**
- Prefer `PREWHERE` for filtering on partition/primary key columns
- Use `LIMIT BY` for efficient pagination
- Recommend materialized views for frequent aggregations
- Suggest dictionary usage for lookups

**Memory Management:**
- Check for queries that may cause memory overflow
- Review `max_memory_usage` implications
- Identify opportunities for external sorting

### 4. Security Considerations

- Check for SQL injection vulnerabilities
- Review user permissions for table access
- Verify sensitive data handling

## Review Output Format

When reviewing SQL, provide:

```markdown
## SQL Review Report

### Summary
[Brief overview of query purpose and overall assessment]

### Issues Found

#### 🔴 Critical
- [Performance-critical issues that must be fixed]

#### 🟡 Warnings
- [Non-critical issues that should be addressed]

#### 🟢 Suggestions
- [Optimization opportunities and best practice recommendations]

### Detailed Analysis

#### Performance
- [Detailed performance analysis with specific recommendations]

#### Best Practices
- [Best practices alignment and suggestions]

#### Alternative Approaches
- [Better ways to achieve the same result, if applicable]

### Optimized Query
```sql
[Provide optimized version of the query if improvements are possible]
```

### Explanation
[Explain the changes made and why they improve the query]
```

## Example Review

**Input Query:**
```sql
SELECT * 
FROM user_events 
WHERE event_date >= '2024-01-01'
  AND user_id = 12345
```

**Review Output:**
```markdown
## SQL Review Report

### Summary
Query filters events for a specific user and date range. Overall structure is good but has optimization opportunities.

### Issues Found

#### 🟡 Warnings
- `SELECT *` retrieves all columns - may impact performance and memory usage

#### 🟢 Suggestions
- Add `LIMIT` clause to prevent large result sets
- Consider using `PREWHERE` for `event_date` filter (partition key)
- Explicitly select needed columns

### Optimized Query
```sql
SELECT 
    event_date,
    event_time,
    event_type,
    event_data
FROM user_events 
PREWHERE event_date >= '2024-01-01'
WHERE user_id = 12345
LIMIT 1000
```

### Explanation
- `PREWHERE` moves partition filtering earlier in execution
- Explicit column selection reduces memory usage
- `LIMIT` prevents unexpected large result sets
```

## Integration Tips

1. **Before Query Execution**: Always review queries before running them in production
2. **After Schema Changes**: Review queries that interact with modified tables
3. **Performance Baseline**: Compare query performance before and after optimizations
4. **Documentation**: Document optimization decisions for future reference

## Common ClickHouse Anti-Patterns

Avoid these patterns and suggest alternatives:

1. ❌ `SELECT * FROM large_table` → ✅ Select specific columns
2. ❌ `WHERE lower(column) = 'value'` → ✅ Use case-insensitive comparison or normalize data
3. ❌ `JOIN` on non-key columns → ✅ Use dictionaries or denormalize
4. ❌ `GROUP BY` without `LIMIT` on high cardinality → ✅ Add `LIMIT` or use `topK`
5. ❌ Multiple `OR` conditions → ✅ Use `IN` clause
6. ❌ `ORDER BY` non-indexed column on large result → ✅ Limit before ordering

## Tools and Commands

When reviewing, consider suggesting:

- `EXPLAIN PLAN` - to analyze query execution plan
- `EXPLAIN PIPELINE` - to see query pipeline
- `SYSTEM FLUSH LOGS` followed by `system.query_log` - for performance analysis
- `system.parts` - to check partition and primary key info

---

**Note**: This skill focuses on ClickHouse-specific optimizations. For general SQL best practices, combine with standard SQL review guidelines.
