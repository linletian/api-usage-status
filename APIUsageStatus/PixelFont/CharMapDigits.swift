// ⚠️ 本文件已弃用。原像素字模数字字符映射表，因状态栏改回系统字体而不再需要。
// 代码保留供历史参考，待后续彻底删除。参见 ARCHITECTURE.md §2.11 / ADR-003。
#if false

import Foundation

// MARK: - CharMapDigits

/// 3×5 pixel font bitmaps for digits 0-9.
/// Each digit is stored as a 5-row × 3-column [[Bool]] matrix.
/// Row 0 is the visual top of the digit.
enum CharMapDigits {
    static let map: [Character: [[Bool]]] = [
        "0": [
            [true,  true,  true ],
            [true,  false, true ],
            [true,  false, true ],
            [true,  false, true ],
            [true,  true,  true ],
        ],
        "1": [
            [false, true,  false],
            [true,  true,  false],
            [false, true,  false],
            [false, true,  false],
            [true,  true,  true ],
        ],
        "2": [
            [true,  true,  true ],
            [false, false, true ],
            [true,  true,  true ],
            [true,  false, false],
            [true,  true,  true ],
        ],
        "3": [
            [true,  true,  true ],
            [false, false, true ],
            [true,  true,  true ],
            [false, false, true ],
            [true,  true,  true ],
        ],
        "4": [
            [true,  false, true ],
            [true,  false, true ],
            [true,  true,  true ],
            [false, false, true ],
            [false, false, true ],
        ],
        "5": [
            [true,  true,  true ],
            [true,  false, false],
            [true,  true,  true ],
            [false, false, true ],
            [true,  true,  true ],
        ],
        "6": [
            [true,  true,  true ],
            [true,  false, false],
            [true,  true,  true ],
            [true,  false, true ],
            [true,  true,  true ],
        ],
        "7": [
            [true,  true,  true ],
            [false, false, true ],
            [false, false, true ],
            [false, true,  false],
            [false, true,  false],
        ],
        "8": [
            [true,  true,  true ],
            [true,  false, true ],
            [true,  true,  true ],
            [true,  false, true ],
            [true,  true,  true ],
        ],
        "9": [
            [true,  true,  true ],
            [true,  false, true ],
            [true,  true,  true ],
            [false, false, true ],
            [true,  true,  true ],
        ],
    ]
}

#endif // false
