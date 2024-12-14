use core::num::traits::WideMul;
use super::fp::BitShiftImpl;
use super::fp::UFixedPointTrait;

use crate::utils::fp::{UFixedPoint, UFixedPointShiftImpl};

const SCALE_FACTOR: u256 = 0x100000000000000000000000000000000;

#[test]
fn test_add() {
    let f1 : UFixedPoint = 0xFFFFFFFFFFFFFFFF_u64.into();
    let f2 : UFixedPoint = 1_u64.into();
    let res = f1 + f2;
    let z: u256 = res.into();
    assert(z.low == 0, 'low 0');
    assert(z.high == 18446744073709551616, 'high 18446744073709551616');
}

#[test]
fn test_fp_value_mapping() {
    let f1 : UFixedPoint = 7_u64.into();
    assert(f1.value.limb0 == 0x0, 'limb0 == 0');
    assert(f1.value.limb1 == 0x7, 'limb1 == 7');

    let val: u256 = f1.into();
    assert(val == 7_u256*0x100000000000000000000000000000000, 'val has to be 128 bit shifted');
}


#[test]
fn test_mul() {
    let f1 : UFixedPoint = 7_u64.into();
    let f2 : UFixedPoint = 7_u64.into();

    let expected = (7_u256*SCALE_FACTOR).wide_mul(7_u256*SCALE_FACTOR);
    
    assert(expected.limb0 == 0, 'limb0==0');
    assert(expected.limb1 == 0, 'limb1==0');
    assert(expected.limb2 == 49, 'limb2==0');
    assert(expected.limb3 == 0, 'limb3==0');
    
    let res: u256 = (f1 * f2).into();
    assert(res.high == 49, 'high 49');
    assert(res.low == 0, 'low 0');
}

#[test]
fn test_multiplication() {
    let f1 : UFixedPoint = 9223372036854775808_u128.into();
    assert(f1.value.limb0 == 0, 'f1.limb0 0= 0');
    assert(f1.value.limb1 == 9223372036854775808_u128, 'f1.limb1 != 0');
    assert(f1.value.limb2 == 0, 'f1.limb2 == 0');
    assert(f1.value.limb3 == 0, 'f1.limb3 == 0');

    let res = f1 * f1;

    assert(res.value.limb0 == 0, 'res.limb0 != 0');
    assert(res.value.limb1 == 0x40000000000000000000000000000000, 'res.limb1 != 0');
    assert(res.value.limb2 == 0, 'res.limb2 == 0');
    assert(res.value.limb3 == 0, 'res.limb3 == 0');

    let expected = 9223372036854775808_u128.wide_mul(9223372036854775808_u128) * SCALE_FACTOR;

    assert(expected.low == 0, 'low == 0');
    assert(expected.high == 0x40000000000000000000000000000000, 'high != 0');

    let result: u256 = res.into();
    assert(result == expected, 'unexpected mult result');
}

#[test]
fn test_u256_conversion() {
    let f: u256 = 0x0123456789ABCDEFFEDCBA987654321000112233445566778899AABBCCDDEEFF_u256;
    
    assert(f.low == 0x00112233445566778899AABBCCDDEEFF, 'low');
    assert(f.high == 0x0123456789ABCDEFFEDCBA9876543210, 'high');

    // BITSHIFT DOWN
    let fp: UFixedPoint = f.into();
    assert(fp.get_integer() == f.high, 'integer == f.high');
    assert(fp.get_fractional() == f.low, 'fractional == f.low');
    
    let fp = fp.bitshift_128_down();
    assert(fp.get_integer() == 0, 'integer==0 bs_down');
    assert(fp.get_fractional() == f.high, 'fractional == f.low bs_down');
    
    let fp = fp.bitshift_128_down();
    assert(fp.get_integer() == 0, 'integer==0 bs_down 2');
    assert(fp.get_fractional() == 0, 'fractional == 0 bs_down 2');

    // BITSHIFT UP
    let fp: UFixedPoint = f.into();
    assert(fp.get_integer() == f.high, 'integer == f.high');
    assert(fp.get_fractional() == f.low, 'fractional == f.low');

    let fp = fp.bitshift_128_up();
    assert(fp.get_integer() == f.low, 'integer == f.high bs_up');
    assert(fp.get_fractional() == 0, 'fractional == f.low bs_up');

    let fp = fp.bitshift_128_up();
    assert(fp.get_integer() == 0, 'integer == f.high bs_up');
    assert(fp.get_fractional() == 0, 'fractional == f.low bs_up');
}

