# kexec 签名验证问题修复说明

## 问题描述

用户问题：为什么我的镜像有签名还是会出现 "Enforced kernel signature verification failed" 的错误？

## 根本原因

在 `kernel/kexec_file.c` 文件中，`kimage_validate_signature` 函数的签名验证逻辑存在一个问题：

当内核镜像加载器（image loader）没有实现 `verify_sig` 回调函数时：
- 函数会返回 `-EKEYREJECTED` 错误码
- 如果启用了 `sig_enforce`（强制签名验证），系统会拒绝加载镜像
- 错误消息是："Enforced kernel signature verification failed"

**问题在于**：这个错误消息没有区分以下两种情况：
1. 镜像加载器不支持签名验证（loader 没有 verify_sig 功能）
2. 镜像签名验证失败（签名无效或被篡改）

## 什么时候会遇到这个问题？

### 场景 1：使用不支持签名验证的镜像格式
- 某些架构或镜像格式的加载器没有实现 `verify_sig` 回调
- 例如：某些 ELF 格式的内核镜像加载器
- 即使镜像有签名，加载器也无法验证

### 场景 2：缺少相应的配置选项
不同架构需要不同的配置选项来启用签名验证：
- x86: `CONFIG_KEXEC_BZIMAGE_VERIFY_SIG`
- ARM64: `CONFIG_KEXEC_IMAGE_VERIFY_SIG`
- s390: `CONFIG_KEXEC_SIG`

如果这些选项未启用，对应的 `verify_sig` 回调就不会被编译进去。

## 修复方案

本补丁做了以下改进：

### 1. 使用更合适的错误码
- 从 `-EKEYREJECTED`（密钥被拒绝）改为 `-EOPNOTSUPP`（操作不支持）
- 这样可以明确区分"不支持"和"验证失败"两种情况

### 2. 改进错误消息
修改后的错误消息会明确告知：

**当加载器不支持签名验证时：**
```
Kernel image loader does not support signature verification.
```

**当签名验证失败时：**
```
Enforced kernel signature verification failed (-129).
```

### 3. 调试信息也做了相应改进
在非强制模式下（sig_enforce = false），调试信息也会区分这两种情况。

## 代码更改

### kernel/kexec_file.c 第 163-172 行
```c
static int kexec_image_verify_sig(struct kimage *image, void *buf,
				  unsigned long buf_len)
{
	if (!image->fops || !image->fops->verify_sig) {
		pr_debug("kernel loader does not support signature verification.\n");
		return -EOPNOTSUPP;  // 改为 EOPNOTSUPP
	}

	return image->fops->verify_sig(buf, buf_len);
}
```

### kernel/kexec_file.c 第 175-208 行
```c
static int
kimage_validate_signature(struct kimage *image)
{
	int ret;

	ret = kexec_image_verify_sig(image, image->kernel_buf,
				     image->kernel_buf_len);
	if (ret) {

		if (sig_enforce) {
			// 区分不支持和验证失败
			if (ret == -EOPNOTSUPP)
				pr_notice("Kernel image loader does not support signature verification.\n");
			else
				pr_notice("Enforced kernel signature verification failed (%d).\n", ret);
			return ret;
		}

		// ... IMA 回退逻辑 ...

		// 调试信息也做相应区分
		if (ret == -EOPNOTSUPP)
			pr_debug("kernel loader does not support signature verification (%d).\n", ret);
		else
			pr_debug("kernel signature verification failed (%d).\n", ret);
	}

	return 0;
}
```

## 用户应该如何解决这个问题？

根据新的错误消息，用户可以采取以下措施：

### 如果看到 "Kernel image loader does not support signature verification"

这意味着您使用的内核镜像格式或架构不支持签名验证。可以：

1. **更换镜像格式**
   - 在 x86 上使用 bzImage 格式（而不是 ELF）
   - 确保使用支持 PE 签名的格式

2. **启用相应的配置选项**
   - 重新编译内核，启用适合您架构的签名验证选项：
     - x86: `CONFIG_KEXEC_BZIMAGE_VERIFY_SIG=y`
     - ARM64: `CONFIG_KEXEC_IMAGE_VERIFY_SIG=y`
     - s390: `CONFIG_KEXEC_SIG=y`

3. **禁用强制签名验证**（如果签名验证不是必需的）
   - 取消 `CONFIG_KEXEC_SIG_FORCE` 配置
   - 允许 IMA 进行签名验证（如果配置了 IMA）

### 如果看到 "Enforced kernel signature verification failed"

这意味着签名验证功能正常，但是签名本身有问题：

1. 检查镜像是否正确签名
2. 验证使用的签名密钥是否在系统信任的密钥环中
3. 检查签名格式是否正确（PE 签名）

## 总结

这个补丁通过使用更准确的错误码和更清晰的错误消息，帮助用户快速定位问题所在：
- 是加载器功能限制（需要更换格式或启用配置）
- 还是签名本身的问题（需要修复签名）

这样可以避免用户在已经正确签名镜像的情况下，还要花费大量时间排查为什么"签名验证失败"。
