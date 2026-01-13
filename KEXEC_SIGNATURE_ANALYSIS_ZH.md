# kexec 镜像签名验证失败问题深度分析

## 问题描述

用户提问：**镜像有签名但是仍然出现 "Enforced kernel signature verification failed" 错误**

本文档基于原有代码逻辑，深入分析可能导致此问题的各种原因。

---

## 一、签名验证流程分析

### 1.1 代码调用链路

```
kexec_file_load() 系统调用
    ↓
kimage_file_alloc_init()
    ↓
kimage_file_prepare_segments()
    ↓
kimage_validate_signature()    [kernel/kexec_file.c:175]
    ↓
kexec_image_verify_sig()       [kernel/kexec_file.c:163]
    ↓
image->fops->verify_sig()      [架构相关实现]
    ↓
kexec_kernel_verify_pe_sig()   [kernel/kexec_file.c:147]
    ↓
verify_pefile_signature()      [crypto/asymmetric_keys/verify_pefile.c]
```

### 1.2 关键函数源码解析

#### kexec_image_verify_sig() - 第一道关卡
```c
static int kexec_image_verify_sig(struct kimage *image, void *buf,
				  unsigned long buf_len)
{
	if (!image->fops || !image->fops->verify_sig) {
		pr_debug("kernel loader does not support signature verification.\n");
		return -EKEYREJECTED;
	}

	return image->fops->verify_sig(buf, buf_len);
}
```

**关键点**：
- 检查 `image->fops->verify_sig` 是否存在
- 如果不存在，直接返回 `-EKEYREJECTED` (错误码 -129)
- 如果存在，调用具体的验证实现

#### kimage_validate_signature() - 决策中心
```c
static int
kimage_validate_signature(struct kimage *image)
{
	int ret;

	ret = kexec_image_verify_sig(image, image->kernel_buf,
				     image->kernel_buf_len);
	if (ret) {

		if (sig_enforce) {
			pr_notice("Enforced kernel signature verification failed (%d).\n", ret);
			return ret;
		}

		/*
		 * If IMA is guaranteed to appraise a signature on the kexec
		 * image, permit it even if the kernel is otherwise locked
		 * down.
		 */
		if (!ima_appraise_signature(READING_KEXEC_IMAGE) &&
		    security_locked_down(LOCKDOWN_KEXEC))
			return -EPERM;

		pr_debug("kernel signature verification failed (%d).\n", ret);
	}

	return 0;
}
```

**关键点**：
- 如果 `sig_enforce = true`（强制验证模式），任何错误都会导致失败
- 如果 `sig_enforce = false`，会尝试通过 IMA 验证作为后备方案
- 错误码通过 `ret` 传递，但错误消息不够详细

#### kexec_kernel_verify_pe_sig() - PE 签名验证
```c
int kexec_kernel_verify_pe_sig(const char *kernel, unsigned long kernel_len)
{
	int ret;

	ret = verify_pefile_signature(kernel, kernel_len,
				      VERIFY_USE_SECONDARY_KEYRING,
				      VERIFYING_KEXEC_PE_SIGNATURE);
	if (ret == -ENOKEY && IS_ENABLED(CONFIG_INTEGRITY_PLATFORM_KEYRING)) {
		ret = verify_pefile_signature(kernel, kernel_len,
					      VERIFY_USE_PLATFORM_KEYRING,
					      VERIFYING_KEXEC_PE_SIGNATURE);
	}
	return ret;
}
```

**关键点**：
- 首先使用 secondary keyring（辅助密钥环）验证
- 如果返回 `-ENOKEY`（找不到密钥），尝试使用 platform keyring（平台密钥环）
- 这是 x86/ARM64 等架构的标准 PE 签名验证路径

---

## 二、镜像有签名但验证失败的可能原因

### 原因 1：镜像加载器不支持签名验证

**现象**：
```
kernel loader does not support signature verification.
Enforced kernel signature verification failed (-129).
```