fn run_division_test(left: u128, right: u128, expected_int: u128, expected_frac: u128) {
    let f1 : UFixedPoint = left.into();
    let f2 : UFixedPoint = right.into();
    let res = f1 / f2;
    assert(res.get_integer() == expected_int, 'integer');
    assert(res.get_fractional() == expected_frac, 'fractional');
}

fn run_division_and_multiplication_test(numenator: u128, divisor: u128, mult: u128, expected_int: u128, expected_frac: u128) {
    let f1 : UFixedPoint = numenator.into();
    let f2 : UFixedPoint = divisor.into();
    let f3 : UFixedPoint = mult.into();
    let res = f1 / f2 * f3;
    assert(res.get_integer() == expected_int, 'integer');
    assert(res.get_fractional() == expected_frac, 'fractional');
}


#[test]
fn test_division() {
    run_division_test(1, 1000, 0, 0x4189374bc6a7ef9db22d0e56041893);
    run_division_test(56, 7, 8, 0);
    run_division_test(0, 7, 0, 0);

    run_division_test(0x373a1db0ac54ce4e580815828152f, 0x68ee6e5a163cd022760d1bb6eb4a0f7d, 0x0, 0x86bc9e2a429fb89528cb71f24afbb);
    run_division_test(0x6420b39c9a627ed6b97f50bed3887, 0xdfc9859d615e2a1423bb70f42426ceeb, 0x0, 0x728a5f7ea534a5858bd21791663d2);
    run_division_test(0x54948d04aab7daa0ac42f255df182, 0x5d97ed36740f5e528f154b565d039df6, 0x0, 0xe758c9b672eb559b2a09feb6e5082);
    run_division_test(0x3603c70c39769c861d6a9e1c4ab93, 0x1cd625b5488f3b7443f7baf785db9d23, 0x0, 0x1df85f1cabacb5b7af7dbfb4f3eb29);
    run_division_test(0x3454ad56a8a03af36c0c682f80ff4, 0x221ff40a3c0917b64cdc72b7c2201553, 0x0, 0x1889426dabe2220f0bdf5e6d91aa22);
    run_division_test(0xc5151b7adb4f20fec8affdacdbd0, 0x9b9f9c2893ba96b28460bd6651ef35b4, 0x0, 0x144332932b6b6b845eb0619b6460d);
    run_division_test(0x30d4f65bb98392fac119cb0d1a001, 0xe816835b58266378ef4ff98551febaa6, 0x0, 0x35dcf041fc7c566cee3c08524ac3c);
    run_division_test(0x5fdcece9a04e6e2ec3b9b97daae29, 0xafc02e6f0de1d5f1a03f856e3ff0ac50, 0x0, 0x8ba28622026c1e149c76ce780d48c);
    run_division_test(0x2dbd5a118251261474e78c00d6218, 0xd648b9b997123ec4ad9c28efe41429c0, 0x0, 0x36a4e0f5ccd2c7245ccc92eaa3032);
    run_division_test(0x5dd565d8cff2c3910670e7281437, 0xc98fe84476bcde26354201c914b67bc2, 0x0, 0x772d1799f8bce31f7938b243b1a3);
    run_division_test(0x395e07b9b8b0101ace9e5d8e81b3, 0x32ab696d44691512dcb0f703652cbc50, 0x0, 0x121d6d65094a60a4e0cacde47959a);
    run_division_test(0x23d7fae99ca75b5b3895532d3af7e, 0xfdd9cc91f526a4604e5155f44cca3932, 0x0, 0x2425ab1a41dec9f5cec9309c9f215);
    run_division_test(0x17a95c6d826ae28da48bf9c7e1d37, 0xdf1d2b4ffad0429069d1149849420ca, 0x0, 0x1b2630cc7021c0eed8b50b883f27c1);
    run_division_test(0x2f4eccfae439a7537c80d4ea48abb, 0x7c783f2d20675729ffa2370389b6041a, 0x0, 0x614c96d92643f1bba9d426a45ca79);
    run_division_test(0x50ef73f24f0359bf40f9af1c54503, 0x469d30f299b08c1fc606db348bec82e6, 0x0, 0x1256b1a2feed6ed8a72d08d53fc7e5);
    run_division_test(0x1f759ee0b81dcc772682f40ebffb0, 0x167ec3ed79e55af7bd2d80b89c1a2308, 0x0, 0x16603f3888ecab6083fd8f64cd3fea);
    run_division_test(0x1942fb52cd7b845ec1f0baf6c4eb1, 0xa32bfb866092db90fe4b43e847d0074f, 0x0, 0x27a209af1d8918a287093736dc0f1);
    run_division_test(0x40e38886d28ca946f16aa26424243, 0x3296ac028d8f1ab8b78a0c05299e8c49, 0x0, 0x1485d8aab412f548495df395399e8b);
    run_division_test(0x2941a1e28f5541a80859ce2f2fc4f, 0x4c744a392588e6801597ddf8611bbf82, 0x0, 0x8a24a5d0d212e897ddc97671b457d);
    run_division_test(0x12ba728d7d93924d73e5292b37627, 0x2432897ea1854505bdae6d810ee658db, 0x0, 0x8473e91137f0d7c56a7fc231ab83e);
    run_division_test(0xd3b366a58fe3821a0299458a948e697c, 0xd36969b2718202cecefc06c537e6201f, 0x1, 0x5997bab757f3870d31faee27348ea1);
    run_division_test(0x1c5531122412a124204881c422341974, 0x16bdecf1affca09bf42a85af2791b978, 0x1, 0x3eef6a228c9ed60eae1635602d1dd8fb);
    run_division_test(0x7662d55984edd61d7e4d6da1c8f7f609, 0xf7c7cfbb07a727f624ed66ea1b822860, 0x0, 0x7a502f6f5d0c2dfaf29130900236627a);
    run_division_test(0x394f5c6063a9bf5e78f3e342cccc96e, 0x4b53133fe701640e79961ed2a272ef12, 0x0, 0xc2c67f91abe37777ac2c2be19bb40bc);
    run_division_test(0x50d5c44bd44ff124dd8a11ed7f13a12c, 0x725eb08a055bbdc1fe4dcacbb0f9e91a, 0x0, 0xb4efecbd889dee1b3445025fe257e7c0);
    run_division_test(0x73c461991f9afba0594ac191776804a, 0x2520a3758144f7e7dd322b111dfbc24d, 0x0, 0x31e3b948bf3b6f8ac8a45cbb8c1ef438);
    run_division_test(0x8c4656479123f4eff6703486c19742b5, 0x4fcfca216a1678f42c518cf2e99db0a7, 0x1, 0xc1f0399a9922d8d80872a47d7566e782);
    run_division_test(0x648bc4ed42f73926ddfdce290ea950d1, 0xb0df10778bc3e270b670a9726a3a45a2, 0x0, 0x91873866dddaf9454fa9adeb86389398);
    run_division_test(0xe2d59629c914cc2a19ec4650788a4655, 0x9f7e128797dce9278d888f512c693456, 0x1, 0x6c16ff2e40d36f87e0dfb54f55f2e7dc);
    run_division_test(0xd5ada7bd58e9ce4459e9e75eb51015d2, 0xd7b7da8e50facc3edf649ced43227461, 0x0, 0xfd944a1de820c5fff7d6ca236f4fef5e);
    run_division_test(0x27209843a980001e1b4f4f299621b0b0, 0xbad89583a1b2c76f8b7dfcbabf468b9e, 0x0, 0x359bdb754935f619c47597a16f7356c1);
    run_division_test(0x545b4f21dbadb9d37e89472c650225e1, 0x247a18df5fa84d3854ad14828029f222, 0x2, 0x5006bbc13f486d49106cf96a3540be0f);
    run_division_test(0xaec80ada660da52cbbe451080be32c0f, 0x2268066ba28c4bb236e2b6250a4b2cfd, 0x5, 0x14757c4e1377d290033f17b2ef44f7e6);
    run_division_test(0x6cc203648df9ab95dc25b57d2a478bc6, 0x8c70b4964dede00784b7073f220c5e4d, 0x0, 0xc63f83370774258aee728c6c6d73c9c3);
    run_division_test(0xa0cf063c914870f20f741551e6a67c27, 0xbc82ef9ab8b00c03e1664b4876f35b76, 0x0, 0xda612163555e568ce463da0fa2ffa736);
    run_division_test(0x455ca50ab17ee49d71dfee7982c4c465, 0x425cc9dd112fabccd39f26cf4d219986, 0x1, 0xb92158c612d13d5b000fc3f50accf57);
    run_division_test(0xba4657b0e8f75f2c3649977fa5041f, 0xdb82d09bfffc45d103493d5e4041ccba, 0x0, 0xd93d2d1f74f7e989a883825f33d1bc);
    run_division_test(0x36c160744ac8b8691dce439885fcd551, 0xea3d9a2cc9fd334d0d907cefc88b7a16, 0x0, 0x3bd77efa7479897df8454f6f2cec26b0);
    run_division_test(0x56f641e2d09092a6e64946c369024aa7, 0xdee3d96895f88628e7f9df4d85303d44, 0x0, 0x63e147d8094e54587636cc8555d3f001);
    run_division_test(0xba4014de01b2b795afadf8f53904079d, 0xcf284844718f47ddee8f64eec36ceada, 0x0, 0xe629e183a78c1ef971e3ec728a5add51);
    run_division_test(0x972e8d62faa9f723704439ccd7ce48d8, 0x2fc13ff50e9c037ad5e6628c955f9, 0x32a7, 0x1194dbb1305b6b8e46f37aac18b3de96);
    run_division_test(0x11dec77d7e80a0ae8c536ef94880abef, 0x6224ad9c0aaa94643a94910213ccc, 0x2e9, 0xcff7aed9835aeb72b94e106c1dc5c50a);
    run_division_test(0x9be1d94f1f4098955784b57ff8273a22, 0x58a2cac5d356a92f5d0b570e73490, 0x1c23, 0x8df262d4df5f763e23950ead0e91d6d4);
    run_division_test(0xba91f625f0295355be949213660a642, 0x5020b063d23456bbe969e1c6b429e, 0x254, 0x12b6b8fbf5ad834d088ea966bc6867c1);
    run_division_test(0x7cb2609973cdab1afb62ba9e51d4a1e9, 0x11cc876c900dacb1c610dcfefc583, 0x7017, 0xfa75d3ec798471ba9599724ff3a5dc50);
    run_division_test(0xeb176d1db709409c8f58579bcaa08768, 0x5f399216c88317c100b77c87c489f, 0x2780, 0x37dc5fd07995a448d350baed20a9fbcf);
    run_division_test(0x4e1beb53e4bf713a2aabfd583cd4961a, 0x48125e52224ac858cdf20ae5410c9, 0x1157, 0x1d224a87b3c7fb3ad145cf875a63253c);
    run_division_test(0x8dce5cdd1f89e4ab5d5b5ccab318512, 0x2a6b118868bbabe5b94547cfd1ae3, 0x357, 0xd1d8a24161e31dd4ec62f41030772908);
    run_division_test(0x72e39155460d8c438d1b57faa36d45e, 0x2c582908deb8c9887dd38c1e21fc8, 0x297, 0x40ecce8073937cc462ba2e0e1acd525c);
    run_division_test(0x385d3e35206e5492c0853df318597708, 0x276219b77cf64eb5a022e4f58208d, 0x16e6, 0x17041dd97bf0d104b1a8941ad435c63d);
    run_division_test(0x93878657cc702dd24e3f3b2ead2212, 0x184c9a82ed59a289b4e149974954a, 0x61, 0x244a939131a571cee36457adf293fc87);
    run_division_test(0x765f6f501bd0643900e91ee8c59c2de2, 0x22ce6a7573c52148bc69c0c965d5b, 0x366a, 0x164c94fd8da4330553b8d434d43fa546);
    run_division_test(0xc2264b74eef484f58a47b24237f777dd, 0x6134cd276ef121755541f782d0dbc, 0x1ff4, 0xebd41213d981bfdbb6f4386ff66c0d07);
    run_division_test(0x8ec51ef7dc01cc5b97dcb0aa006148ef, 0x2a1d021bcb2e7111c6c6af35b4848, 0x363e, 0x2d4190e0dd8ce7e5d679eb6f1a59725);
    run_division_test(0x40a18d9b527f220c55ed3de006789ecf, 0x41aad898324f93145d3f132f5cb06, 0xfbf, 0x5c5cc0a7efa0b44f213e00a99fac30be);
    run_division_test(0xa9877d2e3b18f89b2da40f6d1107f24a, 0x36072d466a5adb9c495bcba3ed505, 0x3234, 0x6f75a473914c0bcef15f264d688b53ef);
    run_division_test(0xd51530cc17577384d6af305bc5a5cbc2, 0x33324fd97851afb64721e1f549f7d, 0x4297, 0xc6f3674200c3fba2420c658bb5ff7bbe);
    run_division_test(0x8bdf568efc85dd92b1412c6ecf7a4b49, 0x4280cbbe7563e118298d6a182afb5, 0x21a6, 0xe58acdcffe698a1764dc4887fbedd386);
    run_division_test(0x57064fdb806bfe1ceb12e5ebf10dc7de, 0x641248868f25b8272b09e3d1d0462, 0xde9, 0xfc689302e34235af64a7f900464cbc05);
    run_division_test(0xc366628c8d7a8a8cb88ef5d8b1d9a9e5, 0x1a930a1a6009c101b3cc9d9731029, 0x75a5, 0xab302c9f1cf2cf5261587bfb12d95c3e);
}

