#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Example script demonstrating KVM Eager Page Splitting configuration
# and verification for VM live migration scenarios.
#
# 示例脚本演示KVM急切页面拆分配置和验证用于VM热迁移场景。

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Check if KVM is available
check_kvm() {
    print_section "Checking KVM Availability / 检查KVM可用性"
    
    if [ ! -e /dev/kvm ]; then
        print_error "KVM is not available. Make sure KVM modules are loaded."
        print_error "KVM不可用。确保已加载KVM模块。"
        exit 1
    fi
    
    print_status "KVM is available / KVM可用"
}

# Check current eager_page_split setting
check_eager_page_split() {
    print_section "Current Eager Page Split Configuration / 当前急切页面拆分配置"
    
    if [ -e /sys/module/kvm/parameters/eager_page_split ]; then
        CURRENT=$(cat /sys/module/kvm/parameters/eager_page_split)
        print_status "eager_page_split = $CURRENT"
        
        if [ "$CURRENT" = "Y" ]; then
            print_status "Eager page splitting is ENABLED (recommended for migration)"
            print_status "急切页面拆分已启用（推荐用于迁移）"
        else
            print_warning "Eager page splitting is DISABLED"
            print_warning "急切页面拆分已禁用"
        fi
    else
        print_error "Cannot find eager_page_split parameter"
        print_error "找不到eager_page_split参数"
        exit 1
    fi
}

# Check TDP MMU setting
check_tdp_mmu() {
    print_section "Checking TDP MMU Configuration / 检查TDP MMU配置"
    
    if [ -e /sys/module/kvm/parameters/tdp_mmu ]; then
        TDP_MMU=$(cat /sys/module/kvm/parameters/tdp_mmu)
        print_status "tdp_mmu = $TDP_MMU"
        
        if [ "$TDP_MMU" = "Y" ]; then
            print_status "TDP MMU is ENABLED (required for eager page split)"
            print_status "TDP MMU已启用（急切页面拆分所需）"
        else
            print_error "TDP MMU is DISABLED. Eager page splitting requires tdp_mmu=Y"
            print_error "TDP MMU已禁用。急切页面拆分需要tdp_mmu=Y"
            exit 1
        fi
    else
        print_warning "Cannot find tdp_mmu parameter (may not be on x86-64)"
        print_warning "找不到tdp_mmu参数（可能不在x86-64上）"
    fi
}

# Enable eager page split
enable_eager_page_split() {
    print_section "Enabling Eager Page Split / 启用急切页面拆分"
    
    if [ -e /sys/module/kvm/parameters/eager_page_split ]; then
        echo Y > /sys/module/kvm/parameters/eager_page_split
        print_status "Eager page splitting ENABLED"
        print_status "急切页面拆分已启用"
    else
        print_error "Cannot enable eager_page_split"
        exit 1
    fi
}

# Disable eager page split
disable_eager_page_split() {
    print_section "Disabling Eager Page Split / 禁用急切页面拆分"
    
    if [ -e /sys/module/kvm/parameters/eager_page_split ]; then
        echo N > /sys/module/kvm/parameters/eager_page_split
        print_status "Eager page splitting DISABLED"
        print_status "急切页面拆分已禁用"
    else
        print_error "Cannot disable eager_page_split"
        exit 1
    fi
}

# Check huge page support
check_huge_pages() {
    print_section "Checking Huge Page Support / 检查大页支持"
    
    # Check for 2MB huge pages
    if grep -q "pse" /proc/cpuinfo; then
        print_status "2MB huge pages supported (PSE)"
        print_status "支持2MB大页（PSE）"
    fi
    
    # Check for 1GB huge pages
    if grep -q "pdpe1gb" /proc/cpuinfo; then
        print_status "1GB huge pages supported (PDPE1GB)"
        print_status "支持1GB大页（PDPE1GB）"
    else
        print_warning "1GB huge pages NOT supported by CPU"
        print_warning "CPU不支持1GB大页"
    fi
    
    # Check current huge page configuration
    if [ -d /sys/kernel/mm/hugepages ]; then
        print_status "Available huge page sizes / 可用的大页大小:"
        ls /sys/kernel/mm/hugepages/ | while read size; do
            echo "  - $size"
        done
    fi
}