**根本原因**：
- `image->fops->verify_sig` 为 NULL
- 即：当前使用的镜像格式加载器没有实现签名验证功能

**具体场景**：

#### 场景 1.1：使用了不支持签名的镜像格式
例如在 x86 上：
- bzImage 格式：`kexec_bzImage64_ops` 有条件编译的 `verify_sig`
- 其他格式（如某些 ELF）：可能没有实现 `verify_sig`

```c
// arch/x86/kernel/kexec-bzimage64.c
const struct kexec_file_ops kexec_bzImage64_ops = {
	.probe = bzImage64_probe,
	.load = bzImage64_load,
	.cleanup = bzImage64_cleanup,
#ifdef CONFIG_KEXEC_BZIMAGE_VERIFY_SIG  // 注意这里
	.verify_sig = kexec_kernel_verify_pe_sig,
#endif
};
```

#### 场景 1.2：缺少编译配置选项
即使使用支持签名的格式，如果缺少配置：
- x86 需要：`CONFIG_KEXEC_BZIMAGE_VERIFY_SIG=y`
- ARM64 需要：`CONFIG_KEXEC_IMAGE_VERIFY_SIG=y`
- s390 需要：`CONFIG_KEXEC_SIG=y`

**检查方法**：
```bash
# 检查内核配置
grep CONFIG_KEXEC /boot/config-$(uname -r)
grep CONFIG_KEXEC_BZIMAGE_VERIFY_SIG /boot/config-$(uname -r)
```

---

### 原因 2：签名格式不正确

**现象**：
```
Enforced kernel signature verification failed (-74).  # -EBADMSG
```

**根本原因**：
- 镜像有签名，但签名格式不符合要求
- PE 签名验证要求特定的签名结构

**具体场景**：

#### 场景 2.1：签名类型不匹配
- x86/ARM64 的 PE 镜像需要 PE/PKCS#7 签名
- 如果使用了其他类型的签名（如 GPG 签名），验证会失败

#### 场景 2.2：签名被破坏
- 镜像在传输或存储过程中被修改
- 签名数据损坏或不完整

**检查方法**：
```bash
# 检查 PE 签名（需要 pesign 工具）
pesign -S -i vmlinuz

# 检查签名是否存在
objdump -h vmlinuz | grep .sign
```

---

### 原因 3：签名密钥不在信任链中

**现象**：
```
Enforced kernel signature verification failed (-126).  # -ENOKEY
```

**根本原因**：
- 镜像签名正确，但签名所用的密钥不在系统信任的密钥环中
- 验证失败因为找不到可信的公钥来验证签名

**详细分析**：

`kexec_kernel_verify_pe_sig()` 会依次尝试两个密钥环：

1. **Secondary Keyring（辅助密钥环）**
   - 路径：`VERIFY_USE_SECONDARY_KEYRING`
   - 包含：系统管理员添加的额外可信密钥
   - 查看：`keyctl list %:.secondary_trusted_keys`

2. **Platform Keyring（平台密钥环）**
   - 路径：`VERIFY_USE_PLATFORM_KEYRING`
   - 包含：UEFI/固件提供的密钥（如 UEFI db）
   - 仅当 `CONFIG_INTEGRITY_PLATFORM_KEYRING` 启用且第一次失败时尝试

**常见情况**：

#### 情况 3.1：使用了自签名证书
- 用户用自己生成的密钥对镜像签名
- 但该密钥的公钥没有导入到系统密钥环

**解决方法**：
```bash
# 将公钥导入 secondary keyring
keyctl padd asymmetric "" %:.secondary_trusted_keys < my-public-key.der
```

#### 情况 3.2：密钥已过期或被吊销
- 签名时使用的证书已经过期
- 证书在 CRL（证书吊销列表）中

#### 情况 3.3：证书链不完整
- PE 签名可能需要完整的证书链
- 中间 CA 证书缺失