#[test]
fn test_division_and_multiplication_by() {
    run_division_and_multiplication_test(0xb6926f9c968555c93f44dcb82000, 0x41c4810843aadccbe5f4a3296ffe4bb5, 0x160f06301942d88312821d3a839a4, 0x3d3c3d6fb3ca40352cff8c194, 0x582ae3129825142d2dc28762d63e0f58);
    run_division_and_multiplication_test(0x6035c082fa70fbef4b5a85a98e01, 0x7cb3ac8362c55a5be8487272a01fd816, 0x43219b60eb0d907b268bb69c4527c, 0x33cb09fc0bae7b82906c11047, 0x868ff1cfd2764c95997b06eabccc4d40);
    run_division_and_multiplication_test(0x335ee4dd963f05e07c48132d3bb65, 0xd5b1a9ac31100b1b2af9047b3d20349c, 0x1d1d6d2ed2dd01e998c269b0b134d, 0x6ffc1a3eeaac6ec613af20a41, 0x4a5a834376064549e4fb70e32c2573fe);
    run_division_and_multiplication_test(0x4a9774ef9e7ef7eb2dd37769b2a57, 0x68b7106ce82b8ec285a2b8640f2a6da6, 0x646125b6c41a49096450cdc52924a, 0x4780d49c8c60b6cbc5e94c082e, 0x72e69388d0529ac7e59850af478e5e2c);
    run_division_and_multiplication_test(0x554b70e6865711eb212f9d59e1b11, 0xbfbbff82df1475549915c1bd16b303c6, 0x4247801f11f5fc008fd15d67d66dc, 0x1d7c23aa4508018d55a9c117df, 0xfedf54c4a67a241a38f65635e9904f48);
    run_division_and_multiplication_test(0x2635985ea60cc205e45baff6a7ee9, 0x90db0a922a99f010e8a609c6bb5d6510, 0x3f13076999b03d83924fdcb600da9, 0x10a330845ab2fa85b1d7e5af32, 0x20db0d441b9a34e81b377a3940946447);
    run_division_and_multiplication_test(0x3af0fe8cb844fd197f40920d84aff, 0x3ab67d323393037cb9d7043d2e815039, 0x3c1fb9fe9f771d2577003f15a3def, 0x3c5ba34f048e25f5c13ca1ef38, 0x63aa2ece2991af79ff6dd847a7133a9b);
    run_division_and_multiplication_test(0x2fff0e318bc58a255c24c6198e92c, 0xd9db3436c10f394bba16356a6d09a1e8, 0x50d71bba5cf899f5100ee6c02589d, 0x11cf60817aad5321294c5eb21b, 0x7ff7f8b4ea16fa9e0754b4ba40b1be32);
    run_division_and_multiplication_test(0x2975a99c4202288eded6c0bbb649e, 0xc649ac895a1508350db5ae616298aac3, 0x478a91ad0851ab464a44a85160c04, 0xef55bd0a66b3db457c56689b6, 0x495a49cda4c4ea265fe0f330e806cdac);
    run_division_and_multiplication_test(0x573ac22601c6360b8e5571c77f31f, 0x2fca44a2e6623b942129e06b401721f9, 0xd9b248ab9ec3b82fed8cfdb98121, 0x18d5a6e8e390b79195322bb41d, 0x730fe7a2de9830319bcd48857fd3aa60);
    run_division_and_multiplication_test(0xb8236135be634964dbb1d7ca4ee2, 0xbd7a7c0e74eefa07636828c786211c01, 0x493125b307895ecab94bb1e7d7c34, 0x47210f6b9a0f95e89d402f3c8, 0x810a70b06584f1c0ed996072e721beec);
    run_division_and_multiplication_test(0x38be1297f1790ca89198af5bda491, 0x7f1d9c3672fcb012b6db3ebf52af8bcb, 0x332893148fac01cfbadfcef52618b, 0x16d61bd8798fecf051afacf972, 0xc64ddb7404ea4cc9d6f09dfcbe160cbf);
    run_division_and_multiplication_test(0x412caa16f8f226f6caa898c14cfba, 0x5bb1cadc77ed2d385e13c742726a21c, 0x331ce4f6e3acd5458e7346ec58db0, 0x245475ce928b41b5dfec2d292ab, 0x54e2cedb87fa43542894b2a86d7b7ab0);
    run_division_and_multiplication_test(0xe64837dd9dd8ace2b323469ae1eb, 0x5066a7de39e0051d3d16976f66a32545, 0x5592705e6f6ed681a20ba05f213df, 0xf517c207c107dca75dcfaea81, 0xc15b151ca62b2655d2818a72e985604b);
    run_division_and_multiplication_test(0x36fd1613995dc80fbe308818c79ba, 0xb0083e398bfea9d03d425e98709eb8a9, 0x4b23cc69d12a5573288ced538eecc, 0x1778d7fe5cfeee213044b5c9de, 0xf3f5f73be7953dddbd16940439016e04);
    run_division_and_multiplication_test(0x4a0f4afdd6a44b835c1610f278e64, 0x52ef3818dd603e8578ec93599baacc70, 0x3d8c40ec1c1b1d1afc22f9dbe529a, 0x36f63255a9aa67fe0ef6f34e2e, 0x2b25cc87ac38c591d79bb6c4c23c200e);
    run_division_and_multiplication_test(0x58899a525a75cc8c5b1b3c258a7c6, 0x741be914c208c2d318e9502d1e4dd96e, 0x4347a94e0a5669d7e28875f8211df, 0x334db0ff3702401111a61afa3e, 0x9ea1caa92e2c3200c58144408c92239e);
    run_division_and_multiplication_test(0x265ef5082e17985e64c81d1045ed6, 0xdc7804734b98298137d81aceb4e3eccb, 0x27b7beb59c34bfbb43abf1e27a3a1, 0x6e99e721d7835a236753ecbe2, 0xdd5a377d4d47ed7827ac355231890e38);
    run_division_and_multiplication_test(0x559e8cdbb81c3f968ad4689eb5b16, 0x3b31a36d48ad95a110085130925b10a7, 0x15ba0f54e2d9c97ebdf3382004737, 0x1f6d156ccc2da76a3142fc641e, 0xf23c25325683a107c8088ed98b30cf1c);
    run_division_and_multiplication_test(0x384501318ddd8aff4d1852cf90188, 0x8706f6c0efb2265a01df36a9ccf34aed, 0x2cc3c8ab2deb16e9f11dec2bce424, 0x12a79b6e5d2a11e661e5bf9bc4, 0x4bdbce63925867cedc8ccd35d7fe6028);
}

#[test]
#[should_panic(expected: 'DIVISION_BY_ZERO')]
fn test_division_by_zero() {
    run_division_test(56, 0, 0, 0);
}