# Display KVM statistics for a VM (if available)
display_vm_stats() {
    print_section "VM Page Statistics / VM页面统计信息"
    
    if [ -d /sys/kernel/debug/kvm ]; then
        print_status "KVM debug filesystem available"
        
        # List VMs
        VM_COUNT=$(ls -d /sys/kernel/debug/kvm/[0-9]* 2>/dev/null | wc -l)
        if [ "$VM_COUNT" -gt 0 ]; then
            print_status "Found $VM_COUNT running VM(s)"
            
            ls -d /sys/kernel/debug/kvm/[0-9]* 2>/dev/null | while read vm_path; do
                VM_ID=$(basename "$vm_path")
                echo ""
                print_status "VM ID: $VM_ID"
                
                if [ -f "$vm_path/stats" ]; then
                    echo "  Page statistics / 页面统计:"
                    grep -E "pages_4k|pages_2m|pages_1g" "$vm_path/stats" || \
                        print_warning "  No page statistics available"
                fi
            done
        else
            print_warning "No running VMs found"
            print_warning "未找到运行中的VM"
        fi
    else
        print_warning "KVM debug filesystem not available. Mount with:"
        print_warning "KVM调试文件系统不可用。使用以下命令挂载："
        echo "  mount -t debugfs none /sys/kernel/debug"
    fi
}

# Run the selftest (if available)
run_selftest() {
    print_section "Running Self-Test / 运行自测试"
    
    TEST_PATH="tools/testing/selftests/kvm/x86/dirty_log_page_splitting_test"
    
    if [ -f "$TEST_PATH" ]; then
        print_status "Found test program at $TEST_PATH"
        print_status "Running test..."
        
        if "$TEST_PATH"; then
            print_status "Test PASSED / 测试通过"
        else
            print_error "Test FAILED / 测试失败"
            return 1
        fi
    else
        print_warning "Test program not found. Build with:"
        print_warning "测试程序未找到。使用以下命令构建："
        echo "  cd tools/testing/selftests/kvm && make"
    fi
}

# Print usage recommendations
print_recommendations() {
    print_section "Recommendations / 建议"
    
    cat <<EOF
For live migration scenarios / 对于热迁移场景:
  ✓ Enable eager_page_split (default) / 启用eager_page_split（默认）
  ✓ Enable tdp_mmu (default) / 启用tdp_mmu（默认）
  ✓ Use huge pages (2MB or 1GB) for guest memory / 为客户机内存使用大页（2MB或1GB）

For read-heavy workloads / 对于读取密集型工作负载:
  • Consider disabling eager_page_split / 考虑禁用eager_page_split
  • This preserves huge pages for read performance / 这保留了大页以提高读取性能

To configure at boot time / 在启动时配置:
  Add to kernel command line / 添加到内核命令行:
    kvm.eager_page_split=Y    (enable / 启用)
    kvm.eager_page_split=N    (disable / 禁用)

To configure at runtime / 在运行时配置:
  echo Y > /sys/module/kvm/parameters/eager_page_split
  echo N > /sys/module/kvm/parameters/eager_page_split
EOF
}

# Main function
main() {
    case "${1:-status}" in
        status)
            check_kvm
            check_tdp_mmu
            check_eager_page_split
            check_huge_pages
            display_vm_stats
            print_recommendations
            ;;
        enable)
            check_root
            enable_eager_page_split
            check_eager_page_split
            ;;
        disable)
            check_root
            disable_eager_page_split
            check_eager_page_split
            ;;
        test)
            run_selftest
            ;;
        help|--help|-h)
            cat <<EOF
Usage: $0 [command]

Commands / 命令:
  status   - Show current configuration (default) / 显示当前配置（默认）
  enable   - Enable eager page splitting / 启用急切页面拆分
  disable  - Disable eager page splitting / 禁用急切页面拆分
  test     - Run self-test program / 运行自测试程序
  help     - Show this help message / 显示此帮助信息

Examples / 示例:
  $0 status          # Check current settings
  $0 enable          # Enable eager page split
  $0 disable         # Disable eager page split
  $0 test            # Run tests

Description / 描述:
This script helps configure and verify KVM Eager Page Splitting,
which improves VM live migration performance by proactively splitting
large pages (including 1GB pages) into 4KB pages before migration.

此脚本帮助配置和验证KVM急切页面拆分功能，通过在迁移前主动将大页
（包括1GB大页）拆分成4KB页面来提高VM热迁移性能。
EOF
            ;;
        *)
            print_error "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