**检查方法**：
```bash
# 查看系统密钥环
cat /proc/keys

# 查看 secondary keyring
keyctl list %:.secondary_trusted_keys

# 查看平台密钥（需要 mokutil）
mokutil --list-enrolled
```

---

### 原因 4：签名算法不支持

**现象**：
```
Enforced kernel signature verification failed (-524).  # -ENOTSUPP
```

**根本原因**：
- 签名使用的算法系统不支持
- 常见于旧内核或编译时未包含某些加密算法

**具体场景**：

#### 场景 4.1：哈希算法不支持
PE 签名常用的哈希算法：
- SHA-256（最常见）
- SHA-384
- SHA-512

如果内核编译时未包含对应的哈希算法模块，验证会失败。

#### 场景 4.2：非对称加密算法不支持
常用的签名算法：
- RSA（最常见）
- ECDSA

**检查方法**：
```bash
# 检查内核支持的加密算法
grep -E "CONFIG_CRYPTO_SHA256|CONFIG_CRYPTO_RSA" /boot/config-$(uname -r)

# 查看已加载的加密模块
lsmod | grep -E "sha256|rsa"
```

---

### 原因 5：签名验证函数返回其他错误

**可能的其他错误码**：

| 错误码 | 宏定义 | 含义 | 可能原因 |
|--------|--------|------|----------|
| -1 | -EPERM | 操作不允许 | SELinux/AppArmor 策略阻止 |
| -12 | -ENOMEM | 内存不足 | 系统资源不足 |
| -22 | -EINVAL | 无效参数 | 签名数据格式错误 |
| -74 | -EBADMSG | 消息损坏 | 签名结构无效 |
| -84 | -EILSEQ | 非法序列 | 证书编码错误 |
| -126 | -ENOKEY | 密钥不存在 | 信任链中找不到公钥 |
| -129 | -EKEYREJECTED | 密钥被拒绝 | 密钥已过期或被撤销 |

---

## 三、sig_enforce 的影响

### 3.1 什么是 sig_enforce

```c
#ifdef CONFIG_KEXEC_SIG
static bool sig_enforce = IS_ENABLED(CONFIG_KEXEC_SIG_FORCE);
```

- 编译时配置：`CONFIG_KEXEC_SIG_FORCE`
- 如果启用，`sig_enforce` 默认为 `true`
- 可在内核启动参数中覆盖（某些发行版）

### 3.2 sig_enforce = true 时的行为

```c
if (sig_enforce) {
	pr_notice("Enforced kernel signature verification failed (%d).\n", ret);
	return ret;
}
```

**特点**：
- ✅ **严格模式**：任何验证错误都会导致 kexec 失败
- ✅ 包括 "不支持验证" 的情况（返回 -EKEYREJECTED）
- ❌ 不会尝试 IMA 后备验证
- ❌ 不会考虑 lockdown 状态

### 3.3 sig_enforce = false 时的行为

```c
if (!ima_appraise_signature(READING_KEXEC_IMAGE) &&
    security_locked_down(LOCKDOWN_KEXEC))
	return -EPERM;

pr_debug("kernel signature verification failed (%d).\n", ret);
```

**特点**：
- ✅ **宽松模式**：验证失败后有后备方案
- ✅ 如果 IMA 可以验证签名，允许继续
- ✅ 考虑系统 lockdown 状态
- ⚠️ 验证失败只输出 debug 级别日志

---

## 四、IMA 作为后备验证机制

### 4.1 IMA (Integrity Measurement Architecture)

当 kexec 自身的签名验证失败但 `sig_enforce = false` 时，系统会尝试通过 IMA 验证：

```c
if (!ima_appraise_signature(READING_KEXEC_IMAGE) &&
    security_locked_down(LOCKDOWN_KEXEC))
	return -EPERM;
```

