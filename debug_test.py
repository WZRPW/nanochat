#!/usr/bin/env python3
"""
简单的测试脚本来验证调试功能
"""

def test_function():
    """测试函数，用于设置断点"""
    print("这是一个测试函数")
    x = 10
    y = 20
    result = x + y
    print(f"计算结果: {result}")
    return result

def main():
    """主函数"""
    print("开始调试测试...")
    test_function()
    print("调试测试完成")

if __name__ == "__main__":
    main()
