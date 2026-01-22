# 数据加密

数据加密是保护 ClickHouse 中敏感数据的重要手段。本节将介绍如何配置磁盘加密、数据传输加密和列级加密。

## 📑 目录

- [加密概览](#加密概览)
- [磁盘加密](#磁盘加密)
- [数据传输加密](#数据传输加密)
- [列级加密](#列级加密)
- [加密密钥管理](#加密密钥管理)
- [加密性能优化](#加密性能优化)
- [实战示例](#实战示例)

## 加密概览

### 加密类型

| 加密类型 | 说明 | 适用场景 | 性能影响 |
|---------|------|---------|---------|
| **磁盘加密** | 加密整个磁盘或分区 | 物理安全 | 中 |
| **数据传输加密** | 加密网络数据 | 网络安全 | 低 |
| **列级加密** | 加密特定列 | 数据隐私 | 低-中 |
| **文件系统加密** | 加密文件系统 | 操作系统级别 | 中-高 |

### 加密算法

| 算法 | 安全级别 | 性能 | 推荐度 |
|------|---------|------|--------|
| **AES-256-GCM** | 高 | 高 | ⭐⭐⭐⭐⭐ |
| **AES-256-CBC** | 高 | 高 | ⭐⭐⭐⭐ |
| **ChaCha20** | 高 | 高 | ⭐⭐⭐⭐⭐ |
| **AES-128-GCM** | 中高 | 很高 | ⭐⭐⭐ |

## 磁盘加密

### Linux LUKS 加密

```bash
#!/bin/bash

# 1. 安装 LUKS 工具
apt-get install -y cryptsetup

# 2. 创建加密分区
cryptsetup -y -v luksFormat /dev/sdb1

# 3. 打开加密分区
cryptsetup open /dev/sdb1 encrypted_clickhouse

# 4. 格式化加密分区
mkfs.ext4 /dev/mapper/encrypted_clickhouse

# 5. 挂载加密分区
mkdir -p /var/lib/clickhouse
mount /dev/mapper/encrypted_clickhouse /var/lib/clickhouse

# 6. 配置自动挂载
cat >> /etc/crypttab << EOF
encrypted_clickhouse /dev/sdb1 none luks
EOF

cat >> /etc/fstab << EOF
/dev/mapper/encrypted_clickhouse /var/lib/clickhouse ext4 defaults 0 0
EOF
```

### ClickHouse 数据目录加密配置

```bash
#!/bin/bash

# 1. 创建加密数据目录
mkdir -p /encrypted/clickhouse/data

# 2. 配置 ClickHouse 使用加密目录
cat > /etc/clickhouse-server/config.d/encrypted_storage.xml << 'EOF'
<clickhouse>
    <path>/encrypted/clickhouse/data/</path>
    <tmp_path>/encrypted/clickhouse/tmp/</path>
    <user_files_path>/encrypted/clickhouse/user_files/</user_files_path>
    <format_schema_path>/encrypted/clickhouse/format_schemas/</format_schema_path>
</clickhouse>
EOF

# 3. 重启 ClickHouse
systemctl restart clickhouse-server

# 4. 验证加密
ls -la /encrypted/clickhouse/data/
```

### Docker 磁盘加密

```yaml
# docker-compose.yml
version: '3.8'

services:
  clickhouse:
    image: clickhouse/clickhouse-server:latest
    container_name: clickhouse-server
    hostname: clickhouse
    volumes:
      # 使用加密的卷
      - encrypted_data:/var/lib/clickhouse
      - /etc/clickhouse-server/certs:/etc/clickhouse-server/certs:ro
    environment:
      - CLICKHOUSE_DB=default
    ports:
      - "8123:8123"
      - "9000:9000"

# 创建加密卷
volumes:
  encrypted_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /encrypted/clickhouse/data
```

## 数据传输加密

### 数据传输加密配置

数据传输加密已在 [网络安全](./05_network_security.md) 中详细介绍了 SSL/TLS 配置，这里简要回顾关键配置：

```xml
<!-- config.xml -->
<openSSL>
    <server>
        <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
        <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <verificationMode>none</verificationMode>
        <loadDefaultCAFile>false</loadDefaultCAFile>
    </server>
    <client>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <verificationMode>strict</verificationMode>
        <loadDefaultCAFile>false</loadDefaultCAFile>
    </client>
</openSSL>
```

## 列级加密

### 使用 AES 加密函数

ClickHouse 提供了内置的加密函数，可以用于列级数据加密：

```sql
-- 创建加密表
CREATE TABLE IF NOT EXISTS secure.encrypted_users
ON CLUSTER 'treasurycluster'
(
    user_id UInt64,
    username String,
    -- 加密敏感字段
    encrypted_email String,
    -- 加密使用 GCM 模式（需自定义函数）
    encrypted_phone String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/encrypted_users', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);

-- 插入加密数据
INSERT INTO secure.encrypted_users
VALUES
(1, 'alice', encrypt('alice@example.com', 'MySecretKey123!', 'AES'), '...', now()),
(2, 'bob', encrypt('bob@example.com', 'MySecretKey123!', 'AES'), '...', now());

-- 查询时解密
SELECT 
    user_id,
    username,
    decrypt(encrypted_email, 'MySecretKey123!', 'AES') as email,
    decrypt(encrypted_phone, 'MySecretKey123!', 'AES') as phone
FROM secure.encrypted_users
WHERE user_id = 1;
```

### 使用自定义加密函数

```sql
-- 创建自定义加密函数（需要 ClickHouse 支持 UDF）
-- 注意：ClickHouse 社区版不支持 UDF，企业版支持

-- 替代方案：使用应用层加密
-- 1. 应用层使用 AES-256-GCM 加密数据
-- 2. 将加密后的数据存储为 String 或 Binary 类型
-- 3. 查询时在应用层解密

-- 示例：存储加密的 JSON 数据
CREATE TABLE IF NOT EXISTS secure.encrypted_events
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    encrypted_data String,  -- 存储应用层加密的数据
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/encrypted_events', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 插入加密数据（应用层加密后）
INSERT INTO secure.encrypted_events
VALUES
(1, 'alice', '{"email":"encrypted_email","phone":"encrypted_phone"}', now());

-- 查询数据（应用层解密）
SELECT 
    event_id,
    user_id,
    encrypted_data  -- 应用层解密
FROM secure.encrypted_events;
```

### 使用掩码函数（脱敏）

```sql
-- 创建脱敏表
CREATE TABLE IF NOT EXISTS secure.masked_users
ON CLUSTER 'treasurycluster'
(
    user_id UInt64,
    username String,
    email String,
    phone String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/masked_users', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);

-- 插入真实数据
INSERT INTO secure.masked_users
VALUES
(1, 'alice', 'alice@example.com', '+86-138-0000-0000', now()),
(2, 'bob', 'bob@example.com', '+86-139-0000-0000', now());

-- 查询时脱敏
-- 邮箱脱敏：只显示第一个字符和域名
SELECT 
    user_id,
    username,
    concat(substring(email, 1, 1), '***@', splitByChar('@', email)[2]) as masked_email,
    concat('+86-', substring(phone, 5, 3), '****', substring(phone, 13, 4)) as masked_phone
FROM secure.masked_users;
```

## 加密密钥管理

### 密钥存储

```bash
# 方法 1：环境变量
export CLICKHOUSE_ENCRYPTION_KEY="MySecretKey123!"

# 方法 2：密钥文件
echo "MySecretKey123!" > /etc/clickhouse-server/encryption.key
chmod 600 /etc/clickhouse-server/encryption.key

# 方法 3：密钥管理服务（KMS）
# 使用 AWS KMS、Azure Key Vault 或 HashiCorp Vault
```

### 密钥轮换

```bash
#!/bin/bash

# 密钥轮换脚本

# 1. 生成新密钥
NEW_KEY=$(openssl rand -base64 32)
echo $NEW_KEY > /etc/clickhouse-server/encryption.key.new
chmod 600 /etc/clickhouse-server/encryption.key.new

# 2. 重新加密数据
# 注意：需要应用层支持密钥轮换
# 这里仅展示概念，实际实现取决于应用

# 3. 更新配置
# /etc/clickhouse-server/config.d/encryption.xml

# 4. 重启 ClickHouse
systemctl restart clickhouse-server

# 5. 备份并删除旧密钥
mv /etc/clickhouse-server/encryption.key /etc/clickhouse-server/encryption.key.backup
mv /etc/clickhouse-server/encryption.key.new /etc/clickhouse-server/encryption.key

echo "密钥轮换完成"
```

### 使用外部密钥管理服务

```python
# 使用 HashiCorp Vault 管理加密密钥
import hvac
import requests

class VaultKeyManager:
    def __init__(self, vault_url, vault_token):
        self.client = hvac.Client(url=vault_url, token=vault_token)
    
    def get_key(self, key_path):
        """从 Vault 获取密钥"""
        response = self.client.secrets.kv.v2.read_secret_version(
            path=key_path
        )
        return response['data']['data']['key']
    
    def rotate_key(self, key_path, new_key):
        """轮换密钥"""
        self.client.secrets.kv.v2.create_or_update_secret(
            path=key_path,
            secret={'key': new_key}
        )

# 使用示例
vault = VaultKeyManager(
    vault_url='https://vault.company.com:8200',
    vault_token='your-vault-token'
)

# 获取密钥
encryption_key = vault.get_key('clickhouse/encryption')

# 使用密钥加密数据
# ... 加密逻辑 ...
```

## 加密性能优化

### 性能对比

| 加密类型 | 读性能 | 写性能 | CPU 开销 |
|---------|--------|--------|---------|
| **无加密** | 100% | 100% | 0% |
| **传输加密** | 98% | 98% | 5% |
| **列级加密** | 95% | 95% | 10% |
| **磁盘加密** | 90% | 90% | 15% |

### 优化策略

```sql
-- 1. 只加密必要列
CREATE TABLE IF NOT EXISTS secure.optimized_users
ON CLUSTER 'treasurycluster'
(
    user_id UInt64,
    username String,
    -- 只加密敏感列
    encrypted_email String,  -- 加密
    encrypted_phone String,  -- 加密
    -- 非敏感列不加密
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/optimized_users', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);

-- 2. 使用物化视图加速查询
CREATE MATERIALIZED VIEW IF NOT EXISTS secure.users_email_view
ENGINE = ReplicatedAggregatingMergeTree()
AS SELECT
    user_id,
    decrypt(encrypted_email, 'MySecretKey123!', 'AES') as email,
    count() as count
FROM secure.encrypted_users
GROUP BY user_id, email;

-- 3. 使用缓存
SET use_query_cache = 1;

SELECT 
    user_id,
    decrypt(encrypted_email, 'MySecretKey123!', 'AES') as email
FROM secure.encrypted_users
WHERE user_id = 1;
```

## 实战示例

### 示例 1: 完整的数据加密方案

```sql
-- 1. 创建加密表
CREATE TABLE IF NOT EXISTS secure.sensitive_data
ON CLUSTER 'treasurycluster'
(
    id UInt64,
    user_id String,
    -- 敏感数据加密存储
    encrypted_name String,
    encrypted_email String,
    encrypted_phone String,
    encrypted_address String,
    encrypted_ssn String,
    -- 非敏感数据不加密
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/sensitive_data', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (id, created_at);

-- 2. 插入加密数据（应用层加密）
-- 示例：使用 Python 加密
"""
import hashlib
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad
import base64

def encrypt_data(data, key):
    """加密数据"""
    # 生成 IV
    iv = hashlib.md5(key.encode()).digest()
    
    # 创建加密器
    cipher = AES.new(key.encode(), AES.MODE_CBC, iv)
    
    # 加密数据
    encrypted_data = cipher.encrypt(pad(data.encode(), AES.block_size))
    
    # Base64 编码
    return base64.b64encode(encrypted_data).decode()

def decrypt_data(encrypted_data, key):
    """解密数据"""
    # 生成 IV
    iv = hashlib.md5(key.encode()).digest()
    
    # 创建解密器
    cipher = AES.new(key.encode(), AES.MODE_CBC, iv)
    
    # 解密数据
    decrypted_data = unpad(cipher.decrypt(base64.b64decode(encrypted_data)), AES.block_size)
    
    return decrypted_data.decode()

# 使用示例
key = "MySecretKey123!"
data = "Alice Smith"
encrypted = encrypt_data(data, key)
print(f"Encrypted: {encrypted}")

decrypted = decrypt_data(encrypted, key)
print(f"Decrypted: {decrypted}")
"""

-- 3. 查询数据（应用层解密）
SELECT 
    id,
    user_id,
    -- 应用层解密
    encrypted_name,  -- 应用层解密
    encrypted_email,  -- 应用层解密
    encrypted_phone,  -- 应用层解密
    status,
    created_at
FROM secure.sensitive_data
WHERE user_id = 'alice';
```

### 示例 2: 混合加密方案

```sql
-- 1. 创建主表（存储敏感数据）
CREATE TABLE IF NOT EXISTS secure.user_profiles
ON CLUSTER 'treasurycluster'
(
    user_id UInt64,
    username String,
    -- 加密敏感数据
    encrypted_email String,
    encrypted_phone String,
    -- 非敏感数据
    created_at DateTime,
    updated_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/user_profiles', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, updated_at);

-- 2. 创建视图表（存储脱敏数据）
CREATE TABLE IF NOT EXISTS secure.user_profiles_masked
ON CLUSTER 'treasurycluster'
(
    user_id UInt64,
    username String,
    -- 脱敏数据
    masked_email String,
    masked_phone String,
    created_at DateTime,
    updated_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/user_profiles_masked', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, updated_at);

-- 3. 创建物化视图，自动同步脱敏数据
CREATE MATERIALIZED VIEW IF NOT EXISTS secure.user_profiles_sync_mv
TO secure.user_profiles_masked
AS SELECT
    user_id,
    username,
    -- 脱敏邮箱
    concat(substring(encrypted_email, 1, 1), '***@', 
           substring(encrypted_email, position('@', encrypted_email) + 1)) as masked_email,
    -- 脱敏手机号
    concat(substring(encrypted_phone, 1, 3), '****', 
           substring(encrypted_phone, length(encrypted_phone) - 3, 4)) as masked_phone,
    created_at,
    updated_at
FROM secure.user_profiles;

-- 4. 插入数据
INSERT INTO secure.user_profiles
VALUES
(1, 'alice', 'encrypted_email_alice', 'encrypted_phone_alice', now(), now()),
(2, 'bob', 'encrypted_email_bob', 'encrypted_phone_bob', now(), now());

-- 5. 查询脱敏数据（普通用户）
SELECT * FROM secure.user_profiles_masked;

-- 6. 查询真实数据（特权用户，应用层解密）
SELECT * FROM secure.user_profiles;
```

### 示例 3: 分层加密方案

```sql
-- 第 1 层：公开数据（无加密）
CREATE TABLE IF NOT EXISTS secure.public_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    event_type String,
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/public_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 第 2 层：内部数据（传输加密）
CREATE TABLE IF NOT EXISTS secure.internal_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    event_data String,
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/internal_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 第 3 层：敏感数据（列级加密）
CREATE TABLE IF NOT EXISTS secure.sensitive_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    encrypted_data String,  -- 应用层加密
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/sensitive_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 第 4 层：绝密数据（磁盘加密 + 列级加密）
-- 表存储在加密的磁盘上
CREATE TABLE IF NOT EXISTS secure.top_secret_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    encrypted_data String,  -- 应用层加密
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/top_secret_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS storage_policy = 'encrypted_policy';
```

## 🎯 数据加密最佳实践

1. **最小化加密范围**：只加密必要的敏感数据
2. **使用强加密算法**：使用 AES-256-GCM 或 ChaCha20
3. **密钥管理**：使用专业的密钥管理服务
4. **密钥轮换**：定期轮换加密密钥（每 90 天）
5. **性能测试**：加密前进行性能测试
6. **备份密钥**：安全备份加密密钥
7. **监控性能**：监控加密对性能的影响
8. **分层加密**：根据数据敏感度分层加密

## ⚠️ 注意事项

1. **性能影响**：加密会增加 CPU 和 I/O 开销
2. **密钥安全**：妥善管理加密密钥
3. **备份恢复**：确保备份包含加密密钥
4. **密钥丢失**：密钥丢失将导致数据无法恢复
5. **应用支持**：列级加密需要应用层支持
6. **测试验证**：在生产环境前充分测试

## 📚 相关文档

- [网络安全](./05_network_security.md)
- [用户认证](./01_authentication.md)
- [审计日志](./07_audit_log.md)
- [安全最佳实践](./08_best_practices.md)