**逻辑解读**：
- `ima_appraise_signature(READING_KEXEC_IMAGE)` 返回 0：IMA 可以验证
- 如果 IMA 可以验证 **且** 系统未处于 lockdown 状态：允许加载
- 如果 IMA 不能验证 **且** 系统处于 lockdown 状态：拒绝加载

### 4.2 IMA 验证的要求

IMA 可以作为后备，但需要：
1. `CONFIG_IMA_APPRAISE=y`
2. 配置了合适的 IMA 策略
3. 镜像有 IMA 扩展属性（xattr）签名：`security.ima`

**检查方法**：
```bash
# 检查文件的 IMA 签名
getfattr -n security.ima /path/to/kernel

# 查看 IMA 策略
cat /sys/kernel/security/ima/policy
```

---

## 五、完整的故障排查流程

### 步骤 1：确定错误码

查看内核日志：
```bash
dmesg | grep -i "signature verification failed"
```

记录错误码，例如：`(-129)`, `(-126)`, `(-74)` 等

### 步骤 2：检查是否支持签名验证

```bash
# 检查相关配置
grep -E "CONFIG_KEXEC_SIG|CONFIG_KEXEC.*VERIFY" /boot/config-$(uname -r)

# 应该看到：
# CONFIG_KEXEC_SIG=y
# CONFIG_KEXEC_BZIMAGE_VERIFY_SIG=y (x86) 或
# CONFIG_KEXEC_IMAGE_VERIFY_SIG=y (ARM64)
```

如果配置不存在，说明是**原因 1**：加载器不支持验证。

### 步骤 3：检查镜像签名

```bash
# 使用 pesign 检查 PE 签名
pesign -S -i /path/to/kernel

# 或使用 sbverify（来自 sbsigntool）
sbverify --list /path/to/kernel
```

如果显示 "No signature found"，说明镜像根本没有签名。

### 步骤 4：检查签名密钥

```bash
# 查看系统可信密钥
keyctl list %:.builtin_trusted_keys
keyctl list %:.secondary_trusted_keys

# 查看签名使用的证书
pesign -S -i /path/to/kernel
# 记录证书的 CN (Common Name)

# 检查该证书是否在系统密钥环中
keyctl list %:.secondary_trusted_keys | grep "CN"
```

如果找不到对应的证书，说明是**原因 3**：密钥不在信任链中。

### 步骤 5：检查 sig_enforce 状态

```bash
# 查看编译配置
grep CONFIG_KEXEC_SIG_FORCE /boot/config-$(uname -r)

# 如果输出 =y，说明强制验证已启用
```

### 步骤 6：检查系统 lockdown 状态

```bash
# 查看 lockdown 状态
cat /sys/kernel/security/lockdown
```

可能的输出：
- `none` - 未启用
- `integrity` - 完整性模式
- `confidentiality` - 机密性模式（最严格）

---

## 六、针对不同原因的解决方案

### 解决方案 1：加载器不支持签名验证

**选项 A**：更换镜像格式
- x86: 使用 bzImage 而不是 vmlinux
- ARM64: 使用 Image 格式

**选项 B**：重新编译内核，启用签名验证支持
```bash
# 在内核配置中启用
CONFIG_KEXEC_SIG=y
CONFIG_KEXEC_BZIMAGE_VERIFY_SIG=y  # (x86)
CONFIG_SIGNED_PE_FILE_VERIFICATION=y
```

**选项 C**：如果不需要强制验证，禁用 sig_enforce
```bash
# 重新编译时禁用
CONFIG_KEXEC_SIG_FORCE=n
```

### 解决方案 2：签名格式不正确

**重新签名镜像**：
```bash
# 使用 sbsign 工具（PE 签名）
sbsign --key mykey.priv --cert mycert.pem --output vmlinuz.signed vmlinuz

# 使用 pesign 工具
pesign -c mycert -p mykey -i vmlinuz -o vmlinuz.signed -s
```

