# kexec Signature Verification Analysis

## Problem Statement
用户反映：镜像已经有签名，但是仍然出现 "Enforced kernel signature verification failed" 错误

Translation: User reports that the image has a signature, but still gets "Enforced kernel signature verification failed" error.

## Root Cause Analysis

### Code Flow
1. `kexec_file_load()` system call (kernel/kexec_file.c:364)
2. → `kimage_file_alloc_init()` (line 305)
3. → `kimage_file_prepare_segments()` (line 217)
4. → `kimage_validate_signature()` (line 241, only if CONFIG_KEXEC_SIG)
5. → `kexec_image_verify_sig()` (line 163)

### The Issue (kernel/kexec_file.c:163-172)

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

**Problem**: When the kernel image format loader doesn't implement the `verify_sig` callback:
- The function returns `-EKEYREJECTED`
- This is treated as a verification failure
- If `sig_enforce` is true (CONFIG_KEXEC_SIG_FORCE), the load fails with error

### When Does This Happen?

Architecture/loader support for signature verification varies:

1. **x86 bzImage64**: Supports verification if `CONFIG_KEXEC_BZIMAGE_VERIFY_SIG` is enabled
   - Uses `kexec_kernel_verify_pe_sig()` for PE signature verification
   
2. **ARM64**: Supports verification if `CONFIG_KEXEC_IMAGE_VERIFY_SIG` is enabled
   - Uses `kexec_kernel_verify_pe_sig()` for PE signature verification

3. **s390**: Has its own verification if `CONFIG_KEXEC_SIG` is enabled
   - Uses custom `s390_verify_sig()` function

4. **Other loaders**: May not implement `verify_sig` at all

### The Confusion

Users may encounter this error in several scenarios:

1. **Scenario A**: Image format loader doesn't support signature verification
   - Example: Using an ELF kernel on an architecture where ELF loader has no verify_sig
   - Image might have signatures in other formats, but loader can't check them
   - Error: "kernel loader does not support signature verification"
   - Result: -EKEYREJECTED → "Enforced kernel signature verification failed"

2. **Scenario B**: Signature verification is supported but signature is invalid/missing
   - Image loader has verify_sig callback
   - Signature check fails (wrong key, corrupted signature, no signature)
   - Result: Actual verification error → "Enforced kernel signature verification failed"

### Current Error Handling (kernel/kexec_file.c:175-201)

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

**Key observation**: 
- When `sig_enforce` is false, the code allows IMA to verify the signature as a fallback
- When `sig_enforce` is true, it immediately fails on any error including -EKEYREJECTED

## Proposed Solutions

### Option 1: Improve Error Messages (Minimal Change)
Change the error message in `kimage_validate_signature` to distinguish between:
- "Loader doesn't support signature verification" (-EKEYREJECTED from missing verify_sig)
- "Signature verification failed" (other error codes)

This helps users understand whether they need to:
- Use a different kernel format that supports signatures
- Fix their kernel signature
- Enable the appropriate CONFIG option for their architecture

### Option 2: Allow IMA Fallback Even with sig_enforce
When the loader doesn't support signature verification (-EKEYREJECTED), allow IMA to verify instead:
- If loader supports verification: strictly enforce it when sig_enforce is true
- If loader doesn't support verification: fall back to IMA if available

This is more flexible but changes the security semantics of CONFIG_KEXEC_SIG_FORCE.

### Option 3: Return Different Error Code for Unsupported
Change `kexec_image_verify_sig` to return a different error code (e.g., -EOPNOTSUPP) when
verify_sig is not implemented, vs -EKEYREJECTED for actual verification failures.

Then handle -EOPNOTSUPP specially in `kimage_validate_signature`.

## Recommendation

**Implement Option 1 (improved error messages) + Option 3 (better error codes)**:

1. Return `-EOPNOTSUPP` when verify_sig callback is not implemented
2. Provide clear, distinct error messages:
   - "Kernel image format does not support signature verification (error: -95)"
   - "Kernel signature verification failed (error: -129)" 
3. When sig_enforce is true and error is -EOPNOTSUPP, consider allowing IMA fallback
4. Document that users should either:
   - Use a kernel image format with signature support
   - Enable CONFIG_KEXEC_*_VERIFY_SIG for their architecture
   - Disable CONFIG_KEXEC_SIG_FORCE if signature verification is not critical

This provides better diagnostics while maintaining security guarantees.
