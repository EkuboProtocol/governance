// Returns 2^n
pub fn exp2(n: u8) -> u128 {
    match n {
        0 => { 0x1 },
        1 => { 0x2 },
        2 => { 0x4 },
        3 => { 0x8 },
        4 => { 0x10 },
        5 => { 0x20 },
        6 => { 0x40 },
        7 => { 0x80 },
        8 => { 0x100 },
        9 => { 0x200 },
        10 => { 0x400 },
        11 => { 0x800 },
        12 => { 0x1000 },
        13 => { 0x2000 },
        14 => { 0x4000 },
        15 => { 0x8000 },
        16 => { 0x10000 },
        17 => { 0x20000 },
        18 => { 0x40000 },
        19 => { 0x80000 },
        20 => { 0x100000 },
        21 => { 0x200000 },
        22 => { 0x400000 },
        23 => { 0x800000 },
        24 => { 0x1000000 },
        25 => { 0x2000000 },
        26 => { 0x4000000 },
        27 => { 0x8000000 },
        28 => { 0x10000000 },
        29 => { 0x20000000 },
        30 => { 0x40000000 },
        31 => { 0x80000000 },
        32 => { 0x100000000 },
        33 => { 0x200000000 },
        34 => { 0x400000000 },
        35 => { 0x800000000 },
        36 => { 0x1000000000 },
        37 => { 0x2000000000 },
        38 => { 0x4000000000 },
        39 => { 0x8000000000 },
        40 => { 0x10000000000 },
        41 => { 0x20000000000 },
        42 => { 0x40000000000 },
        43 => { 0x80000000000 },
        44 => { 0x100000000000 },
        45 => { 0x200000000000 },
        46 => { 0x400000000000 },
        47 => { 0x800000000000 },
        48 => { 0x1000000000000 },
        49 => { 0x2000000000000 },
        50 => { 0x4000000000000 },
        51 => { 0x8000000000000 },
        52 => { 0x10000000000000 },
        53 => { 0x20000000000000 },
        54 => { 0x40000000000000 },
        55 => { 0x80000000000000 },
        56 => { 0x100000000000000 },
        57 => { 0x200000000000000 },
        58 => { 0x400000000000000 },
        59 => { 0x800000000000000 },
        60 => { 0x1000000000000000 },
        61 => { 0x2000000000000000 },
        62 => { 0x4000000000000000 },
        63 => { 0x8000000000000000 },
        64 => { 0x10000000000000000 },
        65 => { 0x20000000000000000 },
        66 => { 0x40000000000000000 },
        67 => { 0x80000000000000000 },
        68 => { 0x100000000000000000 },
        69 => { 0x200000000000000000 },
        70 => { 0x400000000000000000 },
        71 => { 0x800000000000000000 },
        72 => { 0x1000000000000000000 },
        73 => { 0x2000000000000000000 },
        74 => { 0x4000000000000000000 },
        75 => { 0x8000000000000000000 },
        76 => { 0x10000000000000000000 },
        77 => { 0x20000000000000000000 },
        78 => { 0x40000000000000000000 },
        79 => { 0x80000000000000000000 },
        80 => { 0x100000000000000000000 },
        81 => { 0x200000000000000000000 },
        82 => { 0x400000000000000000000 },
        83 => { 0x800000000000000000000 },
        84 => { 0x1000000000000000000000 },
        85 => { 0x2000000000000000000000 },
        86 => { 0x4000000000000000000000 },
        87 => { 0x8000000000000000000000 },
        88 => { 0x10000000000000000000000 },
        89 => { 0x20000000000000000000000 },
        90 => { 0x40000000000000000000000 },
        91 => { 0x80000000000000000000000 },
        92 => { 0x100000000000000000000000 },
        93 => { 0x200000000000000000000000 },
        94 => { 0x400000000000000000000000 },
        95 => { 0x800000000000000000000000 },
        96 => { 0x1000000000000000000000000 },
        97 => { 0x2000000000000000000000000 },
        98 => { 0x4000000000000000000000000 },
        99 => { 0x8000000000000000000000000 },
        100 => { 0x10000000000000000000000000 },
        101 => { 0x20000000000000000000000000 },
        102 => { 0x40000000000000000000000000 },
        103 => { 0x80000000000000000000000000 },
        104 => { 0x100000000000000000000000000 },
        105 => { 0x200000000000000000000000000 },
        106 => { 0x400000000000000000000000000 },
        107 => { 0x800000000000000000000000000 },
        108 => { 0x1000000000000000000000000000 },
        109 => { 0x2000000000000000000000000000 },
        110 => { 0x4000000000000000000000000000 },
        111 => { 0x8000000000000000000000000000 },
        112 => { 0x10000000000000000000000000000 },
        113 => { 0x20000000000000000000000000000 },
        114 => { 0x40000000000000000000000000000 },
        115 => { 0x80000000000000000000000000000 },
        116 => { 0x100000000000000000000000000000 },
        117 => { 0x200000000000000000000000000000 },
        118 => { 0x400000000000000000000000000000 },
        119 => { 0x800000000000000000000000000000 },
        120 => { 0x1000000000000000000000000000000 },
        121 => { 0x2000000000000000000000000000000 },
        122 => { 0x4000000000000000000000000000000 },
        123 => { 0x8000000000000000000000000000000 },
        124 => { 0x10000000000000000000000000000000 },
        125 => { 0x20000000000000000000000000000000 },
        126 => { 0x40000000000000000000000000000000 },
        _ => {
            assert(n == 127, 'exp2');
            0x80000000000000000000000000000000
        },
    }
}