### 解决方案 3：密钥不在信任链中

**导入签名公钥到系统密钥环**：
```bash
# 转换 PEM 格式到 DER 格式（如需要）
openssl x509 -in mycert.pem -outform DER -out mycert.der

# 导入到 secondary keyring
keyctl padd asymmetric "" %:.secondary_trusted_keys < mycert.der
```

**注意**：
- 某些系统的 secondary keyring 可能是只读的
- 可能需要在 UEFI MOK (Machine Owner Key) 中添加密钥

**通过 MOK 添加密钥（UEFI 系统）**：
```bash
# 导入密钥到 MOK
mokutil --import mycert.der

# 重启后在 MOK 管理界面完成导入
```

### 解决方案 4：签名算法不支持

**重新编译内核，包含所需的加密算法**：
```bash
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_RSA=y
CONFIG_CRYPTO_PKCS7_MESSAGE_PARSER=y
CONFIG_ASYMMETRIC_KEY_TYPE=y
CONFIG_ASYMMETRIC_PUBLIC_KEY_SUBTYPE=y
CONFIG_X509_CERTIFICATE_PARSER=y
```

### 解决方案 5：使用 IMA 作为后备

如果 kexec 签名验证不可行，配置 IMA：

```bash
# 1. 确保 IMA 启用
CONFIG_IMA=y
CONFIG_IMA_APPRAISE=y

# 2. 为镜像添加 IMA 签名
evmctl ima_sign --key /path/to/ima_key.pem /path/to/kernel

# 3. 配置 IMA 策略（例如在 /etc/ima/ima-policy）
appraise func=KEXEC_KERNEL_CHECK appraise_type=imasig

# 4. 重新启动或重新加载 IMA 策略
```

---

## 七、总结

### 镜像有签名但验证失败的主要原因总结：

| 序号 | 原因 | 错误码 | 解决方向 |
|------|------|--------|----------|
| 1 | 加载器不支持签名验证 | -129 (-EKEYREJECTED) | 更换格式/启用CONFIG |
| 2 | 签名格式不正确 | -74 (-EBADMSG) | 重新签名 |
| 3 | 密钥不在信任链中 | -126 (-ENOKEY) | 导入公钥 |
| 4 | 签名算法不支持 | -524 (-ENOTSUPP) | 启用加密模块 |
| 5 | 签名已过期/撤销 | -129 (-EKEYREJECTED) | 使用新证书重新签名 |

### 关键建议：

1. **优先检查配置**：确认内核编译时启用了签名验证支持
2. **验证签名存在**：使用 `pesign -S` 确认镜像确实包含签名
3. **检查密钥链**：确保签名密钥的公钥在系统信任的密钥环中
4. **考虑 sig_enforce**：在调试阶段可以暂时禁用强制验证
5. **IMA 作为后备**：如果 kexec 签名验证不可行，考虑使用 IMA

### 调试技巧：

```bash
# 启用更详细的内核日志
echo 8 > /proc/sys/kernel/printk

# 查看详细的错误信息
dmesg -w | grep -i kexec

# 追踪系统调用
strace -e kexec_file_load kexec -s -l /path/to/kernel
```

---

## 附录：常见发行版的默认配置

### Ubuntu/Debian
- 默认启用 `CONFIG_KEXEC_SIG=y`
- 通常 **不启用** `CONFIG_KEXEC_SIG_FORCE`
- 支持通过 secondary keyring 添加自定义密钥

### Red Hat/Fedora/CentOS
- 启用 `CONFIG_KEXEC_SIG=y`
- 在 RHEL 8+ 上启用 `CONFIG_KEXEC_SIG_FORCE=y`
- Secure Boot 环境下强制验证

### SUSE
- 启用签名验证支持
- 默认不强制验证
- 提供 MOK 管理工具

---

**本分析基于 Linux 内核代码，未做任何修改，仅从源码角度解释签名验证失败的各种可能原因。**
